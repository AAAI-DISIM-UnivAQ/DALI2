%% DALI2 Redis Communication Module
%%
%% Star-topology communication using Redis pub/sub:
%%
%%   LINDA channel — all agents subscribe. Messages are published as:
%%     PUBLISH LINDA "<TO>:<CONTENT>:<FROM>"
%%     where TO is the destination agent (or * for broadcast),
%%     CONTENT is the Prolog term (serialized), FROM is the sender.
%%
%%   LOGS channel — agents publish log entries (no subscription needed):
%%     PUBLISH LOGS "<AGENT>:<MESSAGE>"
%%     This channel is for external monitoring tools.
%%
%% Each agent process connects to Redis and:
%%   1. Subscribes to LINDA channel
%%   2. Filters messages addressed to itself (or broadcast *)
%%   3. Publishes outgoing messages to LINDA
%%   4. Publishes log entries to LOGS
%%
%% Redis connection is configured via environment variables:
%%   REDIS_HOST (default: localhost)
%%   REDIS_PORT (default: 6379)
%%
%% This replaces the HTTP point-to-point IPC from the previous architecture
%% with a simple, scalable star topology. Remote machines on the same LAN
%% just need to point to the same Redis instance.

:- module(redis_comm, [
    redis_init/0,
    redis_init/2,
    redis_subscribe_linda/1,     % redis_subscribe_linda(+AgentName)
    redis_subscribe_logs/0,      % redis_subscribe_logs — master subscribes to LOGS channel
    redis_publish_linda/3,       % redis_publish_linda(+From, +To, +Content)
    redis_publish_log/2,         % redis_publish_log(+AgentName, +Message)
    redis_poll_messages/2,       % redis_poll_messages(+AgentName, -Messages)
    redis_bb_write/1,            % redis_bb_write(+Tuple)
    redis_bb_read/1,             % redis_bb_read(+Pattern)
    redis_bb_remove/1,           % redis_bb_remove(+Pattern)
    redis_bb_all/2,              % redis_bb_all(+Pattern, -List)
    redis_connected/0
]).

:- use_module(library(redis)).
:- use_module(library(lists)).
:- use_module(library(broadcast)).

:- dynamic redis_connection/1.       % redis_connection(Connection)
:- dynamic redis_sub_connection/1.   % redis_sub_connection(SubConnection)
:- dynamic redis_msg_queue/3.        % redis_msg_queue(To, Content, From) — buffered incoming
:- dynamic redis_is_connected/0.

%% ============================================================
%% INITIALIZATION
%% ============================================================

%% redis_init/0 — connect using environment variables or defaults
redis_init :-
    (getenv('REDIS_HOST', Host) -> true ; Host = localhost),
    (getenv('REDIS_PORT', PortAtom) ->
        atom_number(PortAtom, Port)
    ;
        Port = 6379
    ),
    redis_init(Host, Port).

%% redis_init/2 — connect to a specific Redis host:port
redis_init(Host, Port) :-
    (redis_is_connected -> true ;
        catch(
            (redis_server(dali2_redis, Host:Port, []),
             assert(redis_is_connected),
             format(user_error, "[Redis] Connected to ~w:~w~n", [Host, Port])),
            Error,
            format(user_error, "[Redis] Connection failed: ~w~n", [Error])
        )
    ).

redis_connected :- redis_is_connected.

%% ============================================================
%% LINDA CHANNEL — Message passing
%% ============================================================

%% redis_publish_linda(+From, +To, +Content)
%% Publishes a message on the LINDA channel.
%% Format: "TO:CONTENT_ATOM:FROM"
redis_publish_linda(From, To, Content) :-
    (redis_is_connected ->
        term_to_atom(Content, ContentAtom),
        format(atom(Msg), "~w:~w:~w", [To, ContentAtom, From]),
        catch(
            redis(dali2_redis, publish('LINDA', Msg), _),
            Error,
            format(user_error, "[Redis] Publish error: ~w~n", [Error])
        )
    ;
        format(user_error, "[Redis] Not connected, cannot publish~n", [])
    ).

%% redis_subscribe_linda(+AgentName)
%% Subscribes to the LINDA channel using listen/2 (broadcast library)
%% and redis_subscribe/4 with options list. Buffers messages for this agent.
redis_subscribe_linda(AgentName) :-
    (redis_is_connected ->
        %% Register broadcast listener for LINDA channel messages
        listen(redis(_, 'LINDA', Message),
            redis_comm:handle_linda_message(AgentName, Message)),
        %% Start subscription (creates background thread internally)
        catch(
            redis_subscribe(dali2_redis, ['LINDA'], _SubId, []),
            Error,
            format(user_error, "[Redis] Subscribe error: ~w~n", [Error])
        )
    ;
        format(user_error, "[Redis] Not connected, cannot subscribe~n", [])
    ).

%% handle_linda_message(+AgentName, +Message)
%% Called via broadcast for each message on the LINDA channel.
%% Parses "TO:CONTENT:FROM" and queues if addressed to us or broadcast.
handle_linda_message(AgentName, Message) :-
    atom_string(MsgAtom, Message),
    parse_linda_message(MsgAtom, To, ContentAtom, From),
    (To == AgentName ; To == '*' ; To == all),
    From \== AgentName,  % don't receive own broadcasts
    !,
    catch(term_to_atom(Content, ContentAtom), _, Content = ContentAtom),
    with_mutex(redis_queue_mutex,
        assert(redis_msg_queue(AgentName, Content, From))
    ).
handle_linda_message(_, _).  % ignore messages not for us

