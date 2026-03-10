%% DALI2 Blackboard - Thread-safe shared tuple space
%% Replaces the TCP-based Linda server from DALI with in-memory assertions.
%%
%% All agents share this blackboard within a single SWI-Prolog process.
%% Thread safety is ensured by SWI-Prolog's built-in mutex on assert/retract.

:- module(blackboard, [
    bb_init/0,
    bb_put/1,
    bb_get/1,
    bb_take/1,
    bb_all/2,
    bb_clear/0,
    bb_register_agent/2,
    bb_unregister_agent/1,
    bb_agents/1,
    bb_agent_info/2
]).

:- use_module(library(lists)).

:- dynamic tuple/1.
:- dynamic registered_agent/2.   % registered_agent(Name, Options)

%% bb_init/0 - Initialize the blackboard
bb_init :-
    retractall(tuple(_)),
    retractall(registered_agent(_, _)).

%% bb_put(+Tuple) - Add a tuple to the blackboard
bb_put(Tuple) :-
    with_mutex(blackboard_mutex, assert(tuple(Tuple))).

%% bb_get(+Pattern) - Read a tuple matching Pattern (non-destructive)
bb_get(Pattern) :-
    with_mutex(blackboard_mutex, tuple(Pattern)).

%% bb_take(+Pattern) - Remove and return a tuple matching Pattern
bb_take(Pattern) :-
    with_mutex(blackboard_mutex, retract(tuple(Pattern))).

%% bb_all(+Pattern, -List) - Get all tuples matching Pattern
bb_all(Pattern, List) :-
    with_mutex(blackboard_mutex,
        findall(Pattern, tuple(Pattern), List)
    ).

%% bb_clear/0 - Remove all tuples
bb_clear :-
    with_mutex(blackboard_mutex, retractall(tuple(_))).

%% bb_register_agent(+Name, +Options) - Register an agent on the blackboard
bb_register_agent(Name, Options) :-
    with_mutex(blackboard_mutex, (
        retractall(registered_agent(Name, _)),
        assert(registered_agent(Name, Options))
    )).

%% bb_unregister_agent(+Name) - Unregister an agent
bb_unregister_agent(Name) :-
    with_mutex(blackboard_mutex, retractall(registered_agent(Name, _))).

%% bb_agents(-List) - Get list of registered agent names
bb_agents(List) :-
    findall(Name, registered_agent(Name, _), List).

%% bb_agent_info(+Name, -Options) - Get agent options
bb_agent_info(Name, Options) :-
    registered_agent(Name, Options).
