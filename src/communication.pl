%% DALI2 Communication - Message passing between agents (local + remote)
%% Replaces DALI's communication_fipa.pl + communication_onto*.pl
%%
%% Local messages are delivered via the shared blackboard.
%% Remote messages are forwarded to peer instances via HTTP (federation).
%% Format: message(From, To, Content, Timestamp)

:- module(communication, [
    send/3,
    send/2,
    receive/2,
    receive_all/2,
    broadcast/2,
    deliver_remote/3      % deliver_remote(+From, +To, +Content)
]).

:- use_module(blackboard).
:- use_module(federation).

%% send(+From, +To, +Content) - Send a message to an agent (local or remote)
send(From, To, Content) :-
    get_time(Stamp),
    T is truncate(Stamp * 1000),
    (federation:fed_is_local(To) ->
        %% Local agent — deliver via blackboard
        bb_put(message(From, To, Content, T))
    ;
        %% Try to find agent on a remote peer
        (federation:fed_find_agent(To, PeerName) ->
            federation:fed_remote_send(PeerName, From, To, Content)
        ;
            %% Agent not found anywhere — deliver locally anyway (may be started later)
            bb_put(message(From, To, Content, T))
        )
    ).

%% send(+To, +Content) - Send from current thread's agent (convenience)
send(To, Content) :-
    (catch(thread_self(Tid), _, fail),
     atom_concat('agent_', Name, Tid) ->
        send(Name, To, Content)
    ;
        send(system, To, Content)
    ).

%% deliver_remote(+From, +To, +Content) - Deliver a message from a remote peer
%%   This is called when a remote instance forwards a message to us.
deliver_remote(From, To, Content) :-
    get_time(Stamp),
    T is truncate(Stamp * 1000),
    bb_put(message(From, To, Content, T)).

%% receive(+AgentName, -Message) - Receive one message for agent (destructive)
receive(AgentName, message(From, Content, T)) :-
    bb_take(message(From, AgentName, Content, T)), !.

%% receive_all(+AgentName, -Messages) - Receive all pending messages
receive_all(AgentName, Messages) :-
    findall(
        message(From, Content, T),
        bb_take(message(From, AgentName, Content, T)),
        Messages
    ).

%% broadcast(+From, +Content) - Send to all agents (local + remote, except sender)
broadcast(From, Content) :-
    %% Local agents
    bb_agents(LocalAgents),
    forall(
        (member(To, LocalAgents), To \= From),
        send(From, To, Content)
    ),
    %% Remote agents
    forall(
        (federation:peer(PeerName, _, RemoteAgents),
         member(To, RemoteAgents), To \= From),
        federation:fed_remote_send(PeerName, From, To, Content)
    ).
