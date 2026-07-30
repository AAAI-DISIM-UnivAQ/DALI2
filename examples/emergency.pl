%% DALI2 Example: Emergency Response MAS
%% Ported from the original DALI emergency example (dalia/example).
%%
%% Agents (9):
%%   - sensor:        detects events, validates alarms (real vs false)
%%   - coordinator:   multi-step dispatch: AI analysis, waits for equipment before responder
%%   - manager:       determines equipment based on emergency type
%%   - evacuator:     handles evacuation, reports back
%%   - responder:     responds with equipment at location, reports back
%%   - communicator:  notifies civilians (mary, john)
%%   - mary, john:    person agents that receive evacuation messages
%%   - logger:        logs all events
%%
%% Flow:
%%   sense(fire, building_a) -> sensor validates -> coordinator dispatches
%%   -> manager selects equipment -> coordinator waits for equipment + location
%%   -> responder dispatched -> evacuator + responder report back -> done
%%
%% Run:   AGENT_FILE=examples/emergency.pl docker compose up --build
%% Or:    swipl -l src/server.pl -g main -- 8080 examples/emergency.pl

%% ============================================================
%% SENSOR — detects events, validates alarms
%% ============================================================

:- agent(sensor, [cycle(1)]).

%% Receive a detection event, validate and forward
senseE(Type, Location) :>
    log("Detected: ~w at ~w", [Type, Location]),
    messageA(logger, send_message(log_event(detection, sensor, [Type, Location]), Me)),
    ( member(Type, [smoke, fire, earthquake]) ->
        log("ALARM CONFIRMED: ~w at ~w", [Type, Location]),
        messageA(coordinator, send_message(alarm(Type, Location), Me)),
        messageA(logger, send_message(log_event(alarm, sensor, [Type, Location]), Me))
    ;
        log("FALSE ALARM: ~w at ~w", [Type, Location]),
        messageA(logger, send_message(log_event(false_alarm, sensor, [Type, Location]), Me))
    ).

%% ============================================================
%% COORDINATOR — multi-step dispatch with AI and internal events
%% ============================================================
%%
%% Pattern:
%%   1. alarm -> assert location, AI analysis, dispatch evacuator + communicator + manager
%%   2. manager sends equipped(E) -> assert equipment
%%   3. Internal: location + equipment ready -> dispatch responder
%%   4. evacuator sends evacuated(L), responder sends responded(L)
%%   5. Internal: evacuated + responded -> emergency resolved

:- agent(coordinator, [cycle(1)]).

alarmE(Type, Location) :>
    log("ALARM: ~w at ~w", [Type, Location]),
    assert_belief(active_emergency(Type, Location)),
    assert_belief(pending_location(Location)),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(analyze(emergency(Type, Location)), Advice),
        log("AI suggests: ~w", [Advice])
    ; true ),
    %% Dispatch evacuator + communicator
    messageA(evacuator, send_message(evacuate(Location, Type), Me)),
    messageA(communicator, send_message(notify_civilians(Type, Location), Me)),
    %% Request equipment from manager
    messageA(manager, send_message(emergency(Type), Me)),
    messageA(logger, send_message(log_event(dispatch, coordinator, [Type, Location]), Me)).

equippedE(Equipment) :>
    log("Equipment received: ~w", [Equipment]),
    assert_belief(equipment_ready(Equipment)).

evacuatedE(Location) :>
    log("Evacuation complete: ~w", [Location]),
    assert_belief(evacuated(Location)),
    messageA(logger, send_message(log_event(report, evacuator, [evacuation_complete, Location]), Me)).

respondedE(Location) :>
    log("Response complete: ~w", [Location]),
    assert_belief(responded(Location)),
    messageA(logger, send_message(log_event(report, responder, [response_complete, Location]), Me)).

%% Internal event: when location + equipment ready -> dispatch responder
dispatch_responseI :>
    believes(pending_location(Location)),
    believes(equipment_ready(Equipment)),
    log("Dispatching responder with ~w to ~w", [Equipment, Location]),
    retract_belief(pending_location(Location)),
    retract_belief(equipment_ready(Equipment)),
    messageA(responder, send_message(respond(Equipment, Location), Me)),
    messageA(logger, send_message(log_event(response_dispatched, coordinator, [Equipment, Location]), Me)).

%% Internal event: when evacuated + responded -> emergency resolved
check_doneI :>
    believes(evacuated(Location)),
    believes(responded(Location)),
    log("EMERGENCY RESOLVED at ~w", [Location]),
    retract_belief(evacuated(Location)),
    retract_belief(responded(Location)),
    retract_belief(active_emergency(_, Location)),
    messageA(logger, send_message(log_event(done, coordinator, [resolved, Location]), Me)).

%% ============================================================
%% MANAGER — determines equipment based on emergency type
%% ============================================================

:- agent(manager, [cycle(1)]).

emergencyE(Type) :>
    log("Emergency type: ~w — determining equipment", [Type]),
    ( Type == fire -> Equipment = firetruck
    ; Type == earthquake -> Equipment = bulldozer
    ; Type == smoke -> Equipment = respirator
    ; Equipment = generic_kit
    ),
    log("Dispatching ~w for ~w", [Equipment, Type]),
    messageA(coordinator, send_message(equipped(Equipment), Me)),
    messageA(logger, send_message(log_event(equipment, manager, [Equipment, Type]), Me)).

%% ============================================================
%% EVACUATOR — handles evacuation, reports back
%% ============================================================

:- agent(evacuator, [cycle(1)]).

evacuateE(Location, Type) :>
    log("Evacuating ~w due to ~w", [Location, Type]),
    messageA(coordinator, send_message(evacuated(Location), Me)),
    messageA(logger, send_message(log_event(evacuation, evacuator, [Location, Type]), Me)).

%% ============================================================
%% RESPONDER — responds with equipment, reports back
%% ============================================================

:- agent(responder, [cycle(1)]).

respondE(Equipment, Location) :>
    log("Using ~w at ~w", [Equipment, Location]),
    messageA(coordinator, send_message(responded(Location), Me)),
    messageA(logger, send_message(log_event(response, responder, [Equipment, Location]), Me)).

%% ============================================================
%% COMMUNICATOR — notifies civilians
%% ============================================================

:- agent(communicator, [cycle(1)]).

notify_civiliansE(Type, Location) :>
    log("Notifying civilians about ~w at ~w", [Type, Location]),
    messageA(mary, send_message(message(Type, Location), Me)),
    messageA(john, send_message(message(Type, Location), Me)),
    messageA(logger, send_message(log_event(notification, communicator, [Type, Location]), Me)).

%% ============================================================
%% PERSON AGENTS — receive evacuation messages
%% ============================================================

:- agent(mary, [cycle(1)]).

messageE(Type, Location) :>
    log("Received alarm about ~w at ~w, preparing for evacuation", [Type, Location]).

:- agent(john, [cycle(1)]).

messageE(Type, Location) :>
    log("Received alarm about ~w at ~w, preparing for evacuation", [Type, Location]).

%% ============================================================
%% LOGGER — logs all events
%% ============================================================

:- agent(logger, [cycle(1)]).

log_eventE(Type, Source, Data) :>
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
