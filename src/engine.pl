%% DALI2 Engine - Core metainterpreter
%% Replaces DALI's active_dali_wi.pl + meta1.pl + memory.pl
%%
%% Each agent runs as a thread with its own event loop.
%% The engine processes:
%%   - External events (messages from other agents)
%%   - Internal events (proactive, with conditions: forever/times/until/between)
%%   - Periodic tasks (every/3)
%%   - Condition monitors (when/3)
%%   - Condition-action rules (edge-triggered on_change)
%%   - Present/environment events (on_present)
%%   - Multi-events (on_all - fire when all events occurred)
%%   - Constraints (invariant checking)
%%   - Goals (achieve/test)
%%   - Tell/told communication filtering
%%   - Ontology-aware matching
%%   - Learning from experience
%%   - Past event memory
%%   - Actions

:- module(engine, [
    start_all/0,
    start_all/1,
    stop_all/0,
    start_agent/1,
    stop_agent/1,
    inject_event/2,
    agent_status/2,
    agent_log/2,
    agent_past/2,
    agent_beliefs/2,
    agent_learned/2,
    agent_goals/2,
    all_logs/1,
    log_agent/2,
    log_agent/3,
    set_node_name/1
]).

:- use_module(blackboard).
:- use_module(communication).
:- use_module(loader).
:- use_module(ai_oracle).
:- use_module(redis_comm).
:- use_module(library(lists)).
:- use_module(library(process)).

%% Process management state
:- dynamic agent_file_setting/1.
:- dynamic node_name_setting/1.     % node_name_setting(NodeName)

%% Agent runtime state
:- dynamic agent_running/1.            % agent_running(Name)
:- dynamic agent_process_pid/2.        % agent_process_pid(Name, Pid) - OS process PID
:- dynamic agent_log_entry/3.          % agent_log_entry(Name, Timestamp, Message)
:- dynamic agent_past_event/4.         % agent_past_event(Name, Event, Timestamp, Source)
:- dynamic agent_belief_rt/2.          % agent_belief_rt(Name, Fact)
:- dynamic agent_last_periodic/3.      % agent_last_periodic(Name, PeriodicId, LastTime)
:- dynamic agent_event_queue/2.        % agent_event_queue(Name, Event)
:- dynamic agent_internal_count/3.     % agent_internal_count(Name, InternalId, Count)
:- dynamic agent_condition_state/3.    % agent_condition_state(Name, CondId, true/false)
:- dynamic agent_multi_fired/2.        % agent_multi_fired(Name, MultiId)
:- dynamic agent_learned_rt/3.         % agent_learned_rt(Name, Pattern, Outcome)
:- dynamic agent_goal_status/3.        % agent_goal_status(Name, GoalId, Status)
:- dynamic agent_last_internal_fire/3. % agent_last_internal_fire(Name, InternalId, LastTime)
:- dynamic agent_internal_snapshot/3.  % agent_internal_snapshot(Name, InternalId, Snapshot)
:- dynamic agent_remember/4.           % agent_remember(Name, Event, Timestamp, Source)
:- dynamic agent_current_sender/2.     % agent_current_sender(Name, Sender) - set during msg processing
:- dynamic agent_residue_goal/3.       % agent_residue_goal(Name, GoalId, Goal)

%% ============================================================
%% PUBLIC API
%% ============================================================

%% start_all/0 - Start all defined agents
start_all :-
    start_all(_).

%% start_all/1 - Start all defined agents, File is optional (already loaded)
start_all(File) :-
    (nonvar(File) -> loader:load_agents(File) ; true),
    forall(loader:agent_def(Name, _), start_agent(Name)).

%% stop_all/0 - Stop all running agents
stop_all :-
    findall(N, agent_running(N), Names),
    maplist(stop_agent, Names).

%% set_node_name(+NodeName) - Set the node name for this instance
set_node_name(NodeName) :-
    retractall(node_name_setting(_)),
    assert(node_name_setting(NodeName)).

get_node_name(NodeName) :-
    (node_name_setting(N) -> NodeName = N ; NodeName = standalone).

%% start_agent(+Name) - Start a single agent as a separate OS process
%%   Communication goes via Redis (LINDA channel).
start_agent(Name) :-
    (agent_running(Name) ->
        log_agent(Name, "Agent already running")
    ;
        loader:agent_def(Name, Options),
        assert(agent_running(Name)),
        bb_register_agent(Name, Options),
        %% Register agent in Redis cluster registry
        get_node_name(NodeName),
        catch(redis_comm:redis_register_agent(NodeName, Name), _, true),
        get_agent_file(AgentFile),
        %% Spawn separate swipl process — only needs agent name and file
        process_create(
            path(swipl),
            ['-l', 'src/agent_process.pl', '-g', 'agent_main', '-t', 'halt',
             '--', Name, AgentFile],
            [process(Pid), detached(true),
             stdout(pipe(_StdOut)), stderr(std)]
        ),
        assert(agent_process_pid(Name, Pid)),
        log_agent(Name, "Agent process started (PID: ~w, Redis)", [Pid])
    ).

%% stop_agent(+Name) - Stop a single agent process
stop_agent(Name) :-
    (agent_running(Name) ->
        retract(agent_running(Name)),
        bb_unregister_agent(Name),
        %% Unregister agent from Redis cluster registry
        get_node_name(NodeName),
        catch(redis_comm:redis_unregister_agent(NodeName, Name), _, true),
        %% Kill OS process if still running
        (agent_process_pid(Name, Pid) ->
            retract(agent_process_pid(Name, Pid)),
            catch(process_kill(Pid), _, true),
            catch(process_wait(Pid, _, [timeout(3)]), _, true)
        ; true),
        log_agent(Name, "Agent stopped")
    ; true).

%% inject_event(+AgentName, +Event) - Inject an external event into an agent
%%   Uses Redis LINDA channel to deliver the event to the agent process.
inject_event(AgentName, Event) :-
    (catch(redis_comm:redis_connected, _, fail) ->
        %% Publish to LINDA channel — agent process will pick it up
        redis_comm:redis_publish_linda(system, AgentName, Event)
    ;
        %% Fallback: legacy thread-based injection
        with_mutex(blackboard_mutex,
            assert(agent_event_queue(AgentName, Event))
        )
    ),
    log_agent(AgentName, "Event injected: ~w", [Event]).

%% agent_status(+Name, -Status) - Get agent status
agent_status(Name, Status) :-
    (agent_running(Name) -> Status = running ; Status = stopped).

%% agent_log(+Name, -Entries) - Get log entries for an agent
agent_log(Name, Entries) :-
    findall(entry(T, Msg), agent_log_entry(Name, T, Msg), Entries).

%% agent_past(+Name, -Events) - Get past events for an agent
agent_past(Name, Events) :-
    findall(past(Ev, T, Src), agent_past_event(Name, Ev, T, Src), Events).

%% agent_beliefs(+Name, -Beliefs) - Get current beliefs for an agent
agent_beliefs(Name, Beliefs) :-
    findall(B, agent_belief_rt(Name, B), Beliefs).

%% agent_learned(+Name, -Learned) - Get learned patterns for an agent
agent_learned(Name, Learned) :-
    findall(learned(P, O), agent_learned_rt(Name, P, O), Learned).

%% agent_goals(+Name, -Goals) - Get goal statuses for an agent
agent_goals(Name, Goals) :-
    findall(goal(Id, Status), agent_goal_status(Name, Id, Status), Goals).

