%% DALI2 Agent Process - Standalone agent runner (one OS process per agent)
%% Each agent runs as a separate SWI-Prolog process.
%% Communicates via Redis pub/sub (star topology):
%%   - LINDA channel: all agents subscribe; messages as "TO:CONTENT:FROM"
%%   - LOGS channel: agents publish log entries for monitoring
%%   - BB (Redis SET): shared blackboard (replaces Linda tuple space)
%%
%% Usage:
%%   swipl -l src/agent_process.pl -g agent_main -t halt -- \
%%     <agent_name> <agent_file>

:- module(agent_process, [agent_main/0]).

:- use_module(library(lists)).

:- use_module(loader).
:- use_module(ai_oracle).
:- use_module(redis_comm).

%% Suppress informational messages
:- multifile user:message_hook/3.
user:message_hook(_, informational, _) :- !.

%% ============================================================
%% AGENT STATE (process-local)
%% ============================================================
:- dynamic agent_name/1.
:- dynamic agent_running/0.
:- dynamic agent_event_queue/1.          % agent_event_queue(Event)
:- dynamic agent_past_event/3.           % agent_past_event(Event, Timestamp, Source)
:- dynamic agent_belief_rt/1.            % agent_belief_rt(Fact)
:- dynamic agent_log_entry/2.            % agent_log_entry(Timestamp, Message)
:- dynamic agent_internal_count/2.       % agent_internal_count(InternalId, Count)
:- dynamic agent_condition_state/2.      % agent_condition_state(CondId, true/false)
:- dynamic agent_multi_fired/1.          % agent_multi_fired(MultiId)
:- dynamic agent_learned_rt/2.           % agent_learned_rt(Pattern, Outcome)
:- dynamic agent_goal_status/2.          % agent_goal_status(GoalId, Status)
:- dynamic agent_last_internal_fire/2.   % agent_last_internal_fire(InternalId, LastTime)
:- dynamic agent_internal_snapshot/2.    % agent_internal_snapshot(InternalId, Snapshot)
:- dynamic agent_remember_ev/3.          % agent_remember_ev(Event, Timestamp, Source)
:- dynamic agent_current_sender/1.       % agent_current_sender(Sender)
:- dynamic agent_residue_goal/2.         % agent_residue_goal(GoalId, Goal)
:- dynamic agent_last_periodic/2.        % agent_last_periodic(PeriodicId, LastTime)

%% ============================================================
%% MAIN ENTRY POINT
%% ============================================================

agent_main :-
    set_prolog_flag(color_term, false),
    current_prolog_flag(argv, Argv),
    parse_agent_args(Argv, Name, AgentFile),
    assert(agent_name(Name)),
    format(user_error, "[~w] Starting agent process~n", [Name]),
    %% Load agent definitions
    loader:load_agents(AgentFile),
    %% Initialize beliefs
    (loader:agent_def(Name, _Options) ->
        forall(loader:agent_belief(Name, Fact), assert(agent_belief_rt(Fact))),
        load_agent_ontology_files_local(Name)
    ;
        format(user_error, "[~w] WARNING: Agent not found in file ~w~n", [Name, AgentFile])
    ),
    assert(agent_running),
    %% Connect to Redis and subscribe to LINDA channel
    redis_comm:redis_init,
    redis_comm:redis_subscribe_linda(Name),
    format(user_error, "[~w] Agent process started (Redis)~n", [Name]),
    agent_loop.

parse_agent_args(Argv, Name, AgentFile) :-
    nth0(0, Argv, NameAtom), Name = NameAtom,
    nth0(1, Argv, AgentFile).

%% ============================================================
%% AGENT EVENT LOOP
%% ============================================================

agent_loop :-
    (agent_running ->
        agent_name(Name),
        loader:agent_def(Name, Options),
        safe_step(process_messages_local(Name)),
        safe_step(process_injected_events_local(Name)),
        safe_step(process_internals_local(Name)),
        safe_step(process_periodics_local(Name)),
        safe_step(process_monitors_local(Name)),
        safe_step(process_condition_actions_local(Name)),
        safe_step(process_present_events_local(Name)),
        safe_step(process_multi_events_local(Name)),
        safe_step(process_past_reactions_local(Name)),
        safe_step(process_constraints_local(Name)),
        safe_step(process_goals_local(Name)),
        safe_step(process_residue_goals_local(Name)),
        safe_step(process_past_lifetime_local(Name)),
        get_cycle_ms(Options, SleepMs),
        SleepSec is SleepMs / 1000,
        sleep(SleepSec),
        agent_loop
    ;
        true
    ).

safe_step(Goal) :-
    (catch(Goal, _, true) -> true ; true).

get_cycle_ms(Options, Ms) :-
    (member(cycle(S), Options) ->
        (number(S) -> Ms is S * 1000 ; Ms = 1000)
    ;
        Ms = 1000
    ).

%% ============================================================
%% MESSAGE PROCESSING
%% ============================================================

process_messages_local(Name) :-
    redis_comm:redis_poll_messages(Name, Messages),
    prioritize_messages_local(Name, Messages, Sorted),
    process_message_list_local(Name, Sorted).

