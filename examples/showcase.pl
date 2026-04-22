%% DALI2 Example: Feature Showcase
%% Demonstrates ALL DALI2 rule types and DSL predicates in a single file,
%% using original DALI syntax (operators :>, :<, ~/, </, ?/, :~ and
%% suffixes E, I, A, N, P) plus DALI2-only features (every, when, helper,
%% on_proposal, learn_from, ontology, ask_ai, bb_read/bb_write/bb_remove).
%%
%% Agents:
%%   - thermostat:   internal events (interval, change, trigger, between), constraints, condition-action
%%   - sensor:       periodic tasks, present events, learning, blackboard, past lifetime/remember
%%   - coordinator:  reactive rules, tell/told (priority queue), FIPA messages, multi-events,
%%                   goals, residue goals, export past rules, action proposal sending
%%   - logger:       ontology (inline + external file), helpers, condition monitor
%%   - worker:       action proposals (on_proposal), FIPA responses, export past rules
%%
%% Features demonstrated (32 total):
%%   1.  Reactive rules (E suffix + :>)          — all agents
%%   2.  Internal events (I suffix + :>)         — thermostat
%%   3.  Internal event interval(N)              — thermostat (temp_check: every 5s)
%%   4.  Internal event change([Facts])          — thermostat (startup_diagnostic: resets on temp change)
%%   5.  Internal event trigger(Condition)       — thermostat (cooling_monitor: only when cooling)
%%   6.  Internal event between(time)            — thermostat (work hours check)
%%   7.  Periodic tasks (every)                  — sensor (heartbeat 15s)         [NEW]
%%   8.  Condition monitors (when)               — logger (high log volume warning) [NEW]
%%   9.  Condition-action (:< operator)          — thermostat (cooling mode edge-triggered)
%%  10.  Present/environment events (N suffix)   — sensor (blackboard monitoring)
%%  11.  Multi-events (E suffix conjunction)     — coordinator (sensor_data + alert)
%%  12.  Constraints (:~ operator)               — thermostat (temp < 50)
%%  13.  Goals (obt_goal/test_goal)              — sensor (calibration), coordinator (alert test)
%%  14.  Tell/told filtering                     — coordinator (priority-based message acceptance)
%%  15.  Priority queue for messages             — coordinator (told priorities: 200/100/50/...)
%%  16.  FIPA confirm/disconfirm                 — coordinator sends, worker receives
%%  17.  FIPA query_ref                          — coordinator queries worker beliefs
%%  18.  FIPA propose/accept/reject              — coordinator proposes to worker
%%  19.  FIPA inform                             — worker sends analysis results
%%  20.  Action proposals (on_proposal)          — worker handles proposals        [NEW]
%%  21.  Past event lifetime + remember tier     — sensor (30s expire, 5min remember)
%%  22.  Export past rules (~/ operator)          — coordinator (alert + reading consumed)
%%  23.  Export past rules (</ operator)          — coordinator (backup not done warning)
%%  24.  Residue goals                           — coordinator (deferred goal retry)
%%  25.  External ontology file loading          — logger (test_ontology.pl)       [NEW]
%%  26.  Inline ontology declarations            — logger (same_as, eq_property)   [NEW]
%%  27.  Learning rules                          — sensor (overheating pattern)    [NEW]
%%  28.  Actions (A suffix)                      — worker (analyze action)
%%  29.  Beliefs                                 — all agents
%%  30.  Helpers                                 — logger (count_logs)             [NEW]
%%  31.  Blackboard                              — sensor writes, sensor reads     [NEW]
%%  32.  AI Oracle (if configured)               — coordinator (emergency analysis) [NEW]
%%
%% Run:   AGENT_FILE=examples/showcase.pl docker compose up --build
%% Or:    swipl -l src/server.pl -g main -- 8080 examples/showcase.pl
%%
%% See EXAMPLES.md for step-by-step test commands.

%% ============================================================
%% THERMOSTAT — internal events, constraints, condition-action
%% ============================================================
%%
%% Demonstrates:
%%   - Internal event with interval (fires every 5 seconds, not every cycle)
%%   - Internal event with change condition (resets counter on belief change)
%%   - Internal event with trigger/start condition (fires only when condition holds)
%%   - Internal event with between/time window
%%   - Constraint (:~ operator) — temperature must stay below 50
%%   - Condition-action (:< operator) — edge-triggered on cooling mode
%%   - Reactive rules (E suffix + :>) — set_temp, update_temp