%% all_logs(-Entries) - Get all log entries across all agents
all_logs(Entries) :-
    findall(entry(Name, T, Msg), agent_log_entry(Name, T, Msg), Entries).

%% ============================================================
%% PROCESS MANAGEMENT HELPERS
%% ============================================================


%% get_agent_file(-File) - Get the current agent file path
get_agent_file(File) :-
    (agent_file_setting(F) -> File = F ; File = '').

%% set_agent_file(+File) - Set the current agent file path
set_agent_file(File) :-
    retractall(agent_file_setting(_)),
    assert(agent_file_setting(File)).


%% ============================================================
%% AGENT LOOP
%% ============================================================

%% agent_loop(+Name, +Options) - Main agent cycle
agent_loop(Name, Options) :-
    catch(
        agent_loop_inner(Name, Options),
        stop_agent,
        log_agent(Name, "Agent loop terminated")
    ).

agent_loop_inner(Name, Options) :-
    (agent_running(Name) ->
        % Each step is wrapped with safe_step/1 so that body failure
        % or uncaught exceptions in one step do not kill the agent loop.
        safe_step(process_messages(Name)),
        safe_step(process_injected_events(Name)),
        safe_step(process_internals(Name)),
        safe_step(process_periodics(Name)),
        safe_step(process_monitors(Name)),
        safe_step(process_condition_actions(Name)),
        safe_step(process_present_events(Name)),
        safe_step(process_multi_events(Name)),
        safe_step(process_past_reactions(Name)),
        safe_step(process_constraints(Name)),
        safe_step(process_goals(Name)),
        safe_step(process_residue_goals(Name)),
        safe_step(process_past_lifetime(Name)),
        % Sleep for cycle duration
        get_cycle_ms(Options, SleepMs),
        SleepSec is SleepMs / 1000,
        sleep(SleepSec),
        agent_loop_inner(Name, Options)
    ;
        true
    ).

%% safe_step(+Goal) - Run a processing step; absorb both failure and exceptions
safe_step(Goal) :-
    (catch(Goal, _, true) -> true ; true).

%% get_cycle_ms(+Options, -Ms) - Extract cycle time from options
get_cycle_ms(Options, Ms) :-
    (member(cycle(S), Options) ->
        (number(S) -> Ms is S * 1000 ; Ms = 1000)
    ;
        Ms = 1000
    ).

%% ============================================================
%% EVENT PROCESSING
%% ============================================================

%% process_messages(+Name) - Receive, prioritize, and process all pending messages
%% Note: In the current architecture, agents run as separate OS processes
%% (agent_process.pl) and poll Redis directly. This engine loop is kept for
%% potential future in-process agent mode.
process_messages(Name) :-
    redis_comm:redis_poll_messages(Name, Messages),
    prioritize_messages(Name, Messages, Sorted),
    process_message_list(Name, Sorted).

%% prioritize_messages(+Name, +Messages, -Sorted) - Sort by told priority (highest first)
prioritize_messages(Name, Messages, Sorted) :-
    assign_priorities(Name, Messages, Prioritized),
    sort(1, @>=, Prioritized, SortedPairs),
    pairs_values(SortedPairs, Sorted).

assign_priorities(_, [], []).
assign_priorities(Name, [Msg|Rest], [P-Msg|PRest]) :-
    Msg = message(_, Content, _),
    (loader:agent_told(Name, Pattern, Priority, _),
     subsumes_term(Pattern, Content) ->
        P = Priority
    ;
        P = 0
    ),
    assign_priorities(Name, Rest, PRest).

process_message_list(_, []).
process_message_list(Name, [message(From, Content, T) | Rest]) :-
    (should_allow_receive(Name, Content, _Priority) ->
        log_agent(Name, "Received from ~w: ~w", [From, Content]),
        record_past(Name, received(Content, From), T),
        % Set current sender for use in handlers (e.g. on_proposal)
        retractall(agent_current_sender(Name, _)),
        assert(agent_current_sender(Name, From)),
        % Handle FIPA message semantics
        handle_fipa_semantics(Name, From, Content, T),
        fire_handlers(Name, Content),
        fire_learning(Name, Content),
        retractall(agent_current_sender(Name, _))
    ;
        log_agent(Name, "Message rejected by told rule: ~w from ~w", [Content, From])
    ),
    process_message_list(Name, Rest).

%% handle_fipa_semantics(+Name, +From, +Content, +T) - FIPA message type special handling
handle_fipa_semantics(Name, _From, confirm(Fact), T) :- !,
    record_past(Name, confirmed(Fact), T),
    log_agent(Name, "Fact confirmed: ~w", [Fact]).

handle_fipa_semantics(Name, _From, disconfirm(Fact), _T) :- !,
    retractall(agent_past_event(Name, confirmed(Fact), _, _)),
    log_agent(Name, "Fact disconfirmed: ~w", [Fact]).

handle_fipa_semantics(Name, From, query_ref(Query), _T) :- !,
    findall(Query, agent_belief_rt(Name, Query), Results),
    communication:send(Name, From, inform(query_ref(Query), values(Results))),
    log_agent(Name, "Query_ref response to ~w: ~w", [From, Results]).

handle_fipa_semantics(Name, From, propose(Action), _T) :- !,
    fire_proposal_handlers(Name, From, Action).

handle_fipa_semantics(_, _, _, _).  % Other FIPA types: no special semantics

%% fire_proposal_handlers(+Name, +From, +Action) - Fire on_proposal handlers
fire_proposal_handlers(Name, From, Action) :-
    forall(
        loader:agent_on_proposal(Name, Pattern, Body),
        (copy_term(Pattern-Body, ActionCopy-BodyCopy),
         (ActionCopy = Action ->
            retractall(agent_current_sender(Name, _)),
            assert(agent_current_sender(Name, From)),
            catch(
                execute_body(Name, BodyCopy),
                Error,
                log_agent(Name, "Proposal handler error: ~w", [Error])
            )
         ; true))
    ).

%% process_injected_events(+Name) - Process events from the inject queue
process_injected_events(Name) :-
    collect_event_queue(Name, Events),
    process_injected_list(Name, Events).

collect_event_queue(Name, [Ev|Rest]) :-
    retract(agent_event_queue(Name, Ev)), !,
    collect_event_queue(Name, Rest).
collect_event_queue(_, []).

process_injected_list(_, []).
process_injected_list(Name, [Event | Rest]) :-
    get_time(Stamp), T is truncate(Stamp * 1000),
    record_past(Name, injected(Event), T),
    fire_handlers(Name, Event),
    fire_learning(Name, Event),
    process_injected_list(Name, Rest).

%% fire_handlers(+Name, +Event) - Fire all matching handlers for an event
fire_handlers(Name, Event) :-
    findall(
        Pattern-Body,
        loader:agent_handler(Name, Pattern, Body),
        Handlers
    ),
    fire_handler_list(Name, Event, Handlers).

fire_handler_list(_, _, []).
fire_handler_list(Name, Event, [Pattern-Body | Rest]) :-
    (copy_term(Pattern-Body, EventCopy-BodyCopy),
     (EventCopy = Event ; ontology_match(Name, EventCopy, Event)) ->
        catch(
            execute_body(Name, BodyCopy),
            Error,
            log_agent(Name, "Handler error for ~w: ~w", [Event, Error])
        )
    ; true),
    fire_handler_list(Name, Event, Rest).

