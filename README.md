# DALI2

> Simplified Multi-Agent System Framework built on SWI-Prolog

DALI2 is a complete rewrite of the [DALI](https://github.com/AAAI-DISIM-UnivAQ/DALI) multi-agent system framework, designed for simplicity and ease of use.

## Key Features

- **Single-file agent definitions** — define all agents in one `.pl` file
- **Integrated web UI** — dashboard, log viewer, message sender, agent inspector
- **Docker-ready** — runs in a container, no local installation needed
- **Single-process architecture** — all agents run as threads in one SWI-Prolog instance
- **Simplified syntax** — no tokenizer, no intermediate files, no E/I/A suffixes
- **In-memory blackboard** — no TCP-based Linda server needed

## Quick Start

### With Docker (recommended)

```sh
docker compose up --build
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Without Docker

Requires [SWI-Prolog](https://www.swi-prolog.org/) installed locally.

```sh
swipl -l src/server.pl -g main -t halt -- 8080 examples/agriculture.pl
```

### Windows

```sh
run.bat examples\agriculture.pl
```

## Agent Language

Agents are defined in a single `.pl` file using a simple syntax:

```prolog
%% Declare an agent with options
:- agent(my_agent, [cycle(1)]).

%% React to events from other agents
my_agent:on(some_event(Arg1, Arg2)) :-
    log("Received: ~w, ~w", [Arg1, Arg2]),
    send(other_agent, response(Arg1)).

%% Periodic task (runs every N seconds)
my_agent:every(10, log("Heartbeat")).

%% Condition monitor (checked every cycle)
my_agent:when(believes(temperature(T)), T > 40) :-
    send(alert_agent, overheat(T)).

%% Action definition
my_agent:do(process(X)) :-
    log("Processing ~w", [X]),
    assert_belief(processed(X)).

%% Initial beliefs
my_agent:believes(status(idle)).
```

### DSL Predicates

| Predicate | Description |
|-----------|-------------|
| `send(Agent, Content)` | Send a message to another agent |
| `broadcast(Content)` | Send to all other agents |
| `log(Format, Args)` | Log a formatted message |
| `log(Message)` | Log a simple message |
| `assert_belief(Fact)` | Add a belief to the agent |
| `retract_belief(Fact)` | Remove a belief |
| `believes(Fact)` | Check if agent has a belief |
| `has_past(Event)` | Check if event is in past memory |
| `do(Action)` | Execute a defined action |

All standard Prolog predicates (arithmetic, comparison, list operations, etc.) are also available.

## Web UI

The web interface at `http://localhost:8080` provides:

- **Agent list** — shows all agents with running/stopped status
- **Event log** — real-time log with filtering by agent
- **Send events** — inject events into any agent from the browser
- **Agent details** — beliefs, past events, start/stop controls
- **Blackboard viewer** — current shared blackboard state
- **Source editor** — edit and hot-reload agent definitions (double-click the DALI2 logo)

## REST API

| Method | Endpoint | Description |
|--------|----------|-------------|
| GET | `/api/status` | System status |
| GET | `/api/agents` | List agents with status |
| GET | `/api/logs?agent=X&since=T` | Get log entries |
| POST | `/api/send` | Send event `{"to":"agent","content":"event(args)"}` |
| POST | `/api/inject` | Inject event `{"agent":"name","event":"event(args)"}` |
| POST | `/api/start` | Start agent `{"agent":"name"}` |
| POST | `/api/stop` | Stop agent `{"agent":"name"}` |
| POST | `/api/reload` | Reload agent file `{"file":"path"}` |
| GET | `/api/beliefs?agent=X` | Get agent beliefs |
| GET | `/api/past?agent=X` | Get past events |
| GET | `/api/blackboard` | View blackboard tuples |
| GET | `/api/source` | Get agent file source |
| POST | `/api/save` | Save agent file `{"content":"..."}` |

## Project Structure

```
DALI2/
├── src/
│   ├── blackboard.pl      # Shared in-memory blackboard
│   ├── communication.pl   # Message passing between agents
│   ├── loader.pl          # Agent file parser
│   ├── engine.pl          # Core metainterpreter
│   └── server.pl          # HTTP server + entry point
├── web/
│   ├── index.html         # Dashboard SPA
│   ├── app.js             # Frontend logic
│   └── style.css          # Styling
├── examples/
│   ├── agriculture.pl     # Smart agriculture MAS
│   └── emergency.pl       # Emergency response MAS
├── Dockerfile
├── docker-compose.yml
├── run.bat
└── README.md
```

## Comparison with DALI

| Aspect | DALI | DALI2 |
|--------|------|-------|
| Source files | ~20 | 5 |
| Agent definition | Multiple files (instances.json + type files) | Single .pl file |
| Process model | Separate process per agent + Linda server | Single process, multi-threaded |
| Communication | TCP sockets (Linda) | In-memory blackboard |
| Tokenizer | Complex (tokefun + togli_var + metti_var) | None (direct term_expansion) |
| UI | Separate Python project (dalia) | Integrated web UI |
| Docker setup | Complex (SICStus install) | Simple (swipl base image) |
| Event syntax | `eventE(X) :> body.` | `agent:on(event(X)) :- body.` |
| Message sending | `messageA(dest, send_message(ev(X), Me))` | `send(dest, ev(X))` |

## License

Apache License 2.0
