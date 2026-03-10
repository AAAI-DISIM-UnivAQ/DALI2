%% DALI2 Example: Emergency Response MAS
%% A multi-agent emergency response system.
%%
%% Agents:
%%   - sensor:        detects emergencies, reports to coordinator
%%   - coordinator:   dispatches responders based on emergency type
%%   - evacuator:     handles evacuation
%%   - responder:     responds to emergencies on-site
%%   - communicator:  notifies civilians
%%   - logger:        logs all events

%% ============================================================
%% SENSOR
%% ============================================================

:- agent(sensor, [cycle(1)]).

sensor:on(sense(Type, Location)) :-
    log("Emergency detected: ~w at ~w", [Type, Location]),
    send(coordinator, alarm(Type, Location)),
    send(logger, log_event(detection, sensor, [Type, Location])).

%% ============================================================
%% COORDINATOR
%% ============================================================

:- agent(coordinator, [cycle(1)]).

coordinator:on(alarm(Type, Location)) :-
    log("Alarm received: ~w at ~w", [Type, Location]),
    assert_belief(active_emergency(Type, Location)),
    % Dispatch evacuator
    send(evacuator, evacuate(Location, Type)),
    % Dispatch communicator
    send(communicator, notify_civilians(Location, Type)),
    % Dispatch responder
    send(responder, respond(Location, Type)),
    send(logger, log_event(dispatch, coordinator, [Type, Location])).

coordinator:on(report(Agent, Status, Location)) :-
    log("Report from ~w: ~w at ~w", [Agent, Status, Location]),
    assert_belief(report_received(Agent, Status, Location)),
    send(logger, log_event(report, Agent, [Status, Location])).

%% ============================================================
%% EVACUATOR
%% ============================================================

:- agent(evacuator, [cycle(1)]).

evacuator:on(evacuate(Location, Type)) :-
    log("Evacuating ~w due to ~w", [Location, Type]),
    assert_belief(evacuating(Location)),
    send(coordinator, report(evacuator, evacuation_complete, Location)),
    send(logger, log_event(evacuation, evacuator, [Location, Type])).

%% ============================================================
%% RESPONDER
%% ============================================================

:- agent(responder, [cycle(1)]).

responder:on(respond(Location, Type)) :-
    log("Responding to ~w at ~w", [Type, Location]),
    assert_belief(responding(Location, Type)),
    send(coordinator, report(responder, response_active, Location)),
    send(logger, log_event(response, responder, [Location, Type])).

%% ============================================================
%% COMMUNICATOR
%% ============================================================

:- agent(communicator, [cycle(1)]).

communicator:on(notify_civilians(Location, Type)) :-
    log("Notifying civilians about ~w at ~w", [Type, Location]),
    send(logger, log_event(notification, communicator, [Location, Type])).

%% ============================================================
%% LOGGER
%% ============================================================

:- agent(logger, [cycle(1)]).

logger:on(log_event(Type, Source, Data)) :-
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
