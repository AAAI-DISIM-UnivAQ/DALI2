%% DALI2 Server - HTTP server + entry point
%% Serves the web UI and provides a REST API for agent management.
%% Replaces DALI's active_user_wi.pl and dalia's main.py

:- module(server, [main/0]).

:- use_module(library(http/thread_httpd)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_files)).
:- use_module(library(http/http_header)).
:- use_module(library(http/http_cors)).
:- use_module(library(http/json)).
:- use_module(library(lists)).

:- set_setting(http:cors, [*]).

:- use_module(blackboard).
:- use_module(communication).
:- use_module(loader).
:- use_module(engine).
:- use_module(ai_oracle).
:- use_module(federation).

%% HTTP Routes
:- http_handler(root(.),         serve_index,       []).
:- http_handler(root(api/status),    api_status,    []).
:- http_handler(root(api/agents),    api_agents,    []).
:- http_handler(root(api/logs),      api_logs,      []).
:- http_handler(root(api/send),      api_send,      [method(post)]).
:- http_handler(root(api/inject),    api_inject,    [method(post)]).
:- http_handler(root(api/start),     api_start,     [method(post)]).
:- http_handler(root(api/stop),      api_stop,      [method(post)]).
:- http_handler(root(api/reload),    api_reload,    [method(post)]).
:- http_handler(root(api/beliefs),   api_beliefs,   []).
:- http_handler(root(api/past),      api_past,      []).
:- http_handler(root(api/blackboard),api_blackboard,[]).
:- http_handler(root(api/source),    api_source,    []).
:- http_handler(root(api/save),      api_save,      [method(post)]).
:- http_handler(root(api/ai/status), api_ai_status, []).
:- http_handler(root(api/ai/key),    api_ai_key,    [method(post)]).
:- http_handler(root(api/ai/ask),    api_ai_ask,    [method(post)]).
:- http_handler(root(api/ai/model),  api_ai_model,  [method(post)]).
%% Federation / Distributed
:- http_handler(root(api/peers),          api_peers,          []).
:- http_handler(root(api/peers/register),  api_peer_register, [method(post)]).
:- http_handler(root(api/peers/unregister),api_peer_unregister,[method(post)]).
:- http_handler(root(api/peers/sync),      api_peer_sync,     [method(post)]).
:- http_handler(root(api/remote/agents),   api_remote_agents,  []).
:- http_handler(root(api/remote/receive),  api_remote_receive, [method(post)]).
:- http_handler(root(static),  serve_static, [prefix]).

%% ============================================================
%% MAIN ENTRY POINT
%% ============================================================

main :-
    set_prolog_flag(color_term, false),
    current_prolog_flag(argv, Argv),
    parse_args(Argv, Port, AgentFile, NodeName, AgentFilter),
    format("~n=== DALI2 Multi-Agent System ===~n"),
    format("Node: ~w | Port: ~w~n", [NodeName, Port]),
    bb_init,
    federation:fed_init(NodeName),
    (AgentFile \= '' ->
        format("Loading agents from: ~w~n", [AgentFile]),
        loader:load_agents(AgentFile),
        findall(N, loader:agent_def(N, _), AllNames),
        format("Agents defined: ~w~n", [AllNames]),
        assert(current_agent_file(AgentFile)),
        %% Start only filtered agents, or all if no filter
        (AgentFilter \= [] ->
            format("Starting agents: ~w~n", [AgentFilter]),
            forall(member(A, AgentFilter), engine:start_agent(A))
        ;
            engine:start_all
        )
    ;
        format("No agent file specified. Use the web UI to load agents.~n"),
        assert(current_agent_file(''))
    ),
    format("Server listening on port ~w~n", [Port]),
    format("(If using Docker with port mapping, open the mapped host port in your browser)~n~n"),
    http_server(http_dispatch, [port(Port)]),
    %% Handle SIGINT/SIGTERM for clean shutdown (e.g. CTRL+C in Docker)
    on_signal(int, _, signal_stop),
    on_signal(term, _, signal_stop),
    %% Set own URL (for peer registration handshakes)
    format(atom(SelfUrl), "http://localhost:~w", [Port]),
    federation:fed_set_url(SelfUrl),
    %% Auto-connect to peers from DALI2_PEERS env var (comma-separated name@url)
    auto_connect_peers,
    thread_get_message(stop_server).

