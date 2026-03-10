%% DALI2 Distributed Example: Emergency Response - Sensor Node
%% This file runs on Node 1 (sensors + logger).
%% The coordinator, evacuator, responder, communicator run on Node 2.
%%
%% Usage: Run with --name sensors --agents sensor,logger
%%   or just run all agents defined here on this node.

:- agent(sensor, [cycle(1)]).
:- agent(logger, [cycle(1)]).

%% SENSOR - Detects emergencies, sends to coordinator (remote on node2)
sensor:on(detect(Type, Location)) :-
    log("Emergency detected: ~w at ~w", [Type, Location]),
    assert_belief(detected(Type, Location)),
    send(coordinator, alarm(Type, Location)),
    send(logger, log_event(detection, sensor, [Type, Location])).

%% LOGGER - Logs all events
logger:on(log_event(Type, Source, Data)) :-
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