%% process_periodics(+Name) - Run periodic tasks whose interval has elapsed
process_periodics(Name) :-
    get_time(Now),
    forall(
        loader:agent_periodic(Name, Seconds, Body),
        (
            term_to_atom(Body, PeriodicId),
            (agent_last_periodic(Name, PeriodicId, Last) ->
                Elapsed is Now - Last,
                (Elapsed >= Seconds ->
                    retract(agent_last_periodic(Name, PeriodicId, Last)),
                    assert(agent_last_periodic(Name, PeriodicId, Now)),
                    catch(
                        execute_body(Name, Body),
                        Error,
                        log_agent(Name, "Periodic error: ~w", [Error])
                    )
                ; true)
            ;
                assert(agent_last_periodic(Name, PeriodicId, Now)),
                catch(
                    execute_body(Name, Body),
                    Error,
                    log_agent(Name, "Periodic error: ~w", [Error])
                )
            )
        )
    ).

%% process_monitors(+Name) - Check condition monitors
process_monitors(Name) :-
    forall(
        loader:agent_monitor(Name, Condition, Body),
        (catch(
            (call_condition(Name, Condition) ->
                catch(
                    execute_body(Name, Body),
                    Error,
                    log_agent(Name, "Monitor error: ~w", [Error])
                )
            ; true),
            _,
            true
        ))
    ).

%% ============================================================
%% INTERNAL EVENTS (proactive)
%% ============================================================

%% process_internals(+Name) - Fire internal events whose conditions are met
process_internals(Name) :-
    get_time(Now),
    forall(
        loader:agent_internal(Name, Event, Options, Body),
        process_single_internal(Name, Event, Options, Body, Now)
    ).

process_single_internal(Name, Event, Options, Body, Now) :-
    term_to_atom(Event, InternalId),
    % Handle change condition (reset counter if monitored facts changed)
    process_change_condition(Name, InternalId, Options),
    (should_fire_internal(Name, InternalId, Options, Now) ->
        (catch(
            (copy_term(Event-Body, _ECopy-BodyCopy),
             execute_body(Name, BodyCopy),
             increment_internal_count(Name, InternalId),
             % Record fire time for interval tracking
             retractall(agent_last_internal_fire(Name, InternalId, _)),
             assert(agent_last_internal_fire(Name, InternalId, Now)),
             get_time(Stamp), T is truncate(Stamp * 1000),
             record_past(Name, internal(Event), T),
             fire_learning(Name, Event)),
            Error,
            log_agent(Name, "Internal event error: ~w", [Error])
        ) -> true ; true)  % Body failure is OK — condition not met
    ; true).

%% process_change_condition(+Name, +Id, +Options) - Reset counter if monitored facts changed
process_change_condition(Name, InternalId, Options) :-
    (member(change(FactList), Options) ->
        get_fact_snapshot(Name, FactList, CurrentSnapshot),
        (agent_internal_snapshot(Name, InternalId, OldSnapshot) ->
            (CurrentSnapshot \== OldSnapshot ->
                retractall(agent_internal_count(Name, InternalId, _)),
                retractall(agent_internal_snapshot(Name, InternalId, _)),
                assert(agent_internal_snapshot(Name, InternalId, CurrentSnapshot)),
                log_agent(Name, "Change detected for ~w, counter reset", [InternalId])
            ;
                true
            )
        ;
            assert(agent_internal_snapshot(Name, InternalId, CurrentSnapshot))
        )
    ;
        true
    ).

get_fact_snapshot(Name, FactList, Snapshot) :-
    maplist(get_single_fact_value(Name), FactList, Snapshot).

get_single_fact_value(Name, Fact, Value) :-
    (agent_belief_rt(Name, Fact) ->
        Value = present(Fact)
    ;
        (agent_past_event(Name, Fact, T, _) ->
            Value = past(Fact, T)
        ;
            Value = absent(Fact)
        )
    ).

should_fire_internal(Name, InternalId, Options, Now) :-
    (Options = [] -> true ;
     is_list(Options) -> check_all_internal_opts(Name, InternalId, Options, Now) ;
     check_single_internal_opt(Name, InternalId, Options, Now)).

check_all_internal_opts(_, _, [], _).
check_all_internal_opts(Name, Id, [Opt|Rest], Now) :-
    check_single_internal_opt(Name, Id, Opt, Now),
    check_all_internal_opts(Name, Id, Rest, Now).

check_single_internal_opt(_, _, forever, _).

check_single_internal_opt(Name, Id, times(N), _) :-
    (agent_internal_count(Name, Id, Count) -> Count < N ; true).

check_single_internal_opt(Name, _, until(Condition), _) :-
    \+ call_condition(Name, Condition).

check_single_internal_opt(_, _, between(time(H1,M1), time(H2,M2)), Now) :-
    stamp_date_time(Now, DateTime, local),
    date_time_value(hour, DateTime, H),
    date_time_value(minute, DateTime, M),
    CurrentMinutes is H * 60 + M,
    StartMinutes is H1 * 60 + M1,
    EndMinutes is H2 * 60 + M2,
    CurrentMinutes >= StartMinutes,
    CurrentMinutes =< EndMinutes.

check_single_internal_opt(Name, _, trigger(Condition), _) :-
    catch(call_condition(Name, Condition), _, fail).

check_single_internal_opt(Name, Id, interval(Seconds), _Now) :-
    (agent_last_internal_fire(Name, Id, LastFire) ->
        get_time(Now2),
        Elapsed is Now2 - LastFire,
        Elapsed >= Seconds
    ;
        true  % first time, allow
    ).

% change option is handled separately in process_change_condition, always passes here
check_single_internal_opt(_, _, change(_), _).

check_single_internal_opt(_, _, between(date(Y1,Mo1,D1), date(Y2,Mo2,D2)), Now) :-
    stamp_date_time(Now, DateTime, local),
    date_time_value(year, DateTime, Y),
    date_time_value(month, DateTime, Mo),
    date_time_value(day, DateTime, D),
    DayCurrent is Y * 10000 + Mo * 100 + D,
    DayStart is Y1 * 10000 + Mo1 * 100 + D1,
    DayEnd is Y2 * 10000 + Mo2 * 100 + D2,
    DayCurrent >= DayStart,
    DayCurrent =< DayEnd.

increment_internal_count(Name, InternalId) :-
    (retract(agent_internal_count(Name, InternalId, N)) ->
        N1 is N + 1,
        assert(agent_internal_count(Name, InternalId, N1))
    ;
        assert(agent_internal_count(Name, InternalId, 1))
    ).

%% ============================================================
%% CONDITION-ACTION RULES (edge-triggered)
%% ============================================================

%% process_condition_actions(+Name) - Fire body on rising edge of condition
process_condition_actions(Name) :-
    forall(
        loader:agent_condition_action(Name, Condition, Body),
        (term_to_atom(Condition, CondId),
         catch(
            (call_condition(Name, Condition) ->
                (agent_condition_state(Name, CondId, true) ->
                    true
                ;
                    retractall(agent_condition_state(Name, CondId, _)),
                    assert(agent_condition_state(Name, CondId, true)),
                    log_agent(Name, "Condition became true: ~w", [Condition]),
                    catch(
                        execute_body(Name, Body),
                        Error,
                        log_agent(Name, "Condition-action error: ~w", [Error])
                    )
                )
            ;
                retractall(agent_condition_state(Name, CondId, _)),
                assert(agent_condition_state(Name, CondId, false))
            ),
            _,
            true
        ))
    ).

