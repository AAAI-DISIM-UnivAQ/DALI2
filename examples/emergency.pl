%% DALI2 Example: Emergency Response MAS
%% Ported from the original DALI emergency example (dalia/example).
%%
%% Agents (9):
%%   - sensor:        detects events, validates alarms via internal events (real vs false)
%%   - coordinator:   multi-step dispatch: AI analysis, waits for equipment before responder
%%   - manager:       determines equipment based on emergency type
%%   - evacuator:     handles evacuation, reports back
%%   - responder:     responds with equipment at location, reports back
%%   - communicator:  notifies civilians (mary, john)
%%   - mary, john:    person agents that receive evacuation messages
%%   - logger:        logs all events
%%
%% Flow:
%%   sense(fire, building_a) → sensor validates → coordinator dispatches
%%   → manager selects equipment → coordinator waits for equipment + location
%%   → responder dispatched → evacuator + responder report back → done
%%
%% Run:   AGENT_FILE=examples/emergency.pl docker compose up --build
%% Or:    swipl -l src/server.pl -g main -- 8080 examples/emergency.pl

%% ============================================================
%% SENSOR — detects events, validates alarms via internal events
%% ============================================================
%%
%% Pattern from DALI: senseE stores state → internal events check
%% if the detection is a real alarm (smoke/fire/earthquake) or false alarm.

:- agent(sensor, [cycle(1)]).

%% Receive a detection event, store state for internal event validation
sensor:on(sense(Type, Location)) :-
    log("Detected: ~w at ~w", [Type, Location]),
    assert_belief(detected(Type, Location)),
    send(logger, log_event(detection, sensor, [Type, Location])).

%% Internal event: real alarm — type is smoke, fire, or earthquake
sensor:internal(check_alarm, [forever]) :-
    believes(detected(Type, Location)),
    member(Type, [smoke, fire, earthquake]),
    log("ALARM CONFIRMED: ~w at ~w", [Type, Location]),
    retract_belief(detected(Type, Location)),
    send(coordinator, alarm(Type, Location)),
    send(logger, log_event(alarm, sensor, [Type, Location])).

%% Internal event: false alarm — type is not in alarm list
sensor:internal(check_false_alarm, [forever]) :-
    believes(detected(Type, Location)),
    \+ member(Type, [smoke, fire, earthquake]),
    log("FALSE ALARM: ~w at ~w", [Type, Location]),
    retract_belief(detected(Type, Location)),
    send(logger, log_event(false_alarm, sensor, [Type, Location])).

%% ============================================================
%% COORDINATOR — multi-step dispatch with AI and internal events
%% ============================================================
%%
%% Pattern from DALI:
%%   1. alarm → assert location, AI analysis, dispatch evacuator + communicator + manager
%%   2. manager sends equipped(E) → assert equipment
%%   3. Internal: location + equipment ready → dispatch responder
%%   4. evacuator sends evacuated(L), responder sends responded(L)
%%   5. Internal: evacuated + responded → emergency resolved

:- agent(coordinator, [cycle(1)]).

coordinator:on(alarm(Type, Location)) :-
    log("ALARM: ~w at ~w", [Type, Location]),
    assert_belief(active_emergency(Type, Location)),
    assert_belief(pending_location(Location)),
    %% AI analysis if available
    ( ai_available ->
        ask_ai(analyze(emergency(Type, Location)), Advice),
        log("AI suggests: ~w", [Advice])
    ; true ),
    %% Dispatch evacuator + communicator
    send(evacuator, evacuate(Location, Type)),
    send(communicator, notify_civilians(Type, Location)),
    %% Request equipment from manager
    send(manager, emergency(Type)),
    send(logger, log_event(dispatch, coordinator, [Type, Location])).

coordinator:on(equipped(Equipment)) :-
    log("Equipment received: ~w", [Equipment]),
    assert_belief(equipment_ready(Equipment)).

