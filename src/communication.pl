%% DALI2 Communication - Message passing between agents via Redis
%%
%% Star-topology communication using Redis pub/sub:
%%   LINDA channel — all agents subscribe. Messages published as "TO:CONTENT:FROM"
%%   LOGS channel — log entries for monitoring
%%   BB (Redis SET) — shared blackboard (replaces Linda tuple space)
%%
%% All instances (local or remote) connect to the same Redis server.
%% No HTTP federation needed — Redis handles cross-instance routing.
%% Format: message(From, Content, Timestamp)

:- module(communication, [
    send/3,
    send/2,
    broadcast/2
]).

:- use_module(redis_comm).

%% send(+From, +To, +Content) - Send a message to an agent via Redis LINDA channel
send(From, To, Content) :-
    (redis_comm:redis_connected ->
        redis_comm:redis_publish_linda(From, To, Content)
    ;
        format(user_error, "[comm] Cannot deliver to ~w: Redis not connected~n", [To])
    ).

%% send(+To, +Content) - Send from current thread/process (convenience)
send(To, Content) :-
    (catch(thread_self(Tid), _, fail),
     atom_concat('agent_', Name, Tid) ->
        send(Name, To, Content)
    ;
        send(system, To, Content)
    ).

%% broadcast(+From, +Content) - Send to all agents (via Redis * broadcast)
broadcast(From, Content) :-
    (redis_comm:redis_connected ->
        redis_comm:redis_publish_linda(From, '*', Content)
    ;
        true
    ).