:- agent(thermostat, [cycle(2)]).

%% Initial beliefs
believes(target_temp(22)).
believes(current_temp(20)).
believes(mode(idle)).

%% Internal event with interval — fires every 5 seconds (not every cycle)
temp_checkI :>
    believes(current_temp(T)),
    log("INTERVAL INTERNAL: temperature check (every 5s), current=~w", [T]).
internal_event(temp_check, 5, forever, true, forever).

%% Internal event with change condition — resets when current_temp changes
startup_diagnosticI :>
    log("CHANGE INTERNAL: startup diagnostic (resets on temp change)"),
    assert_belief(diagnostic_done).
internal_event(startup_diagnostic, 0, change([current_temp(_)]), true, forever).

%% Internal event with trigger — fires only when mode is cooling
cooling_monitorI :>
    believes(current_temp(T)),
    log("TRIGGERED INTERNAL: Monitoring cooling, current temp: ~w", [T]).
internal_event(cooling_monitor, 0, forever, believes(mode(cooling)), forever).

%% Internal event with between — fires only during work hours
work_hours_checkI :>
    log("BETWEEN INTERNAL: work hours system check").
internal_event(work_hours_check, 10, forever, true, in_date(time(0,0), time(23,59))).

%% Constraint: temperature must stay below 50 (DALI :~ prefix syntax)
%% :~ Condition. — fires when Condition is FALSE (violated)
:~ (believes(current_temp(T)), T < 50).

%% Condition-action rule (DALI :< syntax, edge-triggered)
believes(mode(cooling)) :< (
    log("ON_CHANGE: Cooling mode just activated"),
    send(logger, log_event(mode_change, thermostat, cooling))
).

%% External event handlers (DALI :> syntax with E suffix)
set_tempE(NewTarget) :>
    log("Target temperature set to ~w", [NewTarget]),
    retract_belief(target_temp(_)),
    assert_belief(target_temp(NewTarget)).

update_tempE(T) :>
    log("Temperature updated to ~w", [T]),
    retract_belief(current_temp(_)),
    assert_belief(current_temp(T)),
    ( T > 30 ->
        retract_belief(mode(_)),
        assert_belief(mode(cooling)),
        send(coordinator, notify(cooling_active, T))
    ;
        retract_belief(mode(_)),
        assert_belief(mode(idle))
    ).

%% ============================================================
%% SENSOR — periodic, present events, learning, blackboard, past lifetime
%% ============================================================
%%
%% Demonstrates:
%%   - Periodic tasks (every 15s heartbeat) [NEW]
%%   - Present events (N suffix — monitor blackboard)
%%   - Learning rules (overheating pattern) [NEW]
%%   - Blackboard usage (write + read) [NEW]
%%   - Past event lifetime + remember tier
%%   - Goal (achieve calibration)

:- agent(sensor, [cycle(2)]).

%% Initial beliefs
believes(calibrated(false)).

%% Past lifetime — sensor readings expire after 30s, then remembered for 5 minutes
past_event(sensor_data(_), 30).
remember_event(sensor_data(_), 300).
remember_event_mod(sensor_data(_), number(10), last).

%% Periodic task: heartbeat every 15 seconds [NEW]
every(15, log("Sensor heartbeat")).

%% Present events are atomic environmental observations.
%% They cannot be defined with :- (they are set by the environment).
%% Use them as conditions in reactive rules instead:
read_tempE(T) :>
    bb_write(environment(temp, T)),
    log("Sensor stored temp ~w on blackboard", [T]).

%% Learning rules [NEW]
learn_from(read_temp(T), overheating) :- T > 80.
learn_from(read_temp(T), normal) :- T =< 80.

%% External event handler
read_tempE(T) :>
    log("Sensor read: ~w", [T]),
    %% Write to blackboard so present events can detect it
    bb_write(environment(temp, T)),
    %% Check if we previously learned about overheating
    ( learned(read_temp(_), overheating) ->
        log("WARNING: Previously learned overheating pattern!"),
        send(coordinator, alert(repeated_overheating, T))
    ;
        true
    ),
    send(coordinator, sensor_data(T)).