prioritize_messages_local(Name, Messages, Sorted) :-
    assign_priorities_local(Name, Messages, Prioritized),
    sort(1, @>=, Prioritized, SortedPairs),
    pairs_values(SortedPairs, Sorted).

assign_priorities_local(_, [], []).
assign_priorities_local(Name, [Msg|Rest], [P-Msg|PRest]) :-
    Msg = message(_, Content, _),
    (loader:agent_told(Name, Pattern, Priority),
     subsumes_term(Pattern, Content) ->
        P = Priority
    ;
        P = 0
    ),
    assign_priorities_local(Name, Rest, PRest).

process_message_list_local(_, []).
process_message_list_local(Name, [message(From, Content, T) | Rest]) :-
    (should_allow_receive_local(Name, Content, _Priority) ->
        log_local(Name, "Received from ~w: ~w", [From, Content]),
        record_past_local(received(Content, From), T),
        retractall(agent_current_sender(_)),
        assert(agent_current_sender(From)),
        handle_fipa_semantics_local(Name, From, Content, T),
        fire_handlers_local(Name, Content),
        fire_learning_local(Name, Content),
        retractall(agent_current_sender(_))
    ;
        log_local(Name, "Message rejected by told rule: ~w from ~w", [Content, From])
    ),
    process_message_list_local(Name, Rest).

should_allow_receive_local(Receiver, Content, Priority) :-
    (   \+ loader:agent_told(Receiver, _, _)
    ->  Priority = 0
    ;   loader:agent_told(Receiver, Pattern, Priority),
        subsumes_term(Pattern, Content)
    ).

should_allow_send_local(Sender, Content) :-
    (   \+ loader:agent_tell(Sender, _)
    ->  true
    ;   loader:agent_tell(Sender, Pattern),
        subsumes_term(Pattern, Content)
    ).

%% ============================================================
%% FIPA SEMANTICS
%% ============================================================

handle_fipa_semantics_local(Name, _From, confirm(Fact), T) :- !,
    record_past_local(confirmed(Fact), T),
    log_local(Name, "Fact confirmed: ~w", [Fact]).
handle_fipa_semantics_local(Name, _From, disconfirm(Fact), _T) :- !,
    retractall(agent_past_event(confirmed(Fact), _, _)),
    log_local(Name, "Fact disconfirmed: ~w", [Fact]).
handle_fipa_semantics_local(Name, From, query_ref(Query), _T) :- !,
    findall(Query, agent_belief_rt(Query), Results),
    redis_comm:redis_publish_linda(Name, From, inform(query_ref(Query), values(Results))),
    log_local(Name, "Query_ref response to ~w: ~w", [From, Results]).
handle_fipa_semantics_local(Name, From, propose(Action), _T) :- !,
    fire_proposal_handlers_local(Name, From, Action).
handle_fipa_semantics_local(_, _, _, _).

fire_proposal_handlers_local(Name, From, Action) :-
    forall(
        loader:agent_on_proposal(Name, Pattern, Body),
        (copy_term(Pattern-Body, ActionCopy-BodyCopy),
         (ActionCopy = Action ->
            retractall(agent_current_sender(_)),
            assert(agent_current_sender(From)),
            catch(execute_body_local(Name, BodyCopy), Error,
                log_local(Name, "Proposal handler error: ~w", [Error]))
         ; true))
    ).

%% ============================================================
%% EVENT HANDLERS
%% ============================================================

fire_handlers_local(Name, Event) :-
    findall(Pattern-Body, loader:agent_handler(Name, Pattern, Body), Handlers),
    fire_handler_list_local(Name, Event, Handlers).

fire_handler_list_local(_, _, []).
fire_handler_list_local(Name, Event, [Pattern-Body | Rest]) :-
    (copy_term(Pattern-Body, EventCopy-BodyCopy),
     (EventCopy = Event ; ontology_match_local(Name, EventCopy, Event)) ->
        catch(execute_body_local(Name, BodyCopy), Error,
            log_local(Name, "Handler error for ~w: ~w", [Event, Error]))
    ; true),
    fire_handler_list_local(Name, Event, Rest).

%% ============================================================
%% INJECTED EVENTS
%% ============================================================

process_injected_events_local(Name) :-
    collect_event_queue_local(Events),
    process_injected_list_local(Name, Events).

collect_event_queue_local([Ev|Rest]) :-
    with_mutex(agent_queue_mutex, retract(agent_event_queue(Ev))), !,
    collect_event_queue_local(Rest).
collect_event_queue_local([]).

process_injected_list_local(_, []).
process_injected_list_local(Name, [Event | Rest]) :-
    get_time(Stamp), T is truncate(Stamp * 1000),
    record_past_local(injected(Event), T),
    fire_handlers_local(Name, Event),
    fire_learning_local(Name, Event),
    process_injected_list_local(Name, Rest).

%% ============================================================
%% INTERNAL EVENTS
%% ============================================================

