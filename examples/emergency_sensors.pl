%% DALI2 Distributed Example: Emergency Response - Sensor Node
%% This file runs on Node 1 (sensors + logger).
%% The coordinator, evacuator, responder, communicator run on Node 2.
%%
%% Usage: Run with --name sensors --agents sensor,logger
%%   or just run all agents defined here on this node.

:- agent(sensor, [cycle(1)]).

%% SENSOR - Detects emergencies, sends to coordinator (remote on node2)
detectE(Type, Location) :>
    log("Emergency detected: ~w at ~w", [Type, Location]),
    assert_belief(detected(Type, Location)),
    messageA(coordinator, send_message(alarm(Type, Location), Me)),
    messageA(logger, send_message(log_event(detection, sensor, [Type, Location]), Me)).

:- agent(logger, [cycle(1)]).

%% LOGGER - Logs all events
log_eventE(Type, Source, Data) :>
    log("LOG [~w] from ~w: ~w", [Type, Source, Data]).
