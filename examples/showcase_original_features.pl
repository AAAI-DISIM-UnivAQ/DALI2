%% DALI2 Example: Original DALI Features Showcase
%% Demonstrates DALI-original rule types and DSL predicates in a single file,
%% using only standard DALI syntax (operators :>, :<, ~/, </, ?/, :~ and
%% suffixes E, I, A, N, P) and FIPA communication (messageA/send_message).
%% Also demonstrates DALI retrocompatibility features: deltat/1, cd/1,
%% :< on E-suffix events, and DALI message forms (message/2, messageA/3).
%% No DALI2-only extensions (every, when, helper, learn_from, ontology,
%% on_proposal, bb_read/bb_write/bb_remove, ?>, internal_event/5).
%% ask_ai is kept (graceful fallback when not configured).
%%
%% Agents:
%%   - thermostat:   internal events (default fire-once), constraints
%%   - sensor:       past lifetime/remember, goals, event preconditions (cd/1)
%%   - coordinator:  reactive rules, tell/told (priority queue), FIPA messages,
%%                   multi-events (deltat/1 + within/1), goals, residue goals,
%%                   export past rules, DALI message forms
%%   - logger:       semantic logging
%%   - worker:       FIPA responses, actions (A suffix), export past rules,
%%                   event preconditions (:< on E-suffix)
%%
%% Run:   AGENT_FILE=examples/showcase_original_features.pl docker compose up --build
%% Or:    swipl -l src/server.pl -g main -- 8080 examples/showcase_original_features.pl
%%
%% See EXAMPLES.md for step-by-step test commands.

%% ============================================================
%% THERMOSTAT — internal events (default), constraints
%% ============================================================

:- agent(thermostat, [cycle(2)]).

%% Initial beliefs
believes(target_temp(22)).
believes(current_temp(20)).
believes(mode(idle)).

%% Internal event — fires when current_temp belief exists
%% (default behavior: fires once, then stops when recorded in past)
temp_checkI :>
    believes(current_temp(T)),
    log("INTERNAL: temperature check, current=~w", [T]).

%% Internal event — fires once at startup
startup_diagnosticI :>
    log("INTERNAL: startup diagnostic"),
    assert_belief(diagnostic_done).

%% Internal event — fires when mode is cooling
cooling_monitorI :>
    believes(current_temp(T)),
    log("INTERNAL: Monitoring cooling, current temp: ~w", [T]).

%% Internal event — work hours check
work_hours_checkI :>
    log("INTERNAL: work hours system check").

%% Constraint: temperature must stay below 50 (DALI :~ prefix syntax)
%% :~ Condition. — fires when Condition is FALSE (violated)
:~ (believes(current_temp(T)), T < 50).

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
        messageA(coordinator, send_message(notify(cooling_active, T), Me))
    ;
        retract_belief(mode(_)),
        assert_belief(mode(idle))
    ).

%% ============================================================
%% SENSOR — past lifetime, goals
%% ============================================================

:- agent(sensor, [cycle(2)]).

%% Initial beliefs
believes(calibrated(false)).

%% Past lifetime — sensor readings expire after 30s, then remembered for 5 minutes
past_event(sensor_data(_), 30).
remember_event(sensor_data(_), 300).
remember_event_mod(sensor_data(_), number(10), last).

%% External event handler
read_tempE(T) :>
    log("Sensor read: ~w", [T]),
    messageA(coordinator, send_message(sensor_data(T), Me)).

%% DALI retrocompatibility: cd/1 event precondition (DALI eve_cond style)
%% Equivalent to: critical_tempE :< believes(threshold_reached).
cd(critical_temp) :- believes(threshold_reached).

%% External event with precondition (DALI cd/1 gate)
%% Handlers fire only if cd(critical_temp) holds
critical_tempE(T) :>
    log("CRITICAL: temperature ~w exceeds threshold!", [T]),
    messageA(coordinator, send_message(alert(critical, T), Me)).