%% ============================================================
%% PRESENT/ENVIRONMENT EVENTS
%% ============================================================

%% process_present_events(+Name) - Check environment conditions each cycle
process_present_events(Name) :-
    forall(
        loader:agent_present(Name, Condition, Body),
        (catch(
            (call_condition(Name, Condition) ->
                catch(
                    execute_body(Name, Body),
                    Error,
                    log_agent(Name, "Present event error: ~w", [Error])
                )
            ; true),
            _,
            true
        ))
    ).

%% ============================================================
%% MULTI-EVENTS (fire when all listed events occurred)
%% ============================================================

%% process_multi_events(+Name) - Fire when all events in the list have past records
%% Supports optional delta-t: events must have occurred within DeltaT seconds of each other.
process_multi_events(Name) :-
    forall(
        loader:agent_multi_event(Name, EventList, Body, DeltaT),
        (term_to_atom(EventList, MultiId),
         (all_events_occurred(Name, EventList, DeltaT) ->
            (agent_multi_fired(Name, MultiId) ->
                true
            ;
                assert(agent_multi_fired(Name, MultiId)),
                log_agent(Name, "All events occurred: ~w", [EventList]),
                catch(
                    execute_body(Name, Body),
                    Error,
                    log_agent(Name, "Multi-event error: ~w", [Error])
                )
            )
         ;
            retractall(agent_multi_fired(Name, MultiId))
         ))
    ).

%% all_events_occurred(+Name, +EventList, +DeltaT)
%% DeltaT = 0 means no time constraint (backward compatible).
all_events_occurred(Name, EventList, DeltaT) :-
    collect_event_timestamps(Name, EventList, Timestamps),
    (DeltaT =:= 0 ->
        true  % no time constraint
    ;
        DeltaTMs is DeltaT * 1000,
        max_list(Timestamps, MaxT),
        min_list(Timestamps, MinT),
        Span is MaxT - MinT,
        Span =< DeltaTMs
    ).

collect_event_timestamps(_, [], []).
collect_event_timestamps(Name, [Event|Rest], [T|Ts]) :-
    event_in_past_with_time(Name, Event, T),
    collect_event_timestamps(Name, Rest, Ts).

event_in_past_with_time(Name, Event, T) :-
    agent_past_event(Name, received(Event, _), T, _), !.
event_in_past_with_time(Name, Event, T) :-
    agent_past_event(Name, injected(Event), T, _), !.
event_in_past_with_time(Name, Event, T) :-
    agent_past_event(Name, internal(Event), T, _), !.
event_in_past_with_time(Name, Event, T) :-
    agent_past_event(Name, Event, T, _), !.

event_in_past(Name, Event) :-
    agent_past_event(Name, received(Event, _), _, _), !.
event_in_past(Name, Event) :-
    agent_past_event(Name, injected(Event), _, _), !.
event_in_past(Name, Event) :-
    agent_past_event(Name, internal(Event), _, _), !.
event_in_past(Name, Event) :-
    agent_past_event(Name, Event, _, _), !.

%% ============================================================
%% CONSTRAINTS (invariant checking)
%% ============================================================

%% process_constraints(+Name) - Check all constraints; fire handler if violated
process_constraints(Name) :-
    forall(
        loader:agent_constraint(Name, Condition, Body),
        check_single_constraint(Name, Condition, Body)
    ).

check_single_constraint(Name, Condition, Body) :-
    copy_term(Condition-Body, TestCond-_TestBody),
    (catch(call_condition(Name, TestCond), _, fail) ->
        true  % constraint satisfied
    ;
        % Constraint violated - rebind variables for the body
        copy_term(Condition-Body, BCond-BBody),
        attempt_bind(Name, BCond),
        log_agent(Name, "Constraint violated: ~w", [BCond]),
        (BBody \== true ->
            catch(
                execute_body(Name, BBody),
                Error,
                log_agent(Name, "Constraint handler error: ~w", [Error])
            )
        ; true)
    ).

%% attempt_bind(+Name, +Condition) - Bind variables from state-querying parts of a condition
attempt_bind(Name, (C1, C2)) :- !,
    attempt_bind(Name, C1),
    attempt_bind(Name, C2).
attempt_bind(Name, believes(Fact)) :- !,
    (agent_belief_rt(Name, Fact) -> true ; true).
attempt_bind(Name, has_past(Event)) :- !,
    (agent_past_event(Name, Event, _, _) -> true ; true).
attempt_bind(Name, learned(P, O)) :- !,
    (agent_learned_rt(Name, P, O) -> true ; true).
attempt_bind(_, _).  % skip tests (arithmetic, comparisons, etc.)

%% ============================================================
%% GOALS (achieve / test)
%% ============================================================

%% process_goals(+Name) - Process achieve and test goals
process_goals(Name) :-
    forall(
        loader:agent_goal(Name, Type, Goal, Plan),
        process_single_goal(Name, Type, Goal, Plan)
    ).

goal_canonical_id(Goal, GoalId) :-
    copy_term(Goal, GCopy),
    numbervars(GCopy, 0, _),
    term_to_atom(GCopy, GoalId).

process_single_goal(Name, achieve, Goal, Plan) :-
    goal_canonical_id(Goal, GoalId),
    (agent_goal_status(Name, GoalId, achieved) ->
        true
    ;
        (call_condition(Name, Goal) ->
            retractall(agent_goal_status(Name, GoalId, _)),
            assert(agent_goal_status(Name, GoalId, achieved)),
            log_agent(Name, "Goal achieved: ~w", [Goal]),
            get_time(Stamp), T is truncate(Stamp * 1000),
            record_past(Name, goal_achieved(Goal), T)
        ;
            catch(
                execute_body(Name, Plan),
                Error,
                log_agent(Name, "Goal plan error for ~w: ~w", [Goal, Error])
            )
        )
    ).

process_single_goal(Name, test, Goal, Plan) :-
    goal_canonical_id(Goal, GoalId),
    (agent_goal_status(Name, GoalId, _) ->
        true
    ;
        catch(
            (execute_body(Name, Plan) ->
                (call_condition(Name, Goal) ->
                    assert(agent_goal_status(Name, GoalId, succeeded)),
                    log_agent(Name, "Test goal succeeded: ~w", [Goal])
                ;
                    assert(agent_goal_status(Name, GoalId, failed)),
                    log_agent(Name, "Test goal failed: ~w", [Goal])
                )
            ;
                assert(agent_goal_status(Name, GoalId, failed)),
                log_agent(Name, "Test goal plan failed: ~w", [Goal])
            ),
            Error,
            (assert(agent_goal_status(Name, GoalId, error)),
             log_agent(Name, "Test goal error for ~w: ~w", [Goal, Error]))
        )
    ).

%% ============================================================
%% TELL/TOLD COMMUNICATION FILTERING
%% ============================================================

%% should_allow_send(+Sender, +Content) - Check sender's tell rules (with body conditions)
should_allow_send(Sender, Content) :-
    (   \+ loader:agent_tell(Sender, _, _)
    ->  true
    ;   loader:agent_tell(Sender, Pattern, Body),
        subsumes_term(Pattern, Content),
        (Body == true -> true ; catch(call_condition(Sender, Body), _, fail))
    ).

