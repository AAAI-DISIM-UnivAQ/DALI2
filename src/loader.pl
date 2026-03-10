%% DALI2 Loader - Agent definition parser
%% Replaces DALI's tokefun.pl + togli_var.pl + metti_var.pl + leggi_mul.pl
%%
%% Reads a single agents.pl file and extracts:
%%   - Agent declarations:  :- agent(Name, Options).
%%   - Event handlers:      Name:on(Event) :- Body.
%%   - Periodic rules:      Name:every(Seconds, Goal).
%%   - Condition monitors:  Name:when(Condition) :- Body.
%%   - Actions:             Name:do(Action) :- Body.
%%   - Beliefs:             Name:believes(Fact).
%%   - Helper clauses:      Name:helper(Head) :- Body.

:- module(loader, [
    load_agents/1,
    load_agents_from_string/1,
    agent_def/2,
    agent_handler/3,
    agent_periodic/3,
    agent_monitor/3,
    agent_action/3,
    agent_belief/2,
    agent_helper/3,
    clear_definitions/0
]).

:- use_module(library(lists)).

%% Stored definitions
:- dynamic agent_def/2.         % agent_def(Name, Options)
:- dynamic agent_handler/3.     % agent_handler(Name, Event, Body)
:- dynamic agent_periodic/3.    % agent_periodic(Name, Seconds, Body)
:- dynamic agent_monitor/3.     % agent_monitor(Name, Condition, Body)
:- dynamic agent_action/3.      % agent_action(Name, Action, Body)
:- dynamic agent_belief/2.      % agent_belief(Name, Fact)
:- dynamic agent_helper/3.      % agent_helper(Name, Head, Body)

%% clear_definitions/0 - Remove all loaded definitions
clear_definitions :-
    retractall(agent_def(_, _)),
    retractall(agent_handler(_, _, _)),
    retractall(agent_periodic(_, _, _)),
    retractall(agent_monitor(_, _, _)),
    retractall(agent_action(_, _, _)),
    retractall(agent_belief(_, _)),
    retractall(agent_helper(_, _, _)).

%% load_agents(+File) - Load agent definitions from a file
load_agents(File) :-
    clear_definitions,
    read_file_terms(File, Terms),
    process_terms(Terms).

%% load_agents_from_string(+String) - Load agent definitions from a string
load_agents_from_string(String) :-
    clear_definitions,
    term_string(Terms, String),
    (is_list(Terms) ->
        process_terms(Terms)
    ;
        process_terms([Terms])
    ).

%% read_file_terms(+File, -Terms) - Read all terms from a file
read_file_terms(File, Terms) :-
    setup_call_cleanup(
        open(File, read, Stream, []),
        read_all_terms(Stream, Terms),
        close(Stream)
    ).

read_all_terms(Stream, Terms) :-
    read_term(Stream, Term, [module(loader)]),
    (Term == end_of_file ->
        Terms = []
    ;
        Terms = [Term | Rest],
        read_all_terms(Stream, Rest)
    ).

%% process_terms(+Terms) - Process a list of terms into agent definitions
process_terms([]).
process_terms([Term | Rest]) :-
    (process_term(Term) -> true ;
        format(atom(Msg), "Warning: could not process term: ~w~n", [Term]),
        print_message(warning, format(Msg, []))
    ),
    process_terms(Rest).

%% process_term(+Term) - Process a single term

% Agent declaration: :- agent(Name, Options).
process_term(:- agent(Name, Options)) :- !,
    assert(agent_def(Name, Options)).

% Agent declaration without options: :- agent(Name).
process_term(:- agent(Name)) :- !,
    assert(agent_def(Name, [])).

% Event handler: Name:on(Event) :- Body.
process_term((Name:on(Event) :- Body)) :- !,
    assert(agent_handler(Name, Event, Body)).

% Event handler without body: Name:on(Event).
process_term(Name:on(Event)) :- !,
    assert(agent_handler(Name, Event, true)).

% Periodic rule: Name:every(Seconds, Goal).
process_term(Name:every(Seconds, Goal)) :- !,
    assert(agent_periodic(Name, Seconds, Goal)).

% Periodic rule with body: Name:every(Seconds) :- Body.
process_term((Name:every(Seconds) :- Body)) :- !,
    assert(agent_periodic(Name, Seconds, Body)).

% Condition monitor: Name:when(Condition) :- Body.
process_term((Name:when(Condition) :- Body)) :- !,
    assert(agent_monitor(Name, Condition, Body)).

% Action: Name:do(Action) :- Body.
process_term((Name:do(Action) :- Body)) :- !,
    assert(agent_action(Name, Action, Body)).

% Action without body: Name:do(Action).
process_term(Name:do(Action)) :- !,
    assert(agent_action(Name, Action, true)).

% Belief: Name:believes(Fact).
process_term(Name:believes(Fact)) :- !,
    assert(agent_belief(Name, Fact)).

% Helper clause: Name:helper(Head) :- Body.
process_term((Name:helper(Head) :- Body)) :- !,
    assert(agent_helper(Name, Head, Body)).

% Helper clause without body: Name:helper(Head).
process_term(Name:helper(Head)) :- !,
    assert(agent_helper(Name, Head, true)).

% Directives (other :- terms) - execute them
process_term(:- Goal) :- !,
    catch(call(Goal), _, true).

% Standalone facts/rules (without agent prefix) - skip with warning
process_term(Term) :-
    format(user_error, "DALI2 loader: ignoring unrecognized term: ~w~n", [Term]).