%% Obtain goal (DALI obt_goal syntax)
obt_goal(believes(calibrated(true))) :-
    log("Attempting calibration..."),
    messageA(coordinator, send_message(calibration_request, Me)).

%% External event handler
calibration_doneE :>
    log("Calibration confirmed!"),
    retract_belief(calibrated(_)),
    assert_belief(calibrated(true)).

%% ============================================================
%% COORDINATOR — reactive, tell/told, priority queue, FIPA, multi-events,
%%               goals, residue goals, export past rules
%% ============================================================

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
told(_, accept_proposal(_,_), 70) :- true.
told(_, reject_proposal(_,_), 70) :- true.
told(_, query_ref(_,_), 60) :- true.
told(_, notify(_, _), 50) :- true.
told(_, sensor_data(_), 30) :- believes(status(active)).  %% accept only when active
told(_, calibration_request, 10) :- true.       %% lowest priority
told(_, send_confirm(_), 90) :- true.
told(_, query_worker(_), 60) :- true.
told(_, request_analysis(_), 70) :- true.
told(_, test_reject, 70) :- true.
told(_, start_residue_test, 50) :- true.
told(_, critical_data(_), 50) :- true.

%% Tell rules — body conditions supported
tell(_, _, calibration_done) :- true.
tell(_, _, response(_)) :- true.
tell(_, _, log_event(_, _, _)) :- true.
tell(_, _, propose(_,_)) :- believes(status(active)).  %% send proposals only when active
tell(_, _, confirm(_)) :- true.
tell(_, _, query_ref(_,_)) :- true.
tell(_, _, analyze(_)) :- true.

%% Multi-event: fire when both sensor data AND an alert
%% have been received within 10 seconds of each other.
%% Uses inline within/1 (DALI2 preferred form).
sensor_dataE(_), alertE(_, _), within(10) :>
    log("MULTI-EVENT: Both sensor data and alert received within 10s!"),
    messageA(logger, send_message(log_event(combined_alert, coordinator, multi_trigger), Me)).

%% DALI retrocompatibility: deltat/1 global simultaneity interval
%% Multi-events without inline within/1 will use this global interval.
deltat(30).

%% Multi-event using global deltat (no inline within/1)
%% Fires when both events occurred within 30 seconds (from deltat/1 above).
loginE(User), authorizeE(User) :>
    log("MULTI-EVENT (deltat): User ~w fully authenticated", [User]).

%% DALI retrocompatibility: direct message/2 form (auto-converted to send/2)
%% This is equivalent to messageA(logger, send_message(direct_msg(T), Me)).
sensor_dataE(T) :>
    log("Coordinator received sensor data: ~w", [T]),
    ( T > 40 ->
        messageA(logger, send_message(log_event(high_temp, coordinator, T), Me))
    ; true ),
    message(logger, inform(direct_msg(T), coordinator)).

alertE(Type, Value) :>
    log("Coordinator alert: ~w = ~w", [Type, Value]),
    believes(alerts_received(N)),
    N1 is N + 1,
    retract_belief(alerts_received(N)),
    assert_belief(alerts_received(N1)).

emergencyE(Type, Value) :>
    log("EMERGENCY: ~w = ~w", [Type, Value]),
    messageA(logger, send_message(log_event(emergency, coordinator, [Type, Value]), Me)),
    ( ai_available ->
        ask_ai(analyze(emergency(Type, Value)), Advice),
        log("AI advice for emergency: ~w", [Advice])
    ; true ).

calibration_requestE :>
    log("Processing calibration request"),
    messageA(sensor, send_message(calibration_done, Me)).

%% FIPA handlers
confirmE(Fact) :>
    log("FIPA CONFIRM received: ~w", [Fact]).

informE(Content, Meta) :>
    log("FIPA INFORM received: ~w meta=~w", [Content, Meta]).

accept_proposalE(Action, Reason) :>
    log("FIPA PROPOSAL ACCEPTED: ~w (reason: ~w)", [Action, Reason]).

reject_proposalE(Action, Reason) :>
    log("FIPA PROPOSAL REJECTED: ~w (reason: ~w)", [Action, Reason]).