%% should_allow_receive(+Receiver, +Content, -Priority) - Check receiver's told rules (with body conditions)
should_allow_receive(Receiver, Content, Priority) :-
    (   \+ loader:agent_told(Receiver, _, _, _)
    ->  Priority = 0
    ;   loader:agent_told(Receiver, Pattern, Priority, Body),
        subsumes_term(Pattern, Content),
        (Body == true -> true ; catch(call_condition(Receiver, Body), _, fail))
    ).

%% ============================================================
%% ONTOLOGY MATCHING
%% ============================================================

%% ontology_match(+Name, +Term1, +Term2) - Check if terms are equivalent via ontology
ontology_match(_, Term1, Term2) :-
    Term1 = Term2, !.
ontology_match(Name, Term1, Term2) :-
    loader:agent_ontology(Name, same_as(Term1, Term2)), !.
ontology_match(Name, Term1, Term2) :-
    loader:agent_ontology(Name, same_as(Term2, Term1)), !.
ontology_match(Name, Term1, Term2) :-
    functor(Term1, F1, A), functor(Term2, F2, A),
    (loader:agent_ontology(Name, eq_property(F1, F2)) ;
     loader:agent_ontology(Name, eq_property(F2, F1))),
    Term1 =.. [F1|Args], Term2 =.. [F2|Args2],
    maplist(=, Args, Args2), !.
ontology_match(Name, Term1, Term2) :-
    functor(Term1, F1, A), functor(Term2, F2, A),
    (loader:agent_ontology(Name, eq_class(F1, F2)) ;
     loader:agent_ontology(Name, eq_class(F2, F1))),
    Term1 =.. [F1|Args], Term2 =.. [F2|Args2],
    maplist(=, Args, Args2), !.
ontology_match(Name, Term1, Term2) :-
    loader:agent_ontology(Name, symmetric(Rel)),
    Term1 =.. [Rel, A, B],
    Term2 =.. [Rel, B, A], !.

%% ============================================================
%% LEARNING
%% ============================================================

%% fire_learning(+Name, +Event) - Check learning rules when an event occurs
fire_learning(Name, Event) :-
    forall(
        loader:agent_learn_rule(Name, EventPattern, Outcome, Body),
        (copy_term(EventPattern-Outcome-Body, ECopy-OCopy-BCopy),
         (ECopy = Event ->
            catch(
                (execute_body(Name, BCopy) ->
                    assert(agent_learned_rt(Name, Event, OCopy)),
                    log_agent(Name, "Learned from ~w: ~w", [Event, OCopy])
                ; true),
                _,
                true
            )
         ; true))
    ).

%% ============================================================
%% BODY EXECUTION - Interprets agent DSL predicates
%% ============================================================

%% execute_body(+Name, +Body) - Execute a body term in agent context
execute_body(_, true) :- !.
execute_body(Name, (A, B)) :- !,
    execute_body(Name, A),
    execute_body(Name, B).
execute_body(Name, (A ; B)) :- !,
    % Check if A is an if-then (Cond -> Then ; Else)
    (nonvar(A), A = (Cond -> Then) ->
        (execute_body(Name, Cond) ->
            execute_body(Name, Then)
        ;
            execute_body(Name, B)
        )
    ;
        (execute_body(Name, A) ; execute_body(Name, B))
    ).
execute_body(Name, (Cond -> Then)) :- !,
    (execute_body(Name, Cond) ->
        execute_body(Name, Then)
    ; true).
execute_body(Name, \+(Goal)) :- !,
    \+(execute_body(Name, Goal)).
execute_body(Name, not(Goal)) :- !,
    \+(execute_body(Name, Goal)).

% --- DALI2 DSL predicates ---

% send(To, Content) - Send a message to another agent (with tell/told filtering)
execute_body(Name, send(To, Content)) :- !,
    (should_allow_send(Name, Content) ->
        communication:send(Name, To, Content),
        log_agent(Name, "Sent to ~w: ~w", [To, Content])
    ;
        log_agent(Name, "Send blocked by tell rule: ~w to ~w", [Content, To])
    ).

% broadcast(Content) - Send to all other agents
execute_body(Name, broadcast(Content)) :- !,
    communication:broadcast(Name, Content),
    log_agent(Name, "Broadcast: ~w", [Content]).

% log(Format, Args) - Log a formatted message
execute_body(Name, log(Format, Args)) :- !,
    catch(
        (format(atom(Msg), Format, Args),
         log_agent(Name, Msg)),
        _,
        log_agent(Name, Format)
    ).

% log(Message) - Log a simple message
execute_body(Name, log(Message)) :- !,
    log_agent(Name, "~w", [Message]).

% assert_belief(Fact) - Add a belief
execute_body(Name, assert_belief(Fact)) :- !,
    assert(agent_belief_rt(Name, Fact)),
    log_agent(Name, "Belief added: ~w", [Fact]).

% retract_belief(Fact) - Remove a belief
execute_body(Name, retract_belief(Fact)) :- !,
    retractall(agent_belief_rt(Name, Fact)),
    log_agent(Name, "Belief removed: ~w", [Fact]).

% believes(Fact) - Check if agent has a belief (ontology-aware)
execute_body(Name, believes(Fact)) :- !,
    (agent_belief_rt(Name, Fact)
    ; agent_belief_rt(Name, Other), ontology_match(Name, Fact, Other)
    ).

% has_past(Event) - Check if event is in past
execute_body(Name, has_past(Event)) :- !,
    (agent_past_event(Name, Event, _, _) -> true
    ; event_in_past(Name, Event)
    ).

% has_past(Event, Time) - Check past with time
execute_body(Name, has_past(Event, Time)) :- !,
    (agent_past_event(Name, Event, Time, _) -> true
    ; agent_past_event(Name, received(Event, _), Time, _) -> true
    ; agent_past_event(Name, injected(Event), Time, _) -> true
    ; agent_past_event(Name, internal(Event), Time, _)
    ).

% do(Action) - Execute an action defined with agent:do
execute_body(Name, do(Action)) :- !,
    (loader:agent_action(Name, ActionPattern, ActionBody),
     copy_term(ActionPattern-ActionBody, Action-BodyCopy) ->
        log_agent(Name, "Executing action: ~w", [Action]),
        get_time(Stamp), T is truncate(Stamp * 1000),
        record_past(Name, did(Action), T),
        execute_body(Name, BodyCopy)
    ;
        log_agent(Name, "Unknown action: ~w", [Action])
    ).

% helper(Goal) - Call a helper predicate
execute_body(Name, helper(Goal)) :- !,
    (loader:agent_helper(Name, HeadPattern, HelperBody),
     copy_term(HeadPattern-HelperBody, Goal-BodyCopy) ->
        execute_body(Name, BodyCopy)
    ;
        log_agent(Name, "Unknown helper: ~w", [Goal])
    ).

% ask_ai(Context, Result) - Query the AI oracle (with tell/told filtering)
execute_body(Name, ask_ai(Context, Result)) :- !,
    (should_allow_send(Name, Context) ->
        log_agent(Name, "Querying AI oracle: ~w", [Context]),
        ai_oracle:ask_ai(Context, RawResult),
        (should_allow_receive(Name, RawResult, _) ->
            Result = RawResult,
            log_agent(Name, "AI oracle response: ~w", [Result])
        ;
            log_agent(Name, "AI oracle response rejected by told rule: ~w", [RawResult]),
            Result = rejected(RawResult)
        )
    ;
        log_agent(Name, "AI oracle query blocked by tell rule: ~w", [Context]),
        Result = blocked(Context)
    ).