process_internals_local(Name) :-
    get_time(Now),
    forall(
        loader:agent_internal(Name, Event, Options, Body),
        process_single_internal_local(Name, Event, Options, Body, Now)
    ).

process_single_internal_local(Name, Event, Options, Body, Now) :-
    term_to_atom(Event, InternalId),
    process_change_condition_local(InternalId, Options),
    (should_fire_internal_local(InternalId, Options, Now) ->
        (catch(
            (copy_term(Event-Body, _ECopy-BodyCopy),
             execute_body_local(Name, BodyCopy),
             increment_internal_count_local(InternalId),
             retractall(agent_last_internal_fire(InternalId, _)),
             assert(agent_last_internal_fire(InternalId, Now)),
             get_time(Stamp), T is truncate(Stamp * 1000),
             record_past_local(internal(Event), T),
             fire_learning_local(Name, Event)),
            Error,
            log_local(Name, "Internal event error: ~w", [Error])
        ) -> true ; true)
    ; true).

process_change_condition_local(InternalId, Options) :-
    (member(change(FactList), Options) ->
        get_fact_snapshot_local(FactList, CurrentSnapshot),
        (agent_internal_snapshot(InternalId, OldSnapshot) ->
            (CurrentSnapshot \== OldSnapshot ->
                retractall(agent_internal_count(InternalId, _)),
                retractall(agent_internal_snapshot(InternalId, _)),
                assert(agent_internal_snapshot(InternalId, CurrentSnapshot))
            ; true)
        ;
            assert(agent_internal_snapshot(InternalId, CurrentSnapshot))
        )
    ; true).

get_fact_snapshot_local(FactList, Snapshot) :-
    maplist(get_single_fact_local, FactList, Snapshot).

get_single_fact_local(Fact, Value) :-
    (agent_belief_rt(Fact) -> Value = present(Fact)
    ; (agent_past_event(Fact, T, _) -> Value = past(Fact, T)
      ; Value = absent(Fact))).

should_fire_internal_local(InternalId, Options, Now) :-
    (Options = [] -> true ;
     is_list(Options) -> check_all_opts_local(InternalId, Options, Now) ;
     check_single_opt_local(InternalId, Options, Now)).

check_all_opts_local(_, [], _).
check_all_opts_local(Id, [Opt|Rest], Now) :-
    check_single_opt_local(Id, Opt, Now),
    check_all_opts_local(Id, Rest, Now).

check_single_opt_local(_, forever, _).
check_single_opt_local(Id, times(N), _) :-
    (agent_internal_count(Id, Count) -> Count < N ; true).
check_single_opt_local(_, until(Condition), _) :-
    \+ call_condition_local(Condition).
check_single_opt_local(_, between(time(H1,M1), time(H2,M2)), Now) :-
    stamp_date_time(Now, DateTime, local),
    date_time_value(hour, DateTime, H),
    date_time_value(minute, DateTime, M),
    CurrentMinutes is H * 60 + M,
    StartMinutes is H1 * 60 + M1,
    EndMinutes is H2 * 60 + M2,
    CurrentMinutes >= StartMinutes,
    CurrentMinutes =< EndMinutes.
check_single_opt_local(_, trigger(Condition), _) :-
    catch(call_condition_local(Condition), _, fail).
check_single_opt_local(Id, interval(Seconds), _Now) :-
    (agent_last_internal_fire(Id, LastFire) ->
        get_time(Now2), Elapsed is Now2 - LastFire, Elapsed >= Seconds
    ; true).
check_single_opt_local(_, change(_), _).
check_single_opt_local(_, between(date(Y1,Mo1,D1), date(Y2,Mo2,D2)), Now) :-
    stamp_date_time(Now, DateTime, local),
    date_time_value(year, DateTime, Y),
    date_time_value(month, DateTime, Mo),
    date_time_value(day, DateTime, D),
    DayCurrent is Y * 10000 + Mo * 100 + D,
    DayStart is Y1 * 10000 + Mo1 * 100 + D1,
    DayEnd is Y2 * 10000 + Mo2 * 100 + D2,
    DayCurrent >= DayStart, DayCurrent =< DayEnd.

increment_internal_count_local(InternalId) :-
    (retract(agent_internal_count(InternalId, N)) ->
        N1 is N + 1, assert(agent_internal_count(InternalId, N1))
    ;
        assert(agent_internal_count(InternalId, 1))
    ).

%% ============================================================
%% PERIODICS, MONITORS, CONDITION-ACTIONS, PRESENT, MULTI, CONSTRAINTS, GOALS
%% (Simplified — same logic as engine.pl but using process-local state)
%% ============================================================

process_periodics_local(Name) :-
    get_time(Now),
    forall(loader:agent_periodic(Name, Seconds, Body),
        (term_to_atom(Body, PeriodicId),
         (agent_last_periodic(PeriodicId, Last) ->
            Elapsed is Now - Last,
            (Elapsed >= Seconds ->
                retract(agent_last_periodic(PeriodicId, Last)),
                assert(agent_last_periodic(PeriodicId, Now)),
                catch(execute_body_local(Name, Body), _, true)
            ; true)
         ;
            assert(agent_last_periodic(PeriodicId, Now)),
            catch(execute_body_local(Name, Body), _, true)
         ))).

