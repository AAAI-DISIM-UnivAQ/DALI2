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
# Default (agriculture example, no AI)
docker compose up --build

# Choose agent file (Linux/macOS)
AGENT_FILE=examples/emergency.pl docker compose up --build

# PowerShell
$env:AGENT_FILE="examples/emergency.pl"; docker compose up --build

# With OpenAI API key (Linux/macOS)
OPENAI_API_KEY=sk-your-key docker compose up --build

# PowerShell
$env:OPENAI_API_KEY="sk-your-key"; docker compose up --build
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Distributed Mode (multiple machines)

Run agents across separate containers that communicate via HTTP federation:

```sh
docker compose -f docker-compose.distributed.yml up --build
```

This starts two nodes:
- **sensors** (`http://localhost:8081`) — sensor + logger agents
- **responders** (`http://localhost:8082`) — coordinator + evacuator + responder + communicator

Agents automatically discover each other and route messages across nodes.

### Windows

Run `run.bat` — choose single or distributed mode interactively:

```sh
run.bat
```

### Without Docker

Requires [SWI-Prolog](https://www.swi-prolog.org/) installed locally.

```sh
# Single instance
swipl -l src/server.pl -g main -t halt -- 8080 examples/agriculture.pl

# Named node with agent filter
swipl -l src/server.pl -g main -t halt -- 8080 examples/emergency_sensors.pl --name sensors
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
| `ask_ai(Context, Result)` | Query the AI oracle, get a Prolog fact back |
| `ask_ai(Context, Prompt, Result)` | Query AI with custom system prompt |
| `ai_available` | Check if AI oracle is configured |

All standard Prolog predicates (arithmetic, comparison, list operations, etc.) are also available.

## AI Oracle (ChatGPT Integration)

DALI2 can connect to OpenAI's ChatGPT API. Agents send context and receive a Prolog fact back.

### Configuration

- **Environment variable**: Set `OPENAI_API_KEY` when starting the Docker container
- **Web UI**: Enter the key in the "AI Oracle" panel at runtime
- **API**: `POST /api/ai/key` with `{"key": "sk-..."}`

The API key is **optional** — if not set, `ai_available` fails and `ask_ai` returns `suggestion(no_ai_available)`.

### Usage in agents

```prolog
my_agent:on(analyze(Data)) :-
    ( ai_available ->
        ask_ai(analyze_situation(Data), Advice),
        log("AI says: ~w", [Advice]),
        send(coordinator, ai_recommendation(Advice))
    ;
        log("AI not available, using default logic")
    ).
```

### Supported models

`gpt-4o-mini` (default), `gpt-4o`, `gpt-4-turbo`, `gpt-3.5-turbo`. Change via web UI or `POST /api/ai/model`.

## Web UI

The web interface at `http://localhost:8080` provides:

- **Agent list** — shows local and remote agents with running/stopped status
- **Event log** — real-time log with filtering by agent
- **Send events** — inject events into any agent from the browser
- **Agent details** — beliefs, past events, start/stop controls
- **Blackboard viewer** — current shared blackboard state
- **Source editor** — edit and hot-reload agent definitions (double-click the DALI2 logo)
- **Federation panel** — connect peers, view remote agents across nodes
- **AI Oracle panel** — configure API key, model, and test AI queries

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
| GET | `/api/ai/status` | AI oracle status (enabled, model) |
| POST | `/api/ai/key` | Set OpenAI API key `{"key":"sk-..."}` |
| POST | `/api/ai/model` | Set AI model `{"model":"gpt-4o"}` |
| POST | `/api/ai/ask` | Query AI `{"context":"..."}` |
| GET | `/api/peers` | List federation peers |
| POST | `/api/peers/register` | Connect a peer `{"name":"n","url":"http://..."}` |
| POST | `/api/peers/unregister` | Disconnect a peer `{"name":"n"}` |
| POST | `/api/peers/sync` | Sync agent lists with all peers |
| GET | `/api/remote/agents` | List local agents (for peer queries) |
| POST | `/api/remote/receive` | Receive message from remote peer |

## Project Structure

```
DALI2/
├── src/
│   ├── blackboard.pl      # Shared in-memory blackboard
│   ├── communication.pl   # Message passing (local + remote)
│   ├── federation.pl      # Distributed peer federation
│   ├── loader.pl          # Agent file parser
│   ├── engine.pl          # Core metainterpreter
│   ├── ai_oracle.pl       # OpenAI/ChatGPT integration
│   └── server.pl          # HTTP server + entry point
├── web/
│   ├── index.html         # Dashboard SPA
│   ├── app.js             # Frontend logic
│   └── style.css          # Styling
├── examples/
│   ├── agriculture.pl           # Smart agriculture (single node)
│   ├── emergency.pl             # Emergency response (single node)
│   ├── emergency_sensors.pl     # Distributed: sensor node
│   └── emergency_responders.pl  # Distributed: responder node
├── Dockerfile
├── docker-compose.yml               # Single instance
├── docker-compose.distributed.yml   # Multi-instance federation
├── run.bat
└── README.md
```

## Comparison with DALI

| Aspect | DALI | DALI2 |
|--------|------|-------|
| Source files | ~20 | 7 |
| Agent definition | Multiple files (instances.json + type files) | Single .pl file |
| Process model | Separate process per agent + Linda server | Multi-threaded (single or multi-node) |
| Communication | TCP sockets (Linda) | In-memory blackboard + HTTP federation |
| Tokenizer | Complex (tokefun + togli_var + metti_var) | None (direct term_expansion) |
| UI | Separate Python project (dalia) | Integrated web UI |
| AI integration | External Python TCP service | Built-in (direct OpenAI API calls) |
| Docker setup | Complex (SICStus install) | Simple (swipl base image) |
| Event syntax | `eventE(X) :> body.` | `agent:on(event(X)) :- body.` |
| Message sending | `messageA(dest, send_message(ev(X), Me))` | `send(dest, ev(X))` |

## License

Apache License 2.0
