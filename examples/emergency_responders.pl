%% DALI2 Distributed Example: Emergency Response - Responder Node
%% This file runs on Node 2 (coordinator + responders).
%% The sensor and logger run on Node 1.
%%
%% Usage: Run with --name responders --agents coordinator,evacuator,responder,communicator

%% ============================================================
%% COORDINATOR - Receives alarms, dispatches to response teams
%% ============================================================
:- agent(coordinator, [cycle(1)]).

alarmE(Type, Location) :>
    log("ALARM: ~w at ~w", [Type, Location]),
    assert_belief(active_emergency(Type, Location)),
    messageA(evacuator, send_message(dispatch(Type, Location), Me)),
    messageA(communicator, send_message(notify_public(Type, Location), Me)),
    messageA(responder, send_message(dispatch(Type, Location), Me)),
    messageA(logger, send_message(log_event(dispatch, coordinator, [Type, Location]), Me)).

reportE(From, Status, Location) :>
    log("Report from ~w: ~w at ~w", [From, Status, Location]),
    assert_belief(report_received(From, Status, Location)),
    messageA(logger, send_message(log_event(report, From, [Status, Location]), Me)).

%% ============================================================
%% EVACUATOR - Handles evacuation
%% ============================================================
:- agent(evacuator, [cycle(1)]).

dispatchE(Type, Location) :>
    log("Evacuation started at ~w for ~w", [Location, Type]),
    assert_belief(evacuating(Location)),
    messageA(coordinator, send_message(report(evacuator, evacuation_complete, Location), Me)),
    messageA(logger, send_message(log_event(evacuation, evacuator, [Location, Type]), Me)).

%% ============================================================
%% RESPONDER - First response
%% ============================================================
:- agent(responder, [cycle(1)]).

dispatchE(Type, Location) :>
    log("Responding to ~w at ~w", [Type, Location]),
    assert_belief(responding(Location, Type)),
    messageA(coordinator, send_message(report(responder, response_active, Location), Me)),
    messageA(logger, send_message(log_event(response, responder, [Location, Type]), Me)).

%% ============================================================
%% COMMUNICATOR - Public notification
%% ============================================================
:- agent(communicator, [cycle(1)]).

notify_publicE(Type, Location) :>
    log("Public alert: ~w at ~w", [Type, Location]),
    assert_belief(notified(Location)),
    messageA(logger, send_message(log_event(notification, communicator, [Location, Type]), Me)).