% ask_ai(Context, SystemPrompt, Result) - Query AI oracle with custom prompt (with tell/told filtering)
execute_body(Name, ask_ai(Context, SystemPrompt, Result)) :- !,
    (should_allow_send(Name, Context) ->
        log_agent(Name, "Querying AI oracle: ~w", [Context]),
        ai_oracle:ask_ai(Context, SystemPrompt, RawResult),
        (should_allow_receive(Name, RawResult, _) ->
            Result = RawResult,
            log_agent(Name, "AI oracle response: ~w", [Result])
        ;
            log_agent(Name, "AI oracle response rejected by told rule: ~w", [RawResult]),
            Result = rejected(RawResult)
        )
    ;
        log_agent(Name, "AI oracle query blocked by tell rule: ~w", [Context]),
        Result = blocked(Context)
    ).

% ai_available - Check if AI oracle is configured
execute_body(_, ai_available) :- !,
    ai_oracle:ai_available.

% from(Sender) - Get the sender of the current message being processed
execute_body(Name, from(Sender)) :- !,
    agent_current_sender(Name, Sender).

% has_remember(Event) - Check if event is in remember tier
execute_body(Name, has_remember(Event)) :- !,
    agent_remember(Name, Event, _, _).

% has_remember(Event, Time) - Check remember with time
execute_body(Name, has_remember(Event, Time)) :- !,
    agent_remember(Name, Event, Time, _).

% has_confirmed(Fact) - Check if a fact was confirmed via FIPA confirm
execute_body(Name, has_confirmed(Fact)) :- !,
    agent_past_event(Name, confirmed(Fact), _, _).

% accept_proposal(To, Action) - Send accept_proposal FIPA message
execute_body(Name, accept_proposal(To, Action)) :- !,
    execute_body(Name, send(To, accept_proposal(Action))).

% reject_proposal(To, Action) - Send reject_proposal FIPA message
execute_body(Name, reject_proposal(To, Action)) :- !,
    execute_body(Name, send(To, reject_proposal(Action))).

% reply_to(Content) - Reply to the current message sender
execute_body(Name, reply_to(Content)) :- !,
    (agent_current_sender(Name, Sender) ->
        execute_body(Name, send(Sender, Content))
    ;
        log_agent(Name, "reply_to failed: no current sender")
    ).

% learn(Pattern, Outcome) - Record a learned association
execute_body(Name, learn(Pattern, Outcome)) :- !,
    assert(agent_learned_rt(Name, Pattern, Outcome)),
    log_agent(Name, "Learned: ~w -> ~w", [Pattern, Outcome]).

% learned(Pattern, Outcome) - Check if agent has learned something
execute_body(Name, learned(Pattern, Outcome)) :- !,
    agent_learned_rt(Name, Pattern, Outcome).

% forget(Pattern) - Remove all learned associations for Pattern
execute_body(Name, forget(Pattern)) :- !,
    retractall(agent_learned_rt(Name, Pattern, _)),
    log_agent(Name, "Forgot: ~w", [Pattern]).

% onto_match(Term1, Term2) - Check ontology equivalence
execute_body(Name, onto_match(Term1, Term2)) :- !,
    ontology_match(Name, Term1, Term2).

% achieve(Goal) - Manually trigger an achieve goal (with residue tracking)
execute_body(Name, achieve(Goal)) :- !,
    goal_canonical_id(Goal, GoalId),
    (agent_goal_status(Name, GoalId, achieved) ->
        true
    ;
        (catch(call_condition(Name, Goal), _, fail) ->
            retractall(agent_goal_status(Name, GoalId, _)),
            assert(agent_goal_status(Name, GoalId, achieved)),
            retractall(agent_residue_goal(Name, GoalId, _)),
            log_agent(Name, "Inline goal achieved: ~w", [Goal]),
            get_time(Stamp), T is truncate(Stamp * 1000),
            record_past(Name, goal_achieved(Goal), T)
        ;
            (agent_residue_goal(Name, GoalId, _) ->
                true
            ;
                assert(agent_residue_goal(Name, GoalId, Goal)),
                log_agent(Name, "Goal queued as residue: ~w", [Goal])
            )
        )
    ).

% reset_goal(Goal) - Reset a goal so it can be re-attempted
execute_body(Name, reset_goal(Goal)) :- !,
    goal_canonical_id(Goal, GoalId),
    retractall(agent_goal_status(Name, GoalId, _)),
    retractall(agent_residue_goal(Name, GoalId, _)),
    log_agent(Name, "Goal reset: ~w", [Goal]).

% bb_read(Pattern) - Read from shared blackboard
execute_body(_, bb_read(Pattern)) :- !,
    blackboard:bb_get(Pattern).

% bb_write(Tuple) - Write to shared blackboard
execute_body(Name, bb_write(Tuple)) :- !,
    blackboard:bb_put(Tuple),
    log_agent(Name, "Blackboard write: ~w", [Tuple]).

% bb_remove(Pattern) - Remove from shared blackboard
execute_body(Name, bb_remove(Pattern)) :- !,
    blackboard:bb_take(Pattern),
    log_agent(Name, "Blackboard remove: ~w", [Pattern]).

% findall/3 - Standard findall
execute_body(Name, findall(T, Goal, L)) :- !,
    findall(T, execute_body(Name, Goal), L).

% Arithmetic and comparison - delegate directly
execute_body(_, X is Y) :- !, X is Y.
execute_body(_, X > Y) :- !, X > Y.
execute_body(_, X < Y) :- !, X < Y.
execute_body(_, X >= Y) :- !, X >= Y.
execute_body(_, X =< Y) :- !, X =< Y.
execute_body(_, X =:= Y) :- !, X =:= Y.
execute_body(_, X =\= Y) :- !, X =\= Y.
execute_body(_, X = Y) :- !, X = Y.
execute_body(_, X \= Y) :- !, X \= Y.
execute_body(_, X == Y) :- !, X == Y.
execute_body(_, X \== Y) :- !, X \== Y.

% write/nl/format - Allow direct I/O
execute_body(_, write(X)) :- !, write(X).
execute_body(_, writeln(X)) :- !, writeln(X).
execute_body(_, nl) :- !, nl.
execute_body(_, format(F, A)) :- !, format(F, A).
execute_body(_, print(X)) :- !, print(X).

% member/append/length and other list ops
execute_body(_, member(X, L)) :- !, member(X, L).
execute_body(_, append(A, B, C)) :- !, append(A, B, C).
execute_body(_, length(L, N)) :- !, length(L, N).
execute_body(_, msort(L, S)) :- !, msort(L, S).
execute_body(_, sort(L, S)) :- !, sort(L, S).
execute_body(_, nth0(N, L, E)) :- !, nth0(N, L, E).
execute_body(_, nth1(N, L, E)) :- !, nth1(N, L, E).
execute_body(_, last(L, E)) :- !, last(L, E).
execute_body(_, reverse(L, R)) :- !, reverse(L, R).
execute_body(_, flatten(L, F)) :- !, flatten(L, F).