process_monitors_local(Name) :-
    forall(loader:agent_monitor(Name, Condition, Body),
        (catch((call_condition_local(Condition) ->
            catch(execute_body_local(Name, Body), _, true) ; true), _, true))).

process_condition_actions_local(Name) :-
    forall(loader:agent_condition_action(Name, Condition, Body),
        (term_to_atom(Condition, CondId),
         catch((call_condition_local(Condition) ->
            (agent_condition_state(CondId, true) -> true ;
                retractall(agent_condition_state(CondId, _)),
                assert(agent_condition_state(CondId, true)),
                catch(execute_body_local(Name, Body), _, true))
         ;
            retractall(agent_condition_state(CondId, _)),
            assert(agent_condition_state(CondId, false))
         ), _, true))).

process_present_events_local(Name) :-
    forall(loader:agent_present(Name, Condition, Body),
        (catch((call_condition_local(Condition) ->
            catch(execute_body_local(Name, Body), _, true) ; true), _, true))).

process_multi_events_local(Name) :-
    forall(loader:agent_multi_event(Name, EventList, Body),
        (term_to_atom(EventList, MultiId),
         (all_events_occurred_local(EventList) ->
            (agent_multi_fired(MultiId) -> true ;
                assert(agent_multi_fired(MultiId)),
                catch(execute_body_local(Name, Body), _, true))
         ;
            retractall(agent_multi_fired(MultiId))
         ))).

all_events_occurred_local([]).
all_events_occurred_local([Event|Rest]) :-
    event_in_past_local(Event),
    all_events_occurred_local(Rest).

event_in_past_local(Event) :-
    agent_past_event(received(Event, _), _, _), !.
event_in_past_local(Event) :-
    agent_past_event(injected(Event), _, _), !.
event_in_past_local(Event) :-
    agent_past_event(internal(Event), _, _), !.
event_in_past_local(Event) :-
    agent_past_event(Event, _, _), !.

process_constraints_local(Name) :-
    forall(loader:agent_constraint(Name, Condition, Body),
        (copy_term(Condition-Body, TestCond-_),
         (catch(call_condition_local(TestCond), _, fail) -> true ;
            copy_term(Condition-Body, BCond-BBody),
            attempt_bind_local(BCond),
            log_local(Name, "Constraint violated: ~w", [BCond]),
            (BBody \== true ->
                catch(execute_body_local(Name, BBody), _, true) ; true)))).

attempt_bind_local((C1, C2)) :- !, attempt_bind_local(C1), attempt_bind_local(C2).
attempt_bind_local(believes(Fact)) :- !, (agent_belief_rt(Fact) -> true ; true).
attempt_bind_local(has_past(Event)) :- !, (agent_past_event(Event, _, _) -> true ; true).
attempt_bind_local(learned(P, O)) :- !, (agent_learned_rt(P, O) -> true ; true).
attempt_bind_local(_).

process_goals_local(Name) :-
    forall(loader:agent_goal(Name, Type, Goal, Plan),
        process_single_goal_local(Name, Type, Goal, Plan)).

goal_canonical_id_local(Goal, GoalId) :-
    copy_term(Goal, GCopy), numbervars(GCopy, 0, _), term_to_atom(GCopy, GoalId).

process_single_goal_local(Name, achieve, Goal, Plan) :-
    goal_canonical_id_local(Goal, GoalId),
    (agent_goal_status(GoalId, achieved) -> true ;
        (call_condition_local(Goal) ->
            retractall(agent_goal_status(GoalId, _)),
            assert(agent_goal_status(GoalId, achieved)),
            log_local(Name, "Goal achieved: ~w", [Goal]),
            get_time(Stamp), T is truncate(Stamp * 1000),
            record_past_local(goal_achieved(Goal), T)
        ;
            catch(execute_body_local(Name, Plan), _, true)
        )).

process_single_goal_local(Name, test, Goal, Plan) :-
    goal_canonical_id_local(Goal, GoalId),
    (agent_goal_status(GoalId, _) -> true ;
        catch((execute_body_local(Name, Plan) ->
            (call_condition_local(Goal) ->
                assert(agent_goal_status(GoalId, succeeded)),
                log_local(Name, "Test goal succeeded: ~w", [Goal])
            ;
                assert(agent_goal_status(GoalId, failed)),
                log_local(Name, "Test goal failed: ~w", [Goal]))
        ;
            assert(agent_goal_status(GoalId, failed)),
            log_local(Name, "Test goal plan failed: ~w", [Goal])
        ), Error,
            (assert(agent_goal_status(GoalId, error)),
             log_local(Name, "Test goal error: ~w", [Error]))
        )).

process_residue_goals_local(Name) :-
    findall(rg(GoalId, Goal), agent_residue_goal(GoalId, Goal), Residues),
    process_residue_list_local(Name, Residues).