signal_stop(_Signal) :-
    thread_send_message(main, stop_server).

:- dynamic current_agent_file/1.

%% parse_args(+Argv, -Port, -AgentFile, -NodeName, -AgentFilter)
parse_args(Argv, Port, AgentFile, NodeName, AgentFilter) :-
    (nth0(0, Argv, PortAtom) ->
        atom_number(PortAtom, Port)
    ; Port = 8080),
    (nth0(1, Argv, AgentFile0) ->
        AgentFile = AgentFile0
    ; AgentFile = ''),
    %% --name NodeName
    (parse_flag(Argv, '--name', NameAtom) ->
        NodeName = NameAtom
    ; (getenv('DALI2_NODE', EnvName) -> NodeName = EnvName
      ; format(atom(NodeName), 'node-~w', [Port]))),
    %% --agents a1,a2,a3
    (parse_flag(Argv, '--agents', AgentsAtom) ->
        atomic_list_concat(AgentFilter, ',', AgentsAtom)
    ; AgentFilter = []).

parse_flag([Flag, Value | _], Flag, Value) :- !.
parse_flag([_ | Rest], Flag, Value) :- parse_flag(Rest, Flag, Value).

%% auto_connect_peers/0 - Connect to peers listed in DALI2_PEERS env var
%%   Format: name1@http://host1:port1,name2@http://host2:port2
%%   Starts a background thread that retries sync for peers that aren't ready yet.
auto_connect_peers :-
    (getenv('DALI2_PEERS', PeersStr), PeersStr \= '' ->
        atomic_list_concat(PeerSpecs, ',', PeersStr),
        forall(member(Spec, PeerSpecs), connect_peer_spec(Spec)),
        %% Start background retry for unsynced peers
        thread_create(peer_sync_retry_loop, _, [detached(true)])
    ; true).

connect_peer_spec(Spec) :-
    (sub_atom(Spec, Before, 1, _, '@') ->
        sub_atom(Spec, 0, Before, _, Name),
        After is Before + 1,
        sub_atom(Spec, After, _, 0, Url),
        format("Connecting to peer: ~w at ~w~n", [Name, Url]),
        catch(federation:fed_register_peer(Name, Url), E,
            format(user_error, "Failed to connect to ~w: ~w~n", [Name, E]))
    ;
        format(user_error, "Invalid peer spec (expected name@url): ~w~n", [Spec])
    ).

%% peer_sync_retry_loop/0 - Retry syncing with peers that have empty agent lists
peer_sync_retry_loop :-
    peer_sync_retry_loop(10).   % Up to 10 retries

peer_sync_retry_loop(0) :- !.
peer_sync_retry_loop(N) :-
    sleep(3),
    findall(Name, (federation:peer(Name, _, Agents), Agents == []), Unsynced),
    (Unsynced == [] ->
        format(user_error, "[Federation] All peers synced~n", [])
    ;
        format(user_error, "[Federation] Retrying sync for: ~w~n", [Unsynced]),
        forall(member(P, Unsynced),
            catch(federation:fed_sync_peer(P), _, true)),
        N1 is N - 1,
        peer_sync_retry_loop(N1)
    ).

%% ============================================================
%% STATIC FILE SERVING
%% ============================================================

serve_index(_Request) :-
    server_base_dir(Base),
    atom_concat(Base, '/web/index.html', IndexFile),
    read_file_to_string(IndexFile, Content, []),
    format(atom(Reply), '~w', [Content]),
    throw(http_reply(bytes('text/html', Reply))).

