%% DALI2 Federation - Distributed multi-instance agent communication
%% Allows multiple DALI2 instances running on different machines to
%% form a federation where agents can communicate across instances.
%%
%% Like DALI's Linda server, but using HTTP REST instead of TCP sockets.
%% Each instance registers as a peer with other instances.
%% Messages to remote agents are automatically forwarded via HTTP.

:- module(federation, [
    fed_init/1,             % fed_init(+NodeName)
    fed_node_name/1,        % fed_node_name(-Name)
    fed_node_url/1,         % fed_node_url(-Url)
    fed_register_peer/2,    % fed_register_peer(+Name, +Url)
    fed_unregister_peer/1,  % fed_unregister_peer(+Name)
    fed_peers/1,            % fed_peers(-PeerList)
    fed_peer_info/3,        % fed_peer_info(+Name, -Url, -Agents)
    fed_is_local/1,         % fed_is_local(+AgentName)
    fed_find_agent/2,       % fed_find_agent(+AgentName, -PeerName)
    fed_remote_send/4,      % fed_remote_send(+PeerName, +From, +To, +Content)
    fed_sync_peer/1,        % fed_sync_peer(+PeerName)
    fed_sync_all/0,         % fed_sync_all
    fed_set_url/1,          % fed_set_url(+Url)
    fed_all_agents/1        % fed_all_agents(-AgentList)
]).

:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(library(lists)).

:- dynamic node_name/1.
:- dynamic node_url/1.
:- dynamic peer/3.              % peer(Name, Url, AgentList)
:- dynamic peer_last_sync/2.    % peer_last_sync(Name, Timestamp)

%% ============================================================
%% INITIALIZATION
%% ============================================================

fed_init(NodeName) :-
    retractall(node_name(_)),
    assert(node_name(NodeName)),
    format(user_error, "[Federation] Node initialized as '~w'~n", [NodeName]).

fed_node_name(Name) :-
    (node_name(N) -> Name = N ; Name = standalone).

fed_node_url(Url) :-
    (node_url(U) -> Url = U ; Url = '').

fed_set_url(Url) :-
    retractall(node_url(_)),
    assert(node_url(Url)).

%% ============================================================
%% PEER MANAGEMENT
%% ============================================================

%% fed_register_peer(+Name, +Url) - Register a remote peer instance
fed_register_peer(Name, Url) :-
    retractall(peer(Name, _, _)),
    assert(peer(Name, Url, [])),
    format(user_error, "[Federation] Peer registered: ~w at ~w~n", [Name, Url]),
    %% Try to sync immediately
    catch(fed_sync_peer(Name), E,
        format(user_error, "[Federation] Could not sync with ~w: ~w~n", [Name, E])).

%% fed_unregister_peer(+Name) - Remove a peer
fed_unregister_peer(Name) :-
    retractall(peer(Name, _, _)),
    retractall(peer_last_sync(Name, _)),
    format(user_error, "[Federation] Peer unregistered: ~w~n", [Name]).

%% fed_peers(-PeerList) - Get list of known peers
fed_peers(PeerList) :-
    findall(
        _{name: Name, url: Url, agents: Agents},
        peer(Name, Url, Agents),
        PeerList
    ).

%% fed_peer_info(+Name, -Url, -Agents) - Get info about a specific peer
fed_peer_info(Name, Url, Agents) :-
    peer(Name, Url, Agents).

%% ============================================================
%% AGENT ROUTING
%% ============================================================

%% fed_is_local(+AgentName) - True if agent is running on this instance
fed_is_local(AgentName) :-
    current_module(blackboard),
    blackboard:registered_agent(AgentName, _).

%% fed_find_agent(+AgentName, -PeerName) - Find which peer hosts an agent
fed_find_agent(AgentName, PeerName) :-
    peer(PeerName, _, Agents),
    member(AgentName, Agents), !.

%% fed_all_agents(-AgentList) - Get all agents (local + remote) with location info
fed_all_agents(AgentList) :-
    fed_node_name(MyName),
    %% Local agents
    (current_module(blackboard) ->
        findall(
            _{name: N, location: MyName, local: true},
            blackboard:registered_agent(N, _),
            LocalAgents
        )
    ; LocalAgents = []),
    %% Remote agents
    findall(
        _{name: N, location: PeerName, local: false},
        (peer(PeerName, _, Agents), member(N, Agents)),
        RemoteAgents
    ),
    append(LocalAgents, RemoteAgents, AgentList).

%% ============================================================
%% REMOTE MESSAGE SENDING
%% ============================================================

%% fed_remote_send(+PeerName, +From, +To, +Content) - Send message to remote agent
fed_remote_send(PeerName, From, To, Content) :-
    peer(PeerName, BaseUrl, _),
    term_to_atom(Content, ContentAtom),
    atom_string(From, FromStr),
    atom_string(To, ToStr),
    atom_string(ContentAtom, ContentStr),
    Body = _{from: FromStr, to: ToStr, content: ContentStr},
    atom_concat(BaseUrl, '/api/remote/receive', Endpoint),
    with_output_to(string(JsonStr), json_write_dict(current_output, Body, [])),
    catch(
        (http_open(
            Endpoint,
            ResponseStream,
            [
                method(post),
                post(string('application/json', JsonStr)),
                status_code(StatusCode),
                timeout(5)
            ]
        ),
        read_string(ResponseStream, _, _),
        close(ResponseStream),
        (StatusCode =:= 200 ->
            format(user_error, "[Federation] Sent to ~w@~w: ~w~n", [To, PeerName, Content])
        ;
            format(user_error, "[Federation] Send failed (~w) to ~w@~w~n", [StatusCode, To, PeerName])
        )),
        Error,
        format(user_error, "[Federation] Network error sending to ~w: ~w~n", [PeerName, Error])
    ).

%% ============================================================
%% PEER SYNCHRONIZATION
%% ============================================================

%% fed_sync_peer(+PeerName) - Fetch agent list from a peer
fed_sync_peer(PeerName) :-
    peer(PeerName, BaseUrl, _),
    atom_concat(BaseUrl, '/api/remote/agents', Endpoint),
    catch(
        (http_open(Endpoint, Stream, [timeout(5), status_code(Code)]),
         (Code =:= 200 ->
            json_read_dict(Stream, Dict),
            close(Stream),
            (get_dict(agents, Dict, AgentNames) ->
                %% Convert string list to atom list
                maplist(to_atom, AgentNames, AgentAtoms),
                retract(peer(PeerName, BaseUrl, _)),
                assert(peer(PeerName, BaseUrl, AgentAtoms)),
                get_time(Now),
                retractall(peer_last_sync(PeerName, _)),
                assert(peer_last_sync(PeerName, Now)),
                format(user_error, "[Federation] Synced with ~w: ~w agents~n",
                    [PeerName, AgentAtoms])
            ;
                close(Stream),
                format(user_error, "[Federation] Bad response from ~w~n", [PeerName])
            )
         ;
            read_string(Stream, _, _), close(Stream),
            format(user_error, "[Federation] Sync failed (~w) with ~w~n", [Code, PeerName])
         )),
        Error,
        format(user_error, "[Federation] Cannot reach ~w: ~w~n", [PeerName, Error])
    ).

to_atom(X, A) :-
    (atom(X) -> A = X ; atom_string(A, X)).

%% fed_sync_all/0 - Sync with all known peers
fed_sync_all :-
    findall(Name, peer(Name, _, _), Peers),
    maplist(fed_sync_peer, Peers).