coordinator:on(evacuated(Location)) :-
    log("Evacuation complete: ~w", [Location]),
    assert_belief(evacuated(Location)),
    send(logger, log_event(report, evacuator, [evacuation_complete, Location])).

coordinator:on(responded(Location)) :-
    log("Response complete: ~w", [Location]),
    assert_belief(responded(Location)),
    send(logger, log_event(report, responder, [response_complete, Location])).

%% Internal event: when location + equipment ready → dispatch responder
coordinator:internal(dispatch_response, [forever]) :-
    believes(pending_location(Location)),
    believes(equipment_ready(Equipment)),
    log("Dispatching responder with ~w to ~w", [Equipment, Location]),
    retract_belief(pending_location(Location)),
    retract_belief(equipment_ready(Equipment)),
    send(responder, respond(Equipment, Location)),
    send(logger, log_event(response_dispatched, coordinator, [Equipment, Location])).

%% Internal event: when evacuated + responded → emergency resolved
coordinator:internal(check_done, [forever]) :-
    believes(evacuated(Location)),
    believes(responded(Location)),
    log("EMERGENCY RESOLVED at ~w", [Location]),
    retract_belief(evacuated(Location)),
    retract_belief(responded(Location)),
    retract_belief(active_emergency(_, Location)),
    send(logger, log_event(done, coordinator, [resolved, Location])).

%% ============================================================
%% MANAGER — determines equipment based on emergency type
%% ============================================================
%%
%% Pattern from DALI: fire → firetruck, earthquake → bulldozer,
%% smoke → respirator. Sends equipped(E) back to coordinator.

:- agent(manager, [cycle(1)]).

manager:on(emergency(Type)) :-
    log("Emergency type: ~w — determining equipment", [Type]),
    ( Type == fire -> Equipment = firetruck
    ; Type == earthquake -> Equipment = bulldozer
    ; Type == smoke -> Equipment = respirator
    ; Equipment = generic_kit
    ),
    log("Dispatching ~w for ~w", [Equipment, Type]),
    send(coordinator, equipped(Equipment)),
    send(logger, log_event(equipment, manager, [Equipment, Type])).

%% ============================================================
%% EVACUATOR — handles evacuation, reports back
%% ============================================================

:- agent(evacuator, [cycle(1)]).

evacuator:on(evacuate(Location, Type)) :-
    log("Evacuating ~w due to ~w", [Location, Type]),
    send(coordinator, evacuated(Location)),
    send(logger, log_event(evacuation, evacuator, [Location, Type])).

%% ============================================================
%% RESPONDER — responds with equipment, reports back
%% ============================================================

:- agent(responder, [cycle(1)]).

responder:on(respond(Equipment, Location)) :-
    log("Using ~w at ~w", [Equipment, Location]),
    send(coordinator, responded(Location)),
    send(logger, log_event(response, responder, [Equipment, Location])).

%% ============================================================
%% COMMUNICATOR — notifies civilians
%% ============================================================

:- agent(communicator, [cycle(1)]).

communicator:on(notify_civilians(Type, Location)) :-
    log("Notifying civilians about ~w at ~w", [Type, Location]),
    send(mary, message(Type, Location)),
    send(john, message(Type, Location)),
    send(logger, log_event(notification, communicator, [Type, Location])).

%% ============================================================
%% PERSON AGENTS — receive evacuation messages
%% ============================================================

:- agent(mary, [cycle(1)]).

mary:on(message(Type, Location)) :-
    log("Received alarm about ~w at ~w, preparing for evacuation", [Type, Location]).

:- agent(john, [cycle(1)]).

john:on(message(Type, Location)) :-
    log("Received alarm about ~w at ~w, preparing for evacuation", [Type, Location]).

%% ============================================================
%% LOGGER — logs all events
%% ============================================================

:- agent(logger, [cycle(1)]).

logger:on(log_event(Type, Source, Data)) :-
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