%% Obtain goal (DALI obt_goal syntax)
obt_goal(believes(calibrated(true))) :-
    log("Attempting calibration..."),
    send(coordinator, calibration_request).

%% External event handler
calibration_doneE :>
    log("Calibration confirmed!"),
    retract_belief(calibrated(_)),
    assert_belief(calibrated(true)).

%% ============================================================
%% COORDINATOR — reactive, tell/told, priority queue, FIPA, multi-events,
%%               goals, residue goals, export past rules, proposal sending
%% ============================================================
%%
%% Demonstrates:
%%   - Tell/told communication filtering with priority queue
%%   - FIPA message types: confirm, inform, query_ref, propose, accept/reject_proposal
%%   - Multi-events (E suffix conjunction)
%%   - Goals (test_goal)
%%   - Residue goals (deferred achieve)
%%   - Export past rules (~/, </)
%%   - AI Oracle integration (filtered by tell/told) [NEW]

:- agent(coordinator, [cycle(2)]).

%% Initial beliefs
believes(status(active)).
believes(alerts_received(0)).

%% Told rules — DALI communication filtering with body conditions.
%% Body can contain real conditions (not just true).
told(_, emergency(_, _), 200) :- true.         %% highest priority
told(_, alert(_, _), 100) :- true.
told(_, confirm(_), 90) :- true.
told(_, inform(_, _), 80) :- true.
told(_, accept_proposal(_), 70) :- true.
told(_, reject_proposal(_), 70) :- true.
told(_, query_ref(_), 60) :- true.
told(_, notify(_, _), 50) :- true.
told(_, sensor_data(_), 30) :- believes(status(active)).  %% accept only when active
told(_, calibration_request, 10) :- true.       %% lowest priority
told(_, send_confirm(_), 90) :- true.
told(_, query_worker(_), 60) :- true.
told(_, request_analysis(_), 70) :- true.
told(_, test_reject, 70) :- true.
told(_, start_residue_test, 50) :- true.
told(_, critical_data(_), 50) :- true.
told(_, heartbeat).                              %% 2-arg form (priority=0, body=true)

%% Tell rules — body conditions supported
tell(_, _, calibration_done) :- true.
tell(_, _, response(_)) :- true.
tell(_, _, log_event(_, _, _)) :- true.
tell(_, _, propose(_)) :- believes(status(active)).  %% send proposals only when active
tell(_, _, confirm(_)) :- true.
tell(_, _, query_ref(_)) :- true.
tell(_, _, analyze(_)) :- true.

%% Multi-event with delta-t: fire when both sensor data AND an alert
%% have been received within 10 seconds of each other.
sensor_dataE(_), alertE(_, _), within(10) :>
    log("MULTI-EVENT: Both sensor data and alert received within 10s!"),
    send(logger, log_event(combined_alert, coordinator, multi_trigger)).

%% External event handlers (DALI :> syntax with E suffix)
sensor_dataE(T) :>
    log("Coordinator received sensor data: ~w", [T]),
    ( T > 40 ->
        send(logger, log_event(high_temp, coordinator, T))
    ; true ).

alertE(Type, Value) :>
    log("Coordinator alert: ~w = ~w", [Type, Value]),
    believes(alerts_received(N)),
    N1 is N + 1,
    retract_belief(alerts_received(N)),
    assert_belief(alerts_received(N1)).

emergencyE(Type, Value) :>
    log("EMERGENCY: ~w = ~w", [Type, Value]),
    send(logger, log_event(emergency, coordinator, [Type, Value])),
    ( ai_available ->
        ask_ai(analyze(emergency(Type, Value)), Advice),
        log("AI advice for emergency: ~w", [Advice])
    ; true ).

calibration_requestE :>
    log("Processing calibration request"),
    send(sensor, calibration_done).

%% FIPA handlers
confirmE(Fact) :>
    log("FIPA CONFIRM received: ~w", [Fact]).

informE(Content, Meta) :>
    log("FIPA INFORM received: ~w meta=~w", [Content, Meta]).

accept_proposalE(Action) :>
    log("FIPA PROPOSAL ACCEPTED: ~w", [Action]).

reject_proposalE(Action) :>
    log("FIPA PROPOSAL REJECTED: ~w", [Action]).

request_analysisE(Data) :>
    log("Requesting analysis, proposing to worker..."),
    send(worker, propose(analyze(Data))).