%% parse_linda_message(+Msg, -To, -Content, -From)
%% Parses "TO:CONTENT:FROM" — splits on first and last colon.
parse_linda_message(Msg, To, Content, From) :-
    atom_string(Msg, Str),
    %% Find first ':'
    sub_string(Str, BeforeTo, 1, _, ":"),
    sub_string(Str, 0, BeforeTo, _, ToStr),
    AfterTo is BeforeTo + 1,
    sub_string(Str, AfterTo, _, 0, Rest),
    %% Find last ':' in Rest (for From)
    atom_string(RestAtom, Rest),
    atom_chars(RestAtom, RestChars),
    last_colon_split(RestChars, ContentChars, FromChars),
    atom_chars(Content, ContentChars),
    atom_chars(From, FromChars),
    atom_string(To, ToStr).

last_colon_split(Chars, Before, After) :-
    append(Before, [':'|After], Chars),
    \+ member(':', After), !.

%% redis_poll_messages(+AgentName, -Messages)
%% Retrieves and clears all buffered messages for an agent.
redis_poll_messages(AgentName, Messages) :-
    with_mutex(redis_queue_mutex, (
        findall(
            message(From, Content, T),
            (retract(redis_msg_queue(AgentName, Content, From)),
             get_time(Stamp), T is truncate(Stamp * 1000)),
            Messages
        )
    )).

%% ============================================================
%% LOGS CHANNEL — Monitoring
%% ============================================================

%% redis_publish_log(+AgentName, +Message)
%% Publishes a log entry on the LOGS channel.
%% Format: "AGENT:MESSAGE"
redis_publish_log(AgentName, Message) :-
    (redis_is_connected ->
        format(atom(LogMsg), "~w:~w", [AgentName, Message]),
        catch(
            redis(dali2_redis, publish('LOGS', LogMsg), _),
            _Error, true  % fire and forget
        )
    ;
        true
    ).

%% redis_subscribe_logs/0
%% Master server subscribes to LOGS channel to collect agent log entries
%% for the web UI. Parses "AGENT:MESSAGE" and asserts engine:agent_log_entry/3.
redis_subscribe_logs :-
    (redis_is_connected ->
        %% Register broadcast listener for LOGS channel messages
        listen(redis(_, 'LOGS', Message),
            redis_comm:handle_logs_message(Message)),
        %% Start subscription (creates background thread internally)
        catch(
            redis_subscribe(dali2_redis, ['LOGS'], _SubId, []),
            Error,
            format(user_error, "[Redis] LOGS subscribe error: ~w~n", [Error])
        )
    ;
        format(user_error, "[Redis] Not connected, cannot subscribe to LOGS~n", [])
    ).

%% handle_logs_message(+Message)
%% Called via broadcast for each message on the LOGS channel.
%% Parses "AGENT:MESSAGE" and asserts to engine:agent_log_entry/3.
handle_logs_message(Message) :-
    atom_string(MsgAtom, Message),
    atom_string(MsgAtom, Str),
    %% Find first ':' to split AGENT:MESSAGE
    (sub_string(Str, Before, 1, _, ":") ->
        sub_string(Str, 0, Before, _, AgentStr),
        After is Before + 1,
        sub_string(Str, After, _, 0, MsgStr),
        atom_string(Agent, AgentStr),
        atom_string(MsgText, MsgStr),
        get_time(Stamp), T is truncate(Stamp * 1000),
        assert(engine:agent_log_entry(Agent, T, MsgText))
    ;
        true  % malformed message, ignore
    ).

%% ============================================================
%% BLACKBOARD via Redis (replaces in-memory blackboard)
%% Uses Redis SET "BB" as a simple tuple space.
%% Each tuple is stored as a member of the set.
%% ============================================================

%% redis_bb_write(+Tuple) — Add a tuple to the blackboard
redis_bb_write(Tuple) :-
    (redis_is_connected ->
        term_to_atom(Tuple, TupleAtom),
        catch(
            redis(dali2_redis, sadd('BB', TupleAtom), _),
            _Error, true
        )
    ;
        true
    ).

%% redis_bb_read(+Pattern) — Read a matching tuple (non-destructive)
redis_bb_read(Pattern) :-
    redis_is_connected,
    catch(
        redis(dali2_redis, smembers('BB'), Members),
        _, fail
    ),
    member(MemberStr, Members),
    atom_string(MemberAtom, MemberStr),
    catch(term_to_atom(Term, MemberAtom), _, fail),
    subsumes_term(Pattern, Term),
    Pattern = Term.

%% redis_bb_remove(+Pattern) — Remove a matching tuple
redis_bb_remove(Pattern) :-
    redis_is_connected,
    catch(
        redis(dali2_redis, smembers('BB'), Members),
        _, fail
    ),
    member(MemberStr, Members),
    atom_string(MemberAtom, MemberStr),
    catch(term_to_atom(Term, MemberAtom), _, fail),
    subsumes_term(Pattern, Term),
    Pattern = Term,
    catch(
        redis(dali2_redis, srem('BB', MemberAtom), _),
        _, true
    ).

%% redis_bb_all(+Pattern, -List) — Get all matching tuples
redis_bb_all(Pattern, List) :-
    (redis_is_connected ->
        catch(
            redis(dali2_redis, smembers('BB'), Members),
            _, Members = []
        ),
        findall(Term,
            (member(MemberStr, Members),
             atom_string(MemberAtom, MemberStr),
             catch(term_to_atom(Term, MemberAtom), _, fail),
             subsumes_term(Pattern, Term)),
            List)
    ;
        List = []
    ).