process_residue_list_local(_, []).
process_residue_list_local(Name, [rg(GoalId, Goal)|Rest]) :-
    (catch(call_condition_local(Goal), _, fail) ->
        retractall(agent_residue_goal(GoalId, _)),
        retractall(agent_goal_status(GoalId, _)),
        assert(agent_goal_status(GoalId, achieved)),
        log_local(Name, "Residue goal achieved: ~w", [Goal]),
        get_time(Stamp), T is truncate(Stamp * 1000),
        record_past_local(goal_achieved(Goal), T)
    ; true),
    process_residue_list_local(Name, Rest).

process_past_lifetime_local(Name) :-
    get_time(Now), NowMs is truncate(Now * 1000),
    findall(pe(Ev, T, S), agent_past_event(Ev, T, S), PastList),
    check_past_expirations_local(Name, PastList, NowMs),
    findall(re(Ev, T, S), agent_remember_ev(Ev, T, S), RemList),
    check_remember_expirations_local(Name, RemList, NowMs).

check_past_expirations_local(_, [], _).
check_past_expirations_local(Name, [pe(Ev, T, S)|Rest], NowMs) :-
    unwrap_event_content_local(Ev, Content),
    (find_matching_lifetime_local(Name, Content, past, Duration) ->
        (Duration == forever -> true ;
            number(Duration), DurationMs is Duration * 1000, Age is NowMs - T,
            (Age > DurationMs ->
                retract(agent_past_event(Ev, T, S)),
                (find_matching_lifetime_local(Name, Content, remember, _) ->
                    assert(agent_remember_ev(Ev, T, S)) ; true)
            ; true))
    ; true),
    check_past_expirations_local(Name, Rest, NowMs).

check_remember_expirations_local(_, [], _).
check_remember_expirations_local(Name, [re(Ev, T, S)|Rest], NowMs) :-
    unwrap_event_content_local(Ev, Content),
    (find_matching_lifetime_local(Name, Content, remember, Duration) ->
        (Duration == forever -> true ;
            number(Duration), DurationMs is Duration * 1000, Age is NowMs - T,
            (Age > DurationMs -> retract(agent_remember_ev(Ev, T, S)) ; true))
    ; true),
    check_remember_expirations_local(Name, Rest, NowMs).

find_matching_lifetime_local(Name, Content, past, Duration) :-
    loader:agent_past_lifetime(Name, Pattern, Duration), subsumes_term(Pattern, Content), !.
find_matching_lifetime_local(Name, Content, remember, Duration) :-
    loader:agent_remember_lifetime(Name, Pattern, Duration), subsumes_term(Pattern, Content), !.

unwrap_event_content_local(received(C, _), C) :- !.
unwrap_event_content_local(injected(C), C) :- !.
unwrap_event_content_local(internal(C), C) :- !.
unwrap_event_content_local(confirmed(C), C) :- !.
unwrap_event_content_local(did(C), C) :- !.
unwrap_event_content_local(goal_achieved(C), C) :- !.
unwrap_event_content_local(C, C).

%% ============================================================
%% PAST REACTIONS
%% ============================================================

process_past_reactions_local(Name) :-
    forall(loader:agent_past_reaction(Name, EventList, Body),
        try_past_reaction_local(Name, EventList, Body)),
    forall(loader:agent_past_done_reaction(Name, Action, EventList, Body),
        try_past_done_reaction_local(Name, Action, EventList, Body)),
    forall(loader:agent_past_not_done_reaction(Name, Action, EventList, Body),
        try_past_not_done_reaction_local(Name, Action, EventList, Body)).

try_past_reaction_local(Name, EventList, Body) :-
    copy_term(EventList-Body, EL-B),
    (find_all_matching_past_local(EL, Matches) ->
        consume_past_matches_local(Matches),
        catch(execute_body_local(Name, B), _, true)
    ; true).

try_past_done_reaction_local(Name, Action, EventList, Body) :-
    copy_term(Action-EventList-Body, A-EL-B),
    (agent_past_event(did(DidA), _, _), subsumes_term(A, DidA),
     find_all_matching_past_local(EL, Matches) ->
        consume_past_matches_local(Matches),
        catch(execute_body_local(Name, B), _, true)
    ; true).

try_past_not_done_reaction_local(Name, Action, EventList, Body) :-
    copy_term(Action-EventList-Body, A-EL-B),
    (\+ (agent_past_event(did(DidA), _, _), subsumes_term(A, DidA)),
     find_all_matching_past_local(EL, Matches) ->
        consume_past_matches_local(Matches),
        catch(execute_body_local(Name, B), _, true)
    ; true).

find_all_matching_past_local([], []).
find_all_matching_past_local([Pattern|Rest], [match(Key, T, S)|Matches]) :-
    agent_past_event(Key, T, S),
    unwrap_event_content_local(Key, Content),
    Pattern = Content,
    find_all_matching_past_local(Rest, Matches).

consume_past_matches_local([]).
consume_past_matches_local([match(Key, T, S)|Rest]) :-
    (retract(agent_past_event(Key, T, S)) -> true ; true),
    consume_past_matches_local(Rest).