serve_static(Request) :-
    server_base_dir(Base),
    member(path_info(PathInfo), Request),
    atom_concat(Base, '/web/', WebBase),
    atom_concat(WebBase, PathInfo, FilePath),
    (exists_file(FilePath) ->
        file_name_extension(_, Ext, FilePath),
        ext_to_mime(Ext, Mime),
        read_file_to_string(FilePath, Content, []),
        throw(http_reply(bytes(Mime, Content)))
    ;
        throw(http_reply(not_found(FilePath)))
    ).

ext_to_mime(css, 'text/css') :- !.
ext_to_mime(js, 'application/javascript') :- !.
ext_to_mime(html, 'text/html') :- !.
ext_to_mime(json, 'application/json') :- !.
ext_to_mime(png, 'image/png') :- !.
ext_to_mime(svg, 'image/svg+xml') :- !.
ext_to_mime(_, 'application/octet-stream').

%% server_base_dir(-Dir) - Get the base directory of the DALI2 installation
server_base_dir(Dir) :-
    source_file(server:main, File),
    file_directory_name(File, SrcDir),
    file_directory_name(SrcDir, Dir).

%% ============================================================
%% API HANDLERS
%% ============================================================

%% GET /api/status - System status
api_status(_Request) :-
    cors_enable,
    bb_agents(Agents),
    length(Agents, Count),
    (current_agent_file(F) -> File = F ; File = ''),
    (ai_oracle:ai_available -> AI = true ; AI = false),
    (ai_oracle:ai_model(Model) -> true ; Model = 'none'),
    federation:fed_node_name(NodeName),
    federation:fed_peers(Peers),
    length(Peers, PeerCount),
    reply_json_dict(_{status: running, agents: Count, file: File,
                      ai_enabled: AI, ai_model: Model,
                      node: NodeName, peers: PeerCount}).

%% GET /api/agents - List agents with status
api_agents(_Request) :-
    cors_enable,
    findall(
        _{name: Name, status: Status, cycle: Cycle},
        (loader:agent_def(Name, Opts),
         engine:agent_status(Name, Status),
         (member(cycle(C), Opts) -> Cycle = C ; Cycle = 1)
        ),
        AgentList
    ),
    reply_json_dict(_{agents: AgentList}).

%% GET /api/logs?agent=Name&since=Timestamp
api_logs(Request) :-
    cors_enable,
    http_parameters(Request, [
        agent(Agent, [optional(true), default('')]),
        since(Since, [optional(true), default(0), number])
    ]),
    (Agent = '' ->
        findall(
            _{agent: N, time: T, message: Msg},
            (engine:agent_log_entry(N, T, Msg), T > Since),
            Entries0
        )
    ;
        atom_string(AgentAtom, Agent),
        findall(
            _{agent: AgentAtom, time: T, message: Msg},
            (engine:agent_log_entry(AgentAtom, T, Msg), T > Since),
            Entries0
        )
    ),
    % Return last 200 entries max
    length(Entries0, Len),
    (Len > 200 ->
        Skip is Len - 200,
        length(Prefix, Skip),
        append(Prefix, Entries, Entries0)
    ;
        Entries = Entries0
    ),
    reply_json_dict(_{logs: Entries}).