% number_codes, atom_codes, atom_string, etc.
execute_body(_, number_codes(N, C)) :- !, number_codes(N, C).
execute_body(_, atom_codes(A, C)) :- !, atom_codes(A, C).
execute_body(_, atom_string(A, S)) :- !, atom_string(A, S).
execute_body(_, atom_concat(A, B, C)) :- !, atom_concat(A, B, C).
execute_body(_, number(X)) :- !, number(X).
execute_body(_, atom(X)) :- !, atom(X).
execute_body(_, is_list(X)) :- !, is_list(X).
execute_body(_, var(X)) :- !, var(X).
execute_body(_, nonvar(X)) :- !, nonvar(X).
execute_body(_, ground(X)) :- !, ground(X).
execute_body(_, functor(T, F, A)) :- !, functor(T, F, A).
execute_body(_, arg(N, T, A)) :- !, arg(N, T, A).
execute_body(_, copy_term(A, B)) :- !, copy_term(A, B).
execute_body(_, succ(A, B)) :- !, succ(A, B).
execute_body(_, plus(A, B, C)) :- !, plus(A, B, C).
execute_body(_, between(A, B, C)) :- !, between(A, B, C).
execute_body(_, sleep(T)) :- !, sleep(T).
execute_body(_, get_time(T)) :- !, get_time(T).

% --- DALI-style body predicates (runtime support) ---
% These handle DALI syntax that may appear in dynamically evaluated bodies.
% Most DALI syntax is transformed at load time by transform_body/2 in the loader,
% but these clauses provide runtime fallback support.

% messageA(Dest, send_message(Content, _Me)) → send(Dest, Content)
execute_body(Name, messageA(Dest, send_message(Content, _Me))) :- !,
    execute_body(Name, send(Dest, Content)).
execute_body(Name, messageA(Dest, send_message(Content))) :- !,
    execute_body(Name, send(Dest, Content)).

% evp(Event) → has_past(Event)
execute_body(Name, evp(Event)) :- !,
    execute_body(Name, has_past(Event)).

% tenta_residuo(Goal) → achieve(Goal)
execute_body(Name, tenta_residuo(Goal)) :- !,
    execute_body(Name, achieve(Goal)).

% Catch-all: try calling as a Prolog goal
execute_body(Name, Goal) :-
    catch(call(Goal), Error,
        (log_agent(Name, "Goal failed: ~w error: ~w", [Goal, Error]), fail)
    ).

%% ============================================================
%% CONDITION EVALUATION
%% ============================================================

call_condition(Name, (C1, C2)) :- !,
    call_condition(Name, C1),
    call_condition(Name, C2).
call_condition(Name, believes(Fact)) :- !,
    (agent_belief_rt(Name, Fact) -> true
    ; agent_belief_rt(Name, Other), ontology_match(Name, Fact, Other)
    ).
call_condition(Name, has_past(Event)) :- !,
    (agent_past_event(Name, Event, _, _) -> true
    ; event_in_past(Name, Event)
    ).
call_condition(Name, learned(Pattern, Outcome)) :- !,
    agent_learned_rt(Name, Pattern, Outcome).
call_condition(Name, onto_match(T1, T2)) :- !,
    ontology_match(Name, T1, T2).
call_condition(Name, has_remember(Event)) :- !,
    agent_remember(Name, Event, _, _).
call_condition(Name, has_confirmed(Fact)) :- !,
    agent_past_event(Name, confirmed(Fact), _, _).
call_condition(_Name, bb_read(Pattern)) :- !,
    blackboard:bb_get(Pattern).
call_condition(_, Cond) :-
    call(Cond).

%% ============================================================
%% PAST EVENT MEMORY
%% ============================================================

record_past(Name, Event, Timestamp) :-
    assert(agent_past_event(Name, Event, Timestamp, runtime)).

%% ============================================================
%% PAST EVENT LIFETIME & REMEMBER (Feature 2)
%% ============================================================

%% process_past_lifetime(+Name) - Expire past events and enforce remember limits
process_past_lifetime(Name) :-
    get_time(Now),
    NowMs is truncate(Now * 1000),
    % Check past events for expiration
    findall(pe(Ev, T, S), agent_past_event(Name, Ev, T, S), PastList),
    check_past_expirations(Name, PastList, NowMs),
    % Check remember events for expiration
    findall(re(Ev, T, S), agent_remember(Name, Ev, T, S), RemList),
    check_remember_expirations(Name, RemList, NowMs),
    % Enforce remember limits
    enforce_remember_limits(Name).

check_past_expirations(_, [], _).
check_past_expirations(Name, [pe(Ev, T, S)|Rest], NowMs) :-
    check_single_past_expiration(Name, Ev, T, S, NowMs),
    check_past_expirations(Name, Rest, NowMs).

check_single_past_expiration(Name, Ev, T, S, NowMs) :-
    unwrap_event_content(Ev, Content),
    (find_matching_lifetime(Name, Content, past, Duration) ->
        (Duration == forever ->
            true
        ;
            number(Duration),
            DurationMs is Duration * 1000,
            Age is NowMs - T,
            (Age > DurationMs ->
                retract(agent_past_event(Name, Ev, T, S)),
                % Move to remember if remember_lifetime exists
                (find_matching_lifetime(Name, Content, remember, _) ->
                    assert(agent_remember(Name, Ev, T, S))
                ;
                    true
                )
            ;
                true
            )
        )
    ;
        true  % no lifetime rule = keep forever
    ).

check_remember_expirations(_, [], _).
check_remember_expirations(Name, [re(Ev, T, S)|Rest], NowMs) :-
    check_single_remember_expiration(Name, Ev, T, S, NowMs),
    check_remember_expirations(Name, Rest, NowMs).

check_single_remember_expiration(Name, Ev, T, S, NowMs) :-
    unwrap_event_content(Ev, Content),
    (find_matching_lifetime(Name, Content, remember, Duration) ->
        (Duration == forever ->
            true
        ;
            number(Duration),
            DurationMs is Duration * 1000,
            Age is NowMs - T,
            (Age > DurationMs ->
                retract(agent_remember(Name, Ev, T, S))
            ;
                true
            )
        )
    ;
        true
    ).

%% find_matching_lifetime(+Name, +Content, +Type, -Duration)
find_matching_lifetime(Name, Content, past, Duration) :-
    loader:agent_past_lifetime(Name, Pattern, Duration),
    subsumes_term(Pattern, Content), !.
find_matching_lifetime(Name, Content, remember, Duration) :-
    loader:agent_remember_lifetime(Name, Pattern, Duration),
    subsumes_term(Pattern, Content), !.

%% unwrap_event_content(+WrappedEvent, -Content)
unwrap_event_content(received(C, _), C) :- !.
unwrap_event_content(injected(C), C) :- !.
unwrap_event_content(internal(C), C) :- !.
unwrap_event_content(confirmed(C), C) :- !.
unwrap_event_content(did(C), C) :- !.
unwrap_event_content(goal_achieved(C), C) :- !.
unwrap_event_content(C, C).

%% enforce_remember_limits(+Name) - Keep only N remember events per pattern
enforce_remember_limits(Name) :-
    forall(
        loader:agent_remember_limit(Name, Pattern, N, Mode),
        enforce_single_limit(Name, Pattern, N, Mode)
    ).