%% ============================================================
%% LEARNING
%% ============================================================

fire_learning_local(Name, Event) :-
    forall(loader:agent_learn_rule(Name, EventPattern, Outcome, Body),
        (copy_term(EventPattern-Outcome-Body, ECopy-OCopy-BCopy),
         (ECopy = Event ->
            catch((execute_body_local(Name, BCopy) ->
                assert(agent_learned_rt(Event, OCopy)),
                log_local(Name, "Learned from ~w: ~w", [Event, OCopy])
            ; true), _, true)
         ; true))).

%% ============================================================
%% BODY EXECUTION (process-local version)
%% ============================================================

execute_body_local(_, true) :- !.
execute_body_local(Name, (A, B)) :- !, execute_body_local(Name, A), execute_body_local(Name, B).
execute_body_local(Name, (A ; B)) :- !,
    (nonvar(A), A = (Cond -> Then) ->
        (execute_body_local(Name, Cond) -> execute_body_local(Name, Then) ; execute_body_local(Name, B))
    ; (execute_body_local(Name, A) ; execute_body_local(Name, B))).
execute_body_local(Name, (Cond -> Then)) :- !,
    (execute_body_local(Name, Cond) -> execute_body_local(Name, Then) ; true).
execute_body_local(Name, \+(Goal)) :- !, \+(execute_body_local(Name, Goal)).
execute_body_local(Name, not(Goal)) :- !, \+(execute_body_local(Name, Goal)).

%% Communication — send via Redis LINDA channel
execute_body_local(Name, send(To, Content)) :- !,
    (should_allow_send_local(Name, Content) ->
        redis_comm:redis_publish_linda(Name, To, Content),
        log_local(Name, "Sent to ~w: ~w", [To, Content])
    ;
        log_local(Name, "Send blocked by tell rule: ~w to ~w", [Content, To])
    ).
execute_body_local(Name, broadcast(Content)) :- !,
    redis_comm:redis_publish_linda(Name, '*', Content),
    log_local(Name, "Broadcast: ~w", [Content]).

%% Logging
execute_body_local(Name, log(Format, Args)) :- !,
    catch((format(atom(Msg), Format, Args), log_local(Name, Msg)), _, log_local(Name, Format)).
execute_body_local(Name, log(Message)) :- !,
    log_local(Name, "~w", [Message]).

%% Beliefs
execute_body_local(Name, assert_belief(Fact)) :- !,
    assert(agent_belief_rt(Fact)), log_local(Name, "Belief added: ~w", [Fact]).
execute_body_local(Name, retract_belief(Fact)) :- !,
    retractall(agent_belief_rt(Fact)), log_local(Name, "Belief removed: ~w", [Fact]).
execute_body_local(Name, believes(Fact)) :- !,
    (agent_belief_rt(Fact) ; agent_belief_rt(Other), ontology_match_local(Name, Fact, Other)).

%% Past
execute_body_local(_, has_past(Event)) :- !,
    (agent_past_event(Event, _, _) -> true ; event_in_past_local(Event)).
execute_body_local(_, has_past(Event, Time)) :- !,
    (agent_past_event(Event, Time, _) -> true
    ; agent_past_event(received(Event, _), Time, _) -> true
    ; agent_past_event(injected(Event), Time, _) -> true
    ; agent_past_event(internal(Event), Time, _)).

%% Actions
execute_body_local(Name, do(Action)) :- !,
    (loader:agent_action(Name, ActionPattern, ActionBody),
     copy_term(ActionPattern-ActionBody, Action-BodyCopy) ->
        log_local(Name, "Executing action: ~w", [Action]),
        get_time(Stamp), T is truncate(Stamp * 1000),
        record_past_local(did(Action), T),
        execute_body_local(Name, BodyCopy)
    ;
        log_local(Name, "Unknown action: ~w", [Action])
    ).

%% Helpers
execute_body_local(Name, helper(Goal)) :- !,
    (loader:agent_helper(Name, HeadPattern, HelperBody),
     copy_term(HeadPattern-HelperBody, Goal-BodyCopy) ->
        execute_body_local(Name, BodyCopy)
    ;
        log_local(Name, "Unknown helper: ~w", [Goal])
    ).

%% AI Oracle
execute_body_local(Name, ask_ai(Context, Result)) :- !,
    (should_allow_send_local(Name, Context) ->
        ai_oracle:ask_ai(Context, RawResult),
        (should_allow_receive_local(Name, RawResult, _) ->
            Result = RawResult
        ;
            Result = rejected(RawResult))
    ;
        Result = blocked(Context)
    ).
execute_body_local(_, ai_available) :- !, ai_oracle:ai_available.

%% Sender / reply
execute_body_local(_, from(Sender)) :- !, agent_current_sender(Sender).
execute_body_local(Name, reply_to(Content)) :- !,
    (agent_current_sender(Sender) -> execute_body_local(Name, send(Sender, Content)) ; true).

