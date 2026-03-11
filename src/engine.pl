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
    all_logs/1
]).

:- use_module(blackboard).
:- use_module(communication).
:- use_module(loader).
:- use_module(ai_oracle).
:- use_module(library(lists)).

%% Agent runtime state (thread-local per agent, but stored globally with agent name key)
:- dynamic agent_running/1.            % agent_running(Name)
:- dynamic agent_thread/2.             % agent_thread(Name, ThreadId)
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

%% start_agent(+Name) - Start a single agent thread
start_agent(Name) :-
    (agent_running(Name) ->
        log_agent(Name, "Agent already running")
    ;
        loader:agent_def(Name, Options),
        assert(agent_running(Name)),
        bb_register_agent(Name, Options),
        % Assert initial beliefs
        forall(loader:agent_belief(Name, Fact),
            assert(agent_belief_rt(Name, Fact))
        ),
        atom_concat('agent_', Name, ThreadId),
        thread_create(agent_loop(Name, Options), _Tid,
            [alias(ThreadId), detached(false)]),
        assert(agent_thread(Name, ThreadId)),
        log_agent(Name, "Agent started")
    ).

%% stop_agent(+Name) - Stop a single agent
stop_agent(Name) :-
    (agent_running(Name) ->
        retract(agent_running(Name)),
        bb_unregister_agent(Name),
        (agent_thread(Name, Tid) ->
            retract(agent_thread(Name, Tid)),
            catch(thread_signal(Tid, throw(stop_agent)), _, true),
            catch(thread_join(Tid, _), _, true)
        ; true),
        log_agent(Name, "Agent stopped")
    ; true).

%% inject_event(+AgentName, +Event) - Inject an external event into an agent
inject_event(AgentName, Event) :-
    with_mutex(blackboard_mutex,
        assert(agent_event_queue(AgentName, Event))
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
        % 1. Process incoming messages (external events)
        process_messages(Name),
        % 2. Process injected events
        process_injected_events(Name),
        % 3. Process internal events (proactive)
        process_internals(Name),
        % 4. Process periodic tasks
        process_periodics(Name),
        % 5. Process condition monitors (level-triggered)
        process_monitors(Name),
        % 6. Process condition-action rules (edge-triggered)
        process_condition_actions(Name),
        % 7. Process present/environment events
        process_present_events(Name),
        % 8. Process multi-events
        process_multi_events(Name),
        % 9. Check constraints
        process_constraints(Name),
        % 10. Process goals
        process_goals(Name),
        % 11. Sleep for cycle duration
        get_cycle_ms(Options, SleepMs),
        SleepSec is SleepMs / 1000,
        sleep(SleepSec),
        agent_loop_inner(Name, Options)
    ;
        true
    ).

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

%% process_messages(+Name) - Receive and process all pending messages
process_messages(Name) :-
    communication:receive_all(Name, Messages),
    process_message_list(Name, Messages).

process_message_list(_, []).
process_message_list(Name, [message(From, Content, T) | Rest]) :-
    (should_allow_receive(Name, Content, _Priority) ->
        log_agent(Name, "Received from ~w: ~w", [From, Content]),
        record_past(Name, received(Content, From), T),
        fire_handlers(Name, Content),
        fire_learning(Name, Content)
    ;
        log_agent(Name, "Message rejected by told rule: ~w from ~w", [Content, From])
    ),
    process_message_list(Name, Rest).

%% process_injected_events(+Name) - Process events from the inject queue
process_injected_events(Name) :-
    findall(Ev,
        with_mutex(blackboard_mutex,
            retract(agent_event_queue(Name, Ev))
        ),
        Events),
    process_injected_list(Name, Events).

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
    (should_fire_internal(Name, InternalId, Options, Now) ->
        catch(
            (copy_term(Event-Body, _ECopy-BodyCopy),
             execute_body(Name, BodyCopy),
             increment_internal_count(Name, InternalId),
             get_time(Stamp), T is truncate(Stamp * 1000),
             record_past(Name, internal(Event), T),
             fire_learning(Name, Event)),
            Error,
            log_agent(Name, "Internal event error: ~w", [Error])
        )
    ; true).

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
process_multi_events(Name) :-
    forall(
        loader:agent_multi_event(Name, EventList, Body),
        (term_to_atom(EventList, MultiId),
         (all_events_occurred(Name, EventList) ->
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

all_events_occurred(_, []).
all_events_occurred(Name, [Event|Rest]) :-
    event_in_past(Name, Event),
    all_events_occurred(Name, Rest).

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

%% should_allow_send(+Sender, +Content) - Check sender's tell rules
should_allow_send(Sender, Content) :-
    (   \+ loader:agent_tell(Sender, _)
    ->  true
    ;   loader:agent_tell(Sender, Pattern),
        subsumes_term(Pattern, Content)
    ).

%% should_allow_receive(+Receiver, +Content, -Priority) - Check receiver's told rules
should_allow_receive(Receiver, Content, Priority) :-
    (   \+ loader:agent_told(Receiver, _, _)
    ->  Priority = 0
    ;   loader:agent_told(Receiver, Pattern, Priority),
        subsumes_term(Pattern, Content)
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
execute_body(_, \+(Goal)) :- !,
    \+(call(Goal)).
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
    (agent_belief_rt(Name, Fact) -> true
    ; agent_belief_rt(Name, Other), ontology_match(Name, Fact, Other)
    ).

% has_past(Event) - Check if event is in past
execute_body(Name, has_past(Event)) :- !,
    agent_past_event(Name, Event, _, _).

% has_past(Event, Time) - Check past with time
execute_body(Name, has_past(Event, Time)) :- !,
    agent_past_event(Name, Event, Time, _).

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

% achieve(Goal) - Manually trigger an achieve goal
execute_body(Name, achieve(Goal)) :- !,
    process_single_goal(Name, achieve, Goal, true).

% reset_goal(Goal) - Reset a goal so it can be re-attempted
execute_body(Name, reset_goal(Goal)) :- !,
    term_to_atom(Goal, GoalId),
    retractall(agent_goal_status(Name, GoalId, _)),
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