request_analysisE(Data) :>
    log("Requesting analysis, proposing to worker..."),
    messageA(worker, propose(analyze(Data), [], Me)).

test_rejectE :>
    log("Testing proposal rejection..."),
    messageA(worker, propose(impossible_task, [], Me)).

send_confirmE(Fact) :>
    log("Sending FIPA confirm(~w) to worker", [Fact]),
    messageA(worker, confirm(Fact, Me)).

query_workerE(Q) :>
    log("Sending FIPA query_ref(~w) to worker", [Q]),
    messageA(worker, query_ref(Q, _, Me)).

%% Export past rules (DALI ~/ syntax)
%% When both alert and sensor_data in past, consume and react
messageA(logger, send_message(log_event(past_consumed, coordinator, [Type, Value]), Me)) ~/
    alert(Type, _), sensor_data(Value).

%% Export past NOT done (DALI </ syntax)
%% Warn if backup was NOT done but critical data exists
log("EXPORT PAST NOT_DONE: backup NOT done! critical_data needs attention!") </
    critical_data(_).

%% Residue goal test (DALI tenta_residuo syntax)
start_residue_testE :>
    log("Starting residue goal test..."),
    tenta_residuo(evp(residue_resolved)).

%% Test goal (DALI test_goal syntax)
test_goal(believes(alerts_received(N)), N > 0) :-
    log("Testing if any alerts received...").

%% ============================================================
%% LOGGER — semantic logging
%% ============================================================

:- agent(logger, [cycle(2)]).

%% External event handler
log_eventE(Type, Source, Data) :>
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]),
    assert_belief(logged(Type, Source)).

%% ============================================================
%% WORKER — FIPA responses, actions, export past rules
%% ============================================================

:- agent(worker, [cycle(2)]).

%% Initial beliefs
believes(available(true)).
believes(skill(data_analysis)).
believes(status(ready)).

%% Told rules with body conditions
told(_, propose(_,_), 100) :- believes(available(true)).  %% accept proposals only when available
told(_, confirm(_), 90) :- true.
told(_, query_ref(_,_), 80) :- true.
told(_, inform(_, _), 70) :- true.

%% Proposal handler (DALI proposeE syntax — receives propose messages)
proposeE(analyze(Data), Content) :>
    believes(skill(data_analysis)),
    from(Sender),
    log("PROPOSAL: Accepting analyze(~w) from ~w", [Data, Sender]),
    accept_proposal(Sender, analyze(Data), []),
    do(analyze(Data)).

proposeE(impossible_task, Content) :>
    from(Sender),
    log("PROPOSAL: Rejecting impossible_task from ~w", [Sender]),
    reject_proposal(Sender, impossible_task, []).

%% Action definition (DALI A suffix style) with precondition (DALI :< syntax)
%% The precondition must hold before the action body executes.
%% (In original DALI this was never actually checked due to a bug;
%%  DALI2 enforces it correctly.)
analyzeA(Data) :< believes(data_ready(Data)).
analyzeA(Data) :-
    log("Executing analysis: ~w", [Data]),
    assert_belief(analysis_complete(Data)),
    messageA(coordinator, inform(analysis_result(Data), complete, Me)).

%% DALI retrocompatibility: :< on E-suffix (external-event precondition)
%% Handlers for sensitiveE fire only if the precondition holds.
sensitiveE(Data) :< believes(security_clearance).
sensitiveE(Data) :>
    log("Sensitive data received: ~w (precondition verified)", [Data]).

%% DALI retrocompatibility: messageA/3 with explicit ReplyTo
%% Equivalent to messageA(coordinator, send_message(report(Data), Me)).
report_doneE(Data) :>
    messageA(coordinator, send_message(report(Data), worker), worker).

%% External event handler
confirmE(Fact) :>
    log("FIPA CONFIRM received: ~w", [Fact]).

%% Export past rule (DALI ~/ syntax)
messageA(coordinator, inform(task_report(Task), complete, Me)) ~/
    task_done(Task), report_needed(Task).