%% POST /api/send - Send a message to an agent (local or remote)
%%   Body: {"to": "agent_name", "content": "event(args)"}
api_send(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(To, Dict.to),
    atom_string(ContentStr, Dict.content),
    catch(
        (term_string(Content, ContentStr),
         (federation:fed_is_local(To) ->
             %% Local agent — inject directly
             engine:inject_event(To, Content)
         ;
             %% Remote agent — forward via federation
             (federation:fed_find_agent(To, PeerName) ->
                 federation:fed_remote_send(PeerName, user, To, Content)
             ;
                 %% Agent not found anywhere, try local inject anyway
                 engine:inject_event(To, Content)
             )
         ),
         reply_json_dict(_{ok: true, message: "Message sent"})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% POST /api/inject - Inject an event into an agent
%%   Body: {"agent": "name", "event": "event(args)"}
api_inject(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Agent, Dict.agent),
    atom_string(EventStr, Dict.event),
    catch(
        (term_string(Event, EventStr),
         engine:inject_event(Agent, Event),
         reply_json_dict(_{ok: true, message: "Event injected"})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% POST /api/start - Start an agent
%%   Body: {"agent": "name"}
api_start(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Agent, Dict.agent),
    catch(
        (engine:start_agent(Agent),
         reply_json_dict(_{ok: true, message: "Agent started"})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% POST /api/stop - Stop an agent
%%   Body: {"agent": "name"}
api_stop(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Agent, Dict.agent),
    catch(
        (engine:stop_agent(Agent),
         reply_json_dict(_{ok: true, message: "Agent stopped"})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% POST /api/reload - Reload agent definitions and restart
%%   Body: {"file": "path"} (optional, uses current file if omitted)
api_reload(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    (get_dict(file, Dict, FileStr) ->
        atom_string(File, FileStr)
    ;
        current_agent_file(File)
    ),
    catch(
        (engine:stop_all,
         retractall(current_agent_file(_)),
         assert(current_agent_file(File)),
         loader:load_agents(File),
         engine:start_all,
         reply_json_dict(_{ok: true, message: "Reloaded"})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% GET /api/beliefs?agent=Name
api_beliefs(Request) :-
    cors_enable,
    http_parameters(Request, [
        agent(Agent, [optional(true), default('')])
    ]),
    (Agent = '' ->
        findall(
            _{agent: N, belief: B},
            (engine:agent_belief_rt(N, B0), term_to_atom(B0, B)),
            Beliefs
        )
    ;
        atom_string(AgentAtom, Agent),
        findall(
            _{agent: AgentAtom, belief: B},
            (engine:agent_belief_rt(AgentAtom, B0), term_to_atom(B0, B)),
            Beliefs
        )
    ),
    reply_json_dict(_{beliefs: Beliefs}).

%% GET /api/past?agent=Name
api_past(Request) :-
    cors_enable,
    http_parameters(Request, [
        agent(Agent, [optional(true), default('')])
    ]),
    (Agent = '' ->
        findall(
            _{agent: N, event: Ev, time: T, source: Src},
            (engine:agent_past_event(N, Ev0, T, Src),
             term_to_atom(Ev0, Ev)),
            Events
        )
    ;
        atom_string(AgentAtom, Agent),
        findall(
            _{agent: AgentAtom, event: Ev, time: T, source: Src},
            (engine:agent_past_event(AgentAtom, Ev0, T, Src),
             term_to_atom(Ev0, Ev)),
            Events
        )
    ),
    reply_json_dict(_{past: Events}).

%% GET /api/blackboard - View blackboard contents
api_blackboard(_Request) :-
    cors_enable,
    findall(
        T,
        (blackboard:tuple(T0), term_to_atom(T0, T)),
        Tuples
    ),
    reply_json_dict(_{tuples: Tuples}).

%% GET /api/source - Get current agent file source
api_source(_Request) :-
    cors_enable,
    (current_agent_file(File), File \= '', exists_file(File) ->
        read_file_to_string(File, Content, []),
        reply_json_dict(_{file: File, content: Content})
    ;
        reply_json_dict(_{file: '', content: ''})
    ).

%% POST /api/save - Save agent file source
%%   Body: {"content": "...source code..."}
api_save(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    (current_agent_file(File), File \= '' ->
        atom_string(Content, Dict.content),
        setup_call_cleanup(
            open(File, write, Stream),
            write(Stream, Content),
            close(Stream)
        ),
        reply_json_dict(_{ok: true, message: "Saved"})
    ;
        reply_json_dict(_{ok: false, error: "No agent file loaded"})
    ).

%% ============================================================
%% AI ORACLE API HANDLERS
%% ============================================================

%% GET /api/ai/status - AI oracle status
api_ai_status(_Request) :-
    cors_enable,
    (ai_oracle:ai_available -> Enabled = true ; Enabled = false),
    (ai_oracle:ai_model(Model) -> true ; Model = 'none'),
    reply_json_dict(_{enabled: Enabled, model: Model}).

%% POST /api/ai/key - Set the OpenAI API key at runtime
%%   Body: {"key": "sk-..."}
api_ai_key(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Key, Dict.key),
    ai_oracle:set_ai_key(Key),
    reply_json_dict(_{ok: true, message: "API key set"}).

%% POST /api/ai/model - Set the AI model
%%   Body: {"model": "gpt-4o-mini"}
api_ai_model(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Model, Dict.model),
    ai_oracle:set_ai_model(Model),
    reply_json_dict(_{ok: true, message: "Model set"}).

%% POST /api/ai/ask - Directly query the AI oracle from the UI
%%   Body: {"context": "...", "system_prompt": "..."} (system_prompt optional)
api_ai_ask(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Context, Dict.context),
    catch(
        (   (get_dict(system_prompt, Dict, SysStr), SysStr \= "" ->
                atom_string(SysPrompt, SysStr),
                ai_oracle:ask_ai(Context, SysPrompt, Result)
            ;
                ai_oracle:ask_ai(Context, Result)
            ),
            term_to_atom(Result, ResultAtom),
            reply_json_dict(_{ok: true, result: ResultAtom})
        ),
        Error,
        (term_to_atom(Error, ErrAtom),
         reply_json_dict(_{ok: false, error: ErrAtom}))
    ).

%% ============================================================
%% FEDERATION API HANDLERS
%% ============================================================

%% GET /api/peers - List known peer instances
api_peers(_Request) :-
    cors_enable,
    federation:fed_node_name(MyName),
    federation:fed_node_url(MyUrl),
    federation:fed_peers(Peers),
    reply_json_dict(_{node: MyName, url: MyUrl, peers: Peers}).

%% POST /api/peers/register - Register a peer instance
%%   Body: {"name": "node2", "url": "http://host:port"}
api_peer_register(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Name, Dict.name),
    atom_string(Url, Dict.url),
    catch(
        (federation:fed_register_peer(Name, Url),
         reply_json_dict(_{ok: true, message: "Peer registered"})),
        Error,
        (term_to_atom(Error, E),
         reply_json_dict(_{ok: false, error: E}))
    ).

%% POST /api/peers/unregister - Remove a peer
%%   Body: {"name": "node2"}
api_peer_unregister(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(Name, Dict.name),
    federation:fed_unregister_peer(Name),
    reply_json_dict(_{ok: true, message: "Peer unregistered"}).

%% POST /api/peers/sync - Sync agent lists with all peers
api_peer_sync(_Request) :-
    cors_enable,
    catch(
        (federation:fed_sync_all,
         reply_json_dict(_{ok: true, message: "Synced"})),
        Error,
        (term_to_atom(Error, E),
         reply_json_dict(_{ok: false, error: E}))
    ).

%% GET /api/remote/agents - List local agents (called by peers during sync)
api_remote_agents(_Request) :-
    cors_enable,
    bb_agents(LocalAgents),
    reply_json_dict(_{agents: LocalAgents}).

%% POST /api/remote/receive - Receive a message from a remote peer
%%   Body: {"from": "agent_name", "to": "agent_name", "content": "term_string"}
api_remote_receive(Request) :-
    cors_enable,
    http_read_json_dict(Request, Dict),
    atom_string(From, Dict.from),
    atom_string(To, Dict.to),
    atom_string(ContentStr, Dict.content),
    catch(
        (term_string(Content, ContentStr),
         communication:deliver_remote(From, To, Content),
         reply_json_dict(_{ok: true})),
        Error,
        (term_to_atom(Error, E),
         reply_json_dict(_{ok: false, error: E}))
    ).