test_rejectE :>
    log("Testing proposal rejection..."),
    send(worker, propose(impossible_task)).

send_confirmE(Fact) :>
    log("Sending FIPA confirm(~w) to worker", [Fact]),
    send(worker, confirm(Fact)).

query_workerE(Q) :>
    log("Sending FIPA query_ref(~w) to worker", [Q]),
    send(worker, query_ref(Q)).

%% Export past rules (DALI ~/ syntax)
%% When both alert and sensor_data in past, consume and react
send(logger, log_event(past_consumed, coordinator, [Type, Value])) ~/
    alert(Type, _), sensor_data(Value).

%% Export past NOT done (DALI </ syntax)
%% Warn if backup was NOT done but critical data exists
log("EXPORT PAST NOT_DONE: backup NOT done! critical_data needs attention!") </
    critical_data(_).

%% Residue goal test
start_residue_testE :>
    log("Starting residue goal test..."),
    achieve(has_past(residue_resolved)).

%% Test goal (DALI test_goal syntax)
test_goal(believes(alerts_received(N)), N > 0) :-
    log("Testing if any alerts received...").

%% ============================================================
%% LOGGER — ontology (inline + file), helpers, condition monitor
%% ============================================================
%%
%% Demonstrates:
%%   - Inline ontology declarations (same_as, eq_property, symmetric) [NEW]
%%   - External ontology file loading (test_ontology.pl) [NEW]
%%   - Helper predicates [NEW]
%%   - Condition monitors (when) [NEW]

:- agent(logger, [cycle(2)]).

%% Ontology [NEW]
ontology(same_as(log_event, log_entry)).
ontology(eq_property(log_event, record)).
ontology(symmetric(related_to)).

%% External ontology file [NEW]
ontology_file('examples/test_ontology.pl').

%% External event handler
log_eventE(Type, Source, Data) :>
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]),
    assert_belief(logged(Type, Source)),
    helper(count_logs).

%% Helper [NEW]
helper(count_logs) :-
    findall(_, believes(logged(_, _)), Logs),
    length(Logs, N),
    log("Total log entries: ~w", [N]).

%% Condition monitor [NEW]
when(believes(logged(_, _))) :-
    findall(_, believes(logged(_, _)), Logs),
    length(Logs, N),
    ( N > 10 ->
        log("WARNING: High log volume (~w entries)", [N])
    ; true ).

%% ============================================================
%% WORKER — action proposals, FIPA responses, export past rules
%% ============================================================
%%
%% Demonstrates:
%%   - Action proposals (on_proposal) with accept/reject [NEW]
%%   - FIPA message handling (confirm, inform)
%%   - Named actions (A suffix)
%%   - from(Sender) DSL predicate
%%   - accept_proposal/reject_proposal DSL predicates
%%   - Export past rules (~/)
%%   - Told rules for FIPA message acceptance

:- agent(worker, [cycle(2)]).

%% Initial beliefs
believes(available(true)).
believes(skill(data_analysis)).
believes(status(ready)).

%% Told rules with body conditions
told(_, propose(_), 100) :- believes(available(true)).  %% accept proposals only when available
told(_, confirm(_), 90) :- true.
told(_, query_ref(_), 80) :- true.
told(_, inform(_, _), 70) :- true.

%% Action proposal handlers [NEW]
on_proposal(analyze(Data)) :-
    believes(skill(data_analysis)),
    from(Sender),
    log("PROPOSAL: Accepting analyze(~w) from ~w", [Data, Sender]),
    accept_proposal(Sender, analyze(Data)),
    do(analyze(Data)).

on_proposal(impossible_task) :-
    from(Sender),
    log("PROPOSAL: Rejecting impossible_task from ~w", [Sender]),
    reject_proposal(Sender, impossible_task).

%% Action definition (DALI A suffix style)
analyzeA(Data) :-
    log("Executing analysis: ~w", [Data]),
    assert_belief(analysis_complete(Data)),
    send(coordinator, inform(analysis_result(Data), complete)).

%% External event handler
confirmE(Fact) :>
    log("FIPA CONFIRM received: ~w", [Fact]).

%% Export past rule (DALI ~/ syntax)
send(coordinator, inform(task_report(Task), complete)) ~/
    task_done(Task), report_needed(Task).
