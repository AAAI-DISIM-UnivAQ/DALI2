%% DALI2 Communication - Simplified message passing between agents
%% Replaces DALI's communication_fipa.pl + communication_onto*.pl
%%
%% Messages are delivered via the shared blackboard.
%% Format: message(From, To, Content, Timestamp)

:- module(communication, [
    send/3,
    send/2,
    receive/2,
    receive_all/2,
    broadcast/2
]).

:- use_module(blackboard).

%% send(+From, +To, +Content) - Send a message from one agent to another
send(From, To, Content) :-
    get_time(Stamp),
    T is truncate(Stamp * 1000),
    bb_put(message(From, To, Content, T)).

%% send(+To, +Content) - Send from current thread's agent (convenience)
%%   The caller must have set the thread-local agent_name.
send(To, Content) :-
    (catch(thread_self(Tid), _, fail),
     atom_concat('agent_', Name, Tid) ->
        send(Name, To, Content)
    ;
        send(system, To, Content)
    ).

%% receive(+AgentName, -Message) - Receive one message for agent (destructive)
%%   Returns message(From, Content, Timestamp) or fails if none.
receive(AgentName, message(From, Content, T)) :-
    bb_take(message(From, AgentName, Content, T)), !.

%% receive_all(+AgentName, -Messages) - Receive all pending messages
receive_all(AgentName, Messages) :-
    findall(
        message(From, Content, T),
        bb_take(message(From, AgentName, Content, T)),
        Messages
    ).

%% broadcast(+From, +Content) - Send to all registered agents (except sender)
broadcast(From, Content) :-
    bb_agents(Agents),
    forall(
        (member(To, Agents), To \= From),
        send(From, To, Content)
    ).