%% Remember
execute_body_local(_, has_remember(Event)) :- !, agent_remember_ev(Event, _, _).
execute_body_local(_, has_remember(Event, Time)) :- !, agent_remember_ev(Event, Time, _).
execute_body_local(_, has_confirmed(Fact)) :- !, agent_past_event(confirmed(Fact), _, _).

%% Proposals
execute_body_local(Name, accept_proposal(To, Action)) :- !,
    execute_body_local(Name, send(To, accept_proposal(Action))).
execute_body_local(Name, reject_proposal(To, Action)) :- !,
    execute_body_local(Name, send(To, reject_proposal(Action))).

%% Learning
execute_body_local(Name, learn(Pattern, Outcome)) :- !,
    assert(agent_learned_rt(Pattern, Outcome)),
    log_local(Name, "Learned: ~w -> ~w", [Pattern, Outcome]).
execute_body_local(_, learned(Pattern, Outcome)) :- !, agent_learned_rt(Pattern, Outcome).
execute_body_local(Name, forget(Pattern)) :- !,
    retractall(agent_learned_rt(Pattern, _)), log_local(Name, "Forgot: ~w", [Pattern]).

%% Ontology
execute_body_local(Name, onto_match(Term1, Term2)) :- !, ontology_match_local(Name, Term1, Term2).

%% Goals
execute_body_local(Name, achieve(Goal)) :- !,
    goal_canonical_id_local(Goal, GoalId),
    (agent_goal_status(GoalId, achieved) -> true ;
        (catch(call_condition_local(Goal), _, fail) ->
            retractall(agent_goal_status(GoalId, _)),
            assert(agent_goal_status(GoalId, achieved)),
            retractall(agent_residue_goal(GoalId, _)),
            log_local(Name, "Inline goal achieved: ~w", [Goal]),
            get_time(Stamp), T is truncate(Stamp * 1000),
            record_past_local(goal_achieved(Goal), T)
        ;
            (agent_residue_goal(GoalId, _) -> true ;
                assert(agent_residue_goal(GoalId, Goal)),
                log_local(Name, "Goal queued as residue: ~w", [Goal]))
        )).
execute_body_local(Name, reset_goal(Goal)) :- !,
    goal_canonical_id_local(Goal, GoalId),
    retractall(agent_goal_status(GoalId, _)),
    retractall(agent_residue_goal(GoalId, _)),
    log_local(Name, "Goal reset: ~w", [Goal]).

%% Blackboard — via Redis
execute_body_local(_, bb_read(Pattern)) :- !,
    redis_comm:redis_bb_read(Pattern).
execute_body_local(Name, bb_write(Tuple)) :- !,
    redis_comm:redis_bb_write(Tuple), log_local(Name, "Blackboard write: ~w", [Tuple]).
execute_body_local(Name, bb_remove(Pattern)) :- !,
    redis_comm:redis_bb_remove(Pattern), log_local(Name, "Blackboard remove: ~w", [Pattern]).

%% findall
execute_body_local(Name, findall(T, Goal, L)) :- !,
    findall(T, execute_body_local(Name, Goal), L).

%% Arithmetic, comparison, I/O, list ops — delegate directly
execute_body_local(_, X is Y) :- !, X is Y.
execute_body_local(_, X > Y) :- !, X > Y.
execute_body_local(_, X < Y) :- !, X < Y.
execute_body_local(_, X >= Y) :- !, X >= Y.
execute_body_local(_, X =< Y) :- !, X =< Y.
execute_body_local(_, X =:= Y) :- !, X =:= Y.
execute_body_local(_, X =\= Y) :- !, X =\= Y.
execute_body_local(_, X = Y) :- !, X = Y.
execute_body_local(_, X \= Y) :- !, X \= Y.
execute_body_local(_, X == Y) :- !, X == Y.
execute_body_local(_, X \== Y) :- !, X \== Y.
execute_body_local(_, write(X)) :- !, write(X).
execute_body_local(_, writeln(X)) :- !, writeln(X).
execute_body_local(_, nl) :- !, nl.
execute_body_local(_, format(F, A)) :- !, format(F, A).
execute_body_local(_, print(X)) :- !, print(X).
execute_body_local(_, member(X, L)) :- !, member(X, L).
execute_body_local(_, append(A, B, C)) :- !, append(A, B, C).
execute_body_local(_, length(L, N)) :- !, length(L, N).
execute_body_local(_, sort(L, S)) :- !, sort(L, S).
execute_body_local(_, reverse(L, R)) :- !, reverse(L, R).
execute_body_local(_, number(X)) :- !, number(X).
execute_body_local(_, atom(X)) :- !, atom(X).
execute_body_local(_, is_list(X)) :- !, is_list(X).
execute_body_local(_, sleep(T)) :- !, sleep(T).
execute_body_local(_, get_time(T)) :- !, get_time(T).
execute_body_local(_, between(A, B, C)) :- !, between(A, B, C).

%% DALI-style runtime body predicates
execute_body_local(Name, messageA(Dest, send_message(Content, _Me))) :- !,
    execute_body_local(Name, send(Dest, Content)).