enforce_single_limit(Name, Pattern, N, Mode) :-
    findall(re(Ev, T, S),
        (agent_remember(Name, Ev, T, S), unwrap_event_content(Ev, C), subsumes_term(Pattern, C)),
        All),
    length(All, Len),
    (Len > N ->
        (Mode == last ->
            sort(2, @=<, All, Sorted),  % oldest first
            Remove is Len - N,
            take_n(Sorted, Remove, ToRemove)
        ;
            sort(2, @>=, All, Sorted),  % newest first
            Remove is Len - N,
            take_n(Sorted, Remove, ToRemove)
        ),
        remove_remember_entries(Name, ToRemove)
    ;
        true
    ).

take_n(_, 0, []) :- !.
take_n([], _, []) :- !.
take_n([H|T], N, [H|R]) :- N > 0, N1 is N - 1, take_n(T, N1, R).

remove_remember_entries(_, []).
remove_remember_entries(Name, [re(Ev, T, S)|Rest]) :-
    retract(agent_remember(Name, Ev, T, S)),
    remove_remember_entries(Name, Rest).

%% ============================================================
%% PAST REACTIONS - Export Past Rules (Feature 5)
%% ============================================================

%% process_past_reactions(+Name) - Fire rules when past event patterns match, consuming them
process_past_reactions(Name) :-
    process_past_basic(Name),
    process_past_done(Name),
    process_past_not_done(Name).

%% on_past: when all listed past events exist, consume and fire body
process_past_basic(Name) :-
    forall(
        loader:agent_past_reaction(Name, EventList, Body),
        try_past_reaction(Name, EventList, Body)
    ).

try_past_reaction(Name, EventList, Body) :-
    copy_term(EventList-Body, EL-B),
    (find_all_matching_past(Name, EL, Matches) ->
        consume_past_matches(Name, Matches),
        log_agent(Name, "Past reaction fired, consumed: ~w", [EL]),
        catch(
            execute_body(Name, B),
            Error,
            log_agent(Name, "Past reaction error: ~w", [Error])
        )
    ;
        true
    ).

%% on_past_done: fire only if action WAS done and past events match
process_past_done(Name) :-
    forall(
        loader:agent_past_done_reaction(Name, Action, EventList, Body),
        try_past_done_reaction(Name, Action, EventList, Body)
    ).

try_past_done_reaction(Name, Action, EventList, Body) :-
    copy_term(Action-EventList-Body, A-EL-B),
    (agent_past_event(Name, did(DidA), _, _), subsumes_term(A, DidA),
     find_all_matching_past(Name, EL, Matches) ->
        consume_past_matches(Name, Matches),
        log_agent(Name, "Past done reaction fired for ~w", [A]),
        catch(execute_body(Name, B), Error,
            log_agent(Name, "Past done reaction error: ~w", [Error]))
    ;
        true
    ).

%% on_past_not_done: fire only if action was NOT done and past events match
process_past_not_done(Name) :-
    forall(
        loader:agent_past_not_done_reaction(Name, Action, EventList, Body),
        try_past_not_done_reaction(Name, Action, EventList, Body)
    ).

try_past_not_done_reaction(Name, Action, EventList, Body) :-
    copy_term(Action-EventList-Body, A-EL-B),
    (\+ (agent_past_event(Name, did(DidA), _, _), subsumes_term(A, DidA)),
     find_all_matching_past(Name, EL, Matches) ->
        consume_past_matches(Name, Matches),
        log_agent(Name, "Past not_done reaction fired (action ~w not done)", [A]),
        catch(execute_body(Name, B), Error,
            log_agent(Name, "Past not_done reaction error: ~w", [Error]))
    ;
        true
    ).

%% find_all_matching_past(+Name, +PatternList, -Matches)
find_all_matching_past(_, [], []).
find_all_matching_past(Name, [Pattern|Rest], [match(Key, T, S)|Matches]) :-
    agent_past_event(Name, Key, T, S),
    unwrap_event_content(Key, Content),
    Pattern = Content,
    find_all_matching_past(Name, Rest, Matches).

%% consume_past_matches(+Name, +Matches)
consume_past_matches(_, []).
consume_past_matches(Name, [match(Key, T, S)|Rest]) :-
    (retract(agent_past_event(Name, Key, T, S)) -> true ; true),
    consume_past_matches(Name, Rest).

%% ============================================================
%% RESIDUE GOALS (Feature 6)
%% ============================================================

%% process_residue_goals(+Name) - Retry goals that are queued as residue
process_residue_goals(Name) :-
    findall(rg(GoalId, Goal), agent_residue_goal(Name, GoalId, Goal), Residues),
    process_residue_list(Name, Residues).

process_residue_list(_, []).
process_residue_list(Name, [rg(GoalId, Goal)|Rest]) :-
    (catch(call_condition(Name, Goal), _, fail) ->
        retractall(agent_residue_goal(Name, GoalId, _)),
        retractall(agent_goal_status(Name, GoalId, _)),
        assert(agent_goal_status(Name, GoalId, achieved)),
        log_agent(Name, "Residue goal achieved: ~w", [Goal]),
        get_time(Stamp), T is truncate(Stamp * 1000),
        record_past(Name, goal_achieved(Goal), T)
    ;
        true  % still pending, retry next cycle
    ),
    process_residue_list(Name, Rest).

%% ============================================================
%% ONTOLOGY FILE LOADING (Feature 10)
%% ============================================================

%% load_agent_ontology_files(+Name) - Load ontology declarations from files
load_agent_ontology_files(Name) :-
    forall(
        loader:agent_ontology_file(Name, File),
        load_ontology_file(Name, File)
    ).

load_ontology_file(Name, File) :-
    (exists_file(File) ->
        setup_call_cleanup(
            open(File, read, Stream, []),
            read_ontology_terms(Name, Stream),
            close(Stream)
        ),
        log_agent(Name, "Loaded ontology file: ~w", [File])
    ;
        log_agent(Name, "WARNING: Ontology file not found: ~w", [File])
    ).

read_ontology_terms(Name, Stream) :-
    read_term(Stream, Term, []),
    (Term == end_of_file ->
        true
    ;
        (process_ontology_term(Name, Term) -> true ; true),
        read_ontology_terms(Name, Stream)
    ).

process_ontology_term(Name, same_as(A, B)) :- !,
    assert(loader:agent_ontology(Name, same_as(A, B))).
process_ontology_term(Name, eq_property(A, B)) :- !,
    assert(loader:agent_ontology(Name, eq_property(A, B))).
process_ontology_term(Name, eq_class(A, B)) :- !,
    assert(loader:agent_ontology(Name, eq_class(A, B))).
process_ontology_term(Name, symmetric(R)) :- !,
    assert(loader:agent_ontology(Name, symmetric(R))).
process_ontology_term(_, _).  % ignore unknown terms

%% ============================================================
%% LOGGING
%% ============================================================

log_agent(Name, Message) :-
    get_time(Stamp),
    T is truncate(Stamp * 1000),
    assert(agent_log_entry(Name, T, Message)),
    get_time(Now),
    stamp_date_time(Now, date(_Y,_Mo,_D,H,Mi,S,_,_,_), local),
    Sec is truncate(S),
    format(atom(TimeStr), "~|~`0t~d~2+:~|~`0t~d~2+:~|~`0t~d~2+", [H, Mi, Sec]),
    format(user_error, "[~w] [~w] ~w~n", [TimeStr, Name, Message]).

log_agent(Name, Format, Args) :-
    catch(
        (format(atom(Msg), Format, Args),
         log_agent(Name, Msg)),
        _,
        log_agent(Name, Format)
    ).