execute_body_local(Name, messageA(Dest, send_message(Content))) :- !,
    execute_body_local(Name, send(Dest, Content)).
execute_body_local(_, evp(Event)) :- !,
    (agent_past_event(Event, _, _) -> true ; event_in_past_local(Event)).
execute_body_local(Name, tenta_residuo(Goal)) :- !,
    execute_body_local(Name, achieve(Goal)).

%% Catch-all
execute_body_local(Name, Goal) :-
    catch(call(Goal), Error,
        (log_local(Name, "Goal failed: ~w error: ~w", [Goal, Error]), fail)).

%% ============================================================
%% CONDITION EVALUATION
%% ============================================================

call_condition_local((C1, C2)) :- !, call_condition_local(C1), call_condition_local(C2).
call_condition_local(believes(Fact)) :- !,
    (agent_belief_rt(Fact) -> true
    ; agent_belief_rt(Other), agent_name(Name), ontology_match_local(Name, Fact, Other)).
call_condition_local(has_past(Event)) :- !,
    (agent_past_event(Event, _, _) -> true ; event_in_past_local(Event)).
call_condition_local(learned(Pattern, Outcome)) :- !, agent_learned_rt(Pattern, Outcome).
call_condition_local(has_remember(Event)) :- !, agent_remember_ev(Event, _, _).
call_condition_local(has_confirmed(Fact)) :- !, agent_past_event(confirmed(Fact), _, _).
call_condition_local(bb_read(Pattern)) :- !, redis_comm:redis_bb_read(Pattern).
call_condition_local(Cond) :- call(Cond).

%% ============================================================
%% ONTOLOGY MATCHING
%% ============================================================

ontology_match_local(_, Term1, Term2) :- Term1 = Term2, !.
ontology_match_local(Name, Term1, Term2) :-
    loader:agent_ontology(Name, same_as(Term1, Term2)), !.
ontology_match_local(Name, Term1, Term2) :-
    loader:agent_ontology(Name, same_as(Term2, Term1)), !.
ontology_match_local(Name, Term1, Term2) :-
    functor(Term1, F1, A), functor(Term2, F2, A),
    (loader:agent_ontology(Name, eq_property(F1, F2)) ;
     loader:agent_ontology(Name, eq_property(F2, F1))),
    Term1 =.. [F1|Args1], Term2 =.. [F2|Args2],
    maplist(=, Args1, Args2), !.
ontology_match_local(Name, Term1, Term2) :-
    loader:agent_ontology(Name, symmetric(Rel)),
    Term1 =.. [Rel, A, B], Term2 =.. [Rel, B, A], !.

%% ============================================================
%% ONTOLOGY FILE LOADING
%% ============================================================

load_agent_ontology_files_local(Name) :-
    forall(loader:agent_ontology_file(Name, File), load_ontology_file_local(Name, File)).

load_ontology_file_local(Name, File) :-
    (exists_file(File) ->
        setup_call_cleanup(
            open(File, read, Stream, []),
            read_ontology_terms_local(Name, Stream),
            close(Stream)),
        log_local(Name, "Loaded ontology file: ~w", [File])
    ;
        log_local(Name, "WARNING: Ontology file not found: ~w", [File])
    ).

read_ontology_terms_local(Name, Stream) :-
    read_term(Stream, Term, []),
    (Term == end_of_file -> true ;
        (process_ontology_term_local(Name, Term) -> true ; true),
        read_ontology_terms_local(Name, Stream)).

process_ontology_term_local(Name, same_as(A, B)) :- !,
    assert(loader:agent_ontology(Name, same_as(A, B))).
process_ontology_term_local(Name, eq_property(A, B)) :- !,
    assert(loader:agent_ontology(Name, eq_property(A, B))).
process_ontology_term_local(Name, eq_class(A, B)) :- !,
    assert(loader:agent_ontology(Name, eq_class(A, B))).
process_ontology_term_local(Name, symmetric(R)) :- !,
    assert(loader:agent_ontology(Name, symmetric(R))).
process_ontology_term_local(_, _).

%% ============================================================
%% PAST MEMORY
%% ============================================================

record_past_local(Event, Timestamp) :-
    assert(agent_past_event(Event, Timestamp, runtime)).

%% ============================================================
%% LOGGING
%% ============================================================

log_local(Name, Message) :-
    get_time(Stamp), T is truncate(Stamp * 1000),
    assert(agent_log_entry(T, Message)),
    get_time(Now),
    stamp_date_time(Now, date(_Y,_Mo,_D,H,Mi,S,_,_,_), local),
    Sec is truncate(S),
    format(atom(TimeStr), "~|~`0t~d~2+:~|~`0t~d~2+:~|~`0t~d~2+", [H, Mi, Sec]),
    format(user_error, "[~w] [~w] ~w~n", [TimeStr, Name, Message]),
    %% Also publish to Redis LOGS channel
    catch(redis_comm:redis_publish_log(Name, Message), _, true).

log_local(Name, Format, Args) :-
    catch((format(atom(Msg), Format, Args), log_local(Name, Msg)), _, log_local(Name, Format)).

