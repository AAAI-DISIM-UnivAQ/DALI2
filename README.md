# DALI2

> Multi-Agent System Framework built on SWI-Prolog — DALI-compatible syntax, process-based agents

DALI2 is the evolution of the [DALI](https://github.com/AAAI-DISIM-UnivAQ/DALI) multi-agent system framework, now running on SWI-Prolog with DALI-compatible syntax and a process-per-agent architecture.

## Key Features

- **Identical DALI syntax** — no prefix needed, same operators (`:>`, `:<`, `~/`, `</`, `?/`) and suffixes (`E`, `I`, `A`, `N`, `P`) as the original DALI
- **Single-file multi-agent** — define all agents in one `.pl` file; `:- agent(name).` sets the context for subsequent rules
- **Full DALI feature set** — reactive rules, internal events, goals, constraints, learning, ontologies, tell/told filtering (with body conditions), multi-events (with delta-t), and more
- **Process-per-agent architecture** — each agent runs as a separate OS process
- **Redis star topology** — agents communicate via Redis pub/sub (`LINDA` channel for messages, `LOGS` channel for monitoring)
- **Integrated web UI** — dashboard, log viewer, message sender, agent inspector
- **Docker-ready** — runs in a container with Redis, no local installation needed
- **LAN-ready** — remote machines on the same network just point to the same Redis instance
- **AI Oracle** — connect to any LLM via OpenRouter (GPT, Claude, Gemini, etc.)
- **Extra features** — periodic tasks, condition monitors, helpers, blackboard

**Documentation:** [RULES.md](RULES.md) (language reference) · [EXAMPLES.md](EXAMPLES.md) (examples guide)

## Prerequisites

### With Docker (recommended — no other install needed)

- **Docker Desktop** — [https://www.docker.com/products/docker-desktop](https://www.docker.com/products/docker-desktop)

Docker Compose starts Redis automatically. No separate Redis install required.

### Without Docker

- **SWI-Prolog** (≥ 9.0) — [https://www.swi-prolog.org/download/stable](https://www.swi-prolog.org/download/stable)
- **Redis** (≥ 6.0) — [https://redis.io/downloads](https://redis.io/downloads)
  - **Windows:** [https://github.com/tporadowski/redis/releases](https://github.com/tporadowski/redis/releases) or via WSL
  - **macOS:** `brew install redis`
  - **Linux:** `sudo apt install redis-server` or `sudo dnf install redis`

Redis **must** be running before starting DALI2. By default, DALI2 connects to `localhost:6379`. Override with environment variables `REDIS_HOST` and `REDIS_PORT`.

```sh
# Start Redis (if installed locally)
redis-server

# Or run Redis via Docker (even if DALI2 itself runs without Docker)
docker run -d --name dali2-redis -p 6379:6379 redis:7-alpine
```

## Quick Start

### With Docker (recommended)

```sh
# Default (agriculture example, no AI)
docker compose up --build

# Choose agent file (Linux/macOS)
AGENT_FILE=examples/emergency.pl docker compose up --build

# PowerShell
$env:AGENT_FILE="examples/emergency.pl"; docker compose up --build

# With OpenRouter API key (Linux/macOS)
OPENROUTER_API_KEY=sk-or-... docker compose up --build

# PowerShell
$env:OPENROUTER_API_KEY="sk-or-..."; docker compose up --build
```

Open [http://localhost:8080](http://localhost:8080) in your browser.

### Deployment Modes

DALI2 uses a **Redis star topology** for all communication. Every agent process connects to the same Redis instance. Messages are routed by agent name through the `LINDA` pub/sub channel — regardless of which terminal or machine the agent runs on. No code changes needed between modes.

```
┌──────────────────────────────────────────┐
│              REDIS SERVER                │
│   LINDA channel │ LOGS channel │ BB SET  │
└──────┬─────────────┬─────────────┬───────┘
       │             │             │
  ┌────┴────┐  ┌─────┴────┐  ┌─────┴───┐
  │ Node A  │  │  Node B  │  │ Node C  │
  │ agent_1 │  │ agent_3  │  │ agent_5 │
  │ agent_2 │  │ agent_4  │  │ agent_6 │
  └─────────┘  └──────────┘  └─────────┘
```

#### Mode A: All-in-one (single terminal)

One Redis, one server, all agents. Simplest setup.

```sh
# Docker (recommended) — Redis is started automatically
docker compose up --build

# Without Docker — start Redis first (see Prerequisites), then:
swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl
```

#### Mode B: Multi-terminal (same machine)

Multiple server instances share one Redis. Each starts a subset of agents with `--agents`.

```sh
# Step 1: Start Redis (if not already running)
docker run -d --name dali2-redis -p 6379:6379 redis:7-alpine

# Step 2: Terminal 1 — sensors node (port 8081)
swipl -l src/server.pl -g main -- 8081 examples/agriculture.pl \
  --name sensors --agents soil_sensor,weather_monitor,logger

# Step 3: Terminal 2 — advisors node (port 8082)
swipl -l src/server.pl -g main -- 8082 examples/agriculture.pl \
  --name advisors --agents crop_advisor,irrigation_controller,farmer_agent
```

Both nodes connect to `localhost:6379` by default. Agents on different nodes communicate through Redis automatically.

> **PowerShell:** same commands, just replace `\` with `` ` `` for line continuation.

#### Mode C: Multi-machine

Same as Mode B, but Redis runs on a chosen machine. All nodes point `REDIS_HOST` to that machine.

```sh
# Machine X (192.168.1.10): Start Redis
docker run -d -p 6379:6379 redis:7-alpine

# Machine Y: Start sensors node
REDIS_HOST=192.168.1.10 swipl -l src/server.pl -g main -- 8081 \
  examples/agriculture.pl --name sensors \
  --agents soil_sensor,weather_monitor,logger

# Machine Z: Start advisors node
REDIS_HOST=192.168.1.10 swipl -l src/server.pl -g main -- 8082 \
  examples/agriculture.pl --name advisors \
  --agents crop_advisor,irrigation_controller,farmer_agent
```

> **PowerShell:**
> ```powershell
> $env:REDIS_HOST="192.168.1.10"; swipl -l src/server.pl -g main -- 8081 `
>   examples/agriculture.pl --name sensors --agents soil_sensor,weather_monitor,logger
> ```

#### Pre-configured distributed example (Docker Compose)

A ready-made two-node example with shared Redis:

```sh
docker compose -f docker-compose.distributed.yml up --build
```

This starts a shared Redis, `sensors` on port 8081, and `responders` on port 8082 — all connected automatically.

#### Testing the distributed setup

Send a soil reading to the sensor:

```sh
# Linux/macOS
curl -X POST http://localhost:8081/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"soil_sensor","content":"read_soil(25, 6.5, north_field)"}'

# PowerShell
curl.exe -X POST http://localhost:8081/api/send -H "Content-Type: application/json" `
  -d '{\"to\":\"soil_sensor\",\"content\":\"read_soil(25, 6.5, north_field)\"}'
```

Expected chain of events across nodes:

1. **soil_sensor** (Node A) receives `read_soil`, sends `soil_report` → **crop_advisor** (Node B) via Redis
2. **crop_advisor** (Node B) detects low moisture, sends `irrigate` → **irrigation_controller** (Node B)
3. **irrigation_controller** (Node B) activates irrigation, sends `log_event` → **logger** (Node A) via Redis
4. **logger** (Node A) logs events from both local and remote agents

Open the web UI on either node to see the **Cluster** panel showing all agents across all nodes.

#### Cleanup

```sh
# Docker Compose
docker compose down
docker compose -f docker-compose.distributed.yml down

# Standalone Redis
docker stop dali2-redis && docker rm dali2-redis
```

> **Tip:** The `--init` flag and `init: true` in docker-compose files ensure CTRL+C stops containers cleanly.

### Windows

Run `run.bat` — choose single or distributed mode interactively:

```sh
run.bat
```

## Agent Language

Agents are defined in a single `.pl` file using **identical DALI syntax** — no prefix needed. Each `:- agent(name).` directive sets the context for subsequent rules.

See **[RULES.md](RULES.md)** for the complete reference and **[EXAMPLES.md](EXAMPLES.md)** for walkthroughs.

```prolog
:- agent(my_agent, [cycle(1)]).

%% External event (E suffix + :> operator) — identical to DALI
alarmE(Type, Location) :>
    log("Alarm: ~w at ~w", [Type, Location]),
    assert_belief(active(Type, Location)),
    messageA(responder, send_message(dispatch(Type, Location), my_agent)).

%% Internal event (I suffix + :> operator + internal_event/5)
check_statusI :>
    believes(active(Type, Location)),
    log("Still active: ~w at ~w", [Type, Location]).
internal_event(check_status, 5, forever, true, forever).

%% Condition-action rule (:< operator)
believes(active(_, _)) :<
    log("Alert condition activated!"),
    send(logger, log_event(alert_active, my_agent)).

%% Export past (~/ operator)
send(logger, report(Type, Loc)) ~/
    alarm(Type, Loc), response(Loc).

%% Told rules (DALI communication.con style)
told(_, alarm(_,_), 100) :- true.
told(_, status(_), 50) :- true.

%% Past event lifetime
past_event(alarm(_,_), 60).
remember_event(alarm(_,_), 3600).

%% Obtain goal
obt_goal(believes(all_clear)) :-
    send(coordinator, check_status_request).

%% Action definition (A suffix)
dispatchA(Type, Location) :-
    log("Dispatching for ~w at ~w", [Type, Location]).

%% Initial beliefs
believes(status(idle)).
```

**Additional features:** `every` (periodic), `when` (condition monitor), `helper` (utility predicates), `on_proposal` (action proposals), `learn_from` (learning), `ontology`/`ontology_file`, `ask_ai` (AI Oracle), `bb_read`/`bb_write`/`bb_remove` (blackboard).

## Architecture: Redis Star Topology

Each agent runs as a **separate OS process**. All agents communicate through **Redis** in a star topology:

```
                    ┌─────────────┐
                    │    Redis    │
                    │  ┌───────┐  │
                    │  │ LINDA │  │  ← pub/sub channel for messages
                    │  │ LOGS  │  │  ← pub/sub channel for monitoring
                    │  │  BB   │  │  ← SET for shared blackboard
                    │  └───────┘  │
                    └──────┬──────┘
              ┌────────────┼────────────┐
              ↕            ↕            ↕
        ┌──────────┐ ┌──────────┐ ┌──────────┐
        │ Agent 1  │ │ Agent 2  │ │ Agent N  │
        │ (swipl)  │ │ (swipl)  │ │ (swipl)  │
        └──────────┘ └──────────┘ └──────────┘

        ┌──────────────────────────────────────┐
        │         Master Server (:8080)        │
        │  Web UI · REST API · Cluster         │
        └──────────────────────────────────────┘
```

**LINDA channel** — all agents subscribe. Messages published as `TO:CONTENT:FROM` where `TO` is the destination agent (`*` for broadcast), `CONTENT` is the serialized Prolog term, `FROM` is the sender.

**LOGS channel** — agents publish log entries for external monitoring. No subscription needed.

**BB (Redis SET)** — shared blackboard replacing DALI's Linda tuple space. Agents read/write tuples via `bb_read`/`bb_write`/`bb_remove`.

**LAN support** — remote machines on the same network just point to the same Redis instance via `REDIS_HOST` environment variable.

## AI Oracle (via OpenRouter)

DALI2 can connect to any LLM through [OpenRouter](https://openrouter.ai/). Agents send context and receive a Prolog fact back.

### Configuration

- **Environment variable**: Set `OPENROUTER_API_KEY` when starting the Docker container
- **Web UI**: Enter the key in the "AI Oracle" panel at runtime
- **API**: `POST /api/ai/key` with `{"key": "sk-or-..."}`

The API key is **optional** — if not set, `ai_available` fails and `ask_ai` returns `suggestion(no_ai_available)`.

### Usage in agents

```prolog
:- agent(my_agent, [cycle(2)]).

analyzeE(Data) :>
    ( ai_available ->
        ask_ai(analyze_situation(Data), Advice),
        log("AI says: ~w", [Advice]),
        send(coordinator, ai_recommendation(Advice))
    ;
        log("AI not available, using default logic")
    ).
```

### Supported models

The web UI model selector shows both **free** and **paid** models. Free models are marked with `(free)`.

**Free models (no credit required):**
`google/gemini-2.0-flash-exp:free` (default), `meta-llama/llama-3.3-70b-instruct:free`, `qwen/qwen-2.5-72b-instruct:free`, `deepseek/deepseek-chat-v3-0324:free`, and others.

**Paid models:**
`openai/gpt-4o-mini`, `openai/gpt-4o`, `anthropic/claude-sonnet-4`, `google/gemini-2.5-pro-preview`, and [any model on OpenRouter](https://openrouter.ai/models).

Change via web UI or `POST /api/ai/model`.

## Web UI

The web interface at `http://localhost:8080` provides:

- **Agent list** — shows local and remote agents with running/stopped status
- **Event log** — real-time log with filtering by agent
- **Send events** — inject events into any agent from the browser
- **Agent details** — beliefs, past events, start/stop controls
- **Blackboard viewer** — current shared blackboard state
- **Source editor** — edit and hot-reload agent definitions (double-click the DALI2 logo)
- **Cluster panel** — view all agents across all nodes in the Redis cluster
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
| GET | `/api/learned?agent=X` | Get learned patterns |
| GET | `/api/goals?agent=X` | Get goal statuses |
| GET | `/api/blackboard` | View blackboard tuples |
| GET | `/api/source` | Get agent file source |
| POST | `/api/save` | Save agent file `{"content":"..."}` |
| GET | `/api/ai/status` | AI oracle status (enabled, model) |
| POST | `/api/ai/key` | Set OpenRouter API key `{"key":"sk-or-..."}` |
| POST | `/api/ai/model` | Set AI model `{"model":"gpt-4o"}` |
| POST | `/api/ai/ask` | Query AI `{"context":"..."}` |
| GET | `/api/cluster` | List all agents in the Redis cluster, grouped by node |

## Comparison with DALI

| Aspect | DALI (SICStus) | DALI2 (SWI-Prolog) |
|--------|----------------|---------------------|
| Source files | ~20 | 8 |
| Agent definition | Multiple files (instances + type files) | Single `.pl` file (multi-agent) |
| Process model | Separate process per agent + Linda server | **Separate OS process per agent** + Redis pub/sub |
| Communication | TCP sockets (Linda) | Redis star topology (pub/sub) |
| Tokenizer | Complex (tokefun + togli_var + metti_var) | None (direct parsing with DALI operators) |
| UI | Separate Python project (dalia) | Integrated web UI |
| AI integration | External Python TCP service | Built-in (OpenRouter API) |
| Docker setup | Complex (SICStus install) | Simple (swipl base image) |
| Event syntax | `eventE(X) :> body.` | `eventE(X) :> body.` (identical!) |
| Message sending | `messageA(dest, send_message(ev(X), Me))` | Same, or `send(dest, ev(X))` |
| Internal events | `eventI :> body.` + `internal_event/5` | `eventI :> body.` + `internal_event/5` (identical!) |
| Tell/told | `told(_, pattern, pri) :- true.` | `told(_, pattern, pri) :- true.` (identical!) |
| FIPA messages | `confirm`/`disconfirm`/`propose`/`query_ref` | `send(to, confirm(fact))` — full FIPA-ACL |
| Action definition | `actionA(X) :- body.` | `actionA(X) :- body.` (identical!) |
| Action proposal | `propose(A,C,Ag)` + `call_propose` | `on_proposal(action) :- body.` |
| Past lifetime | `past_event(ev, 60).` | `past_event(ev, 60).` (identical!) |
| Remember | `remember_event_mod(ev, number(5), last).` | `remember_event_mod(ev, number(5), last).` (identical!) |
| Export past (~/) | `head ~/ past1, past2.` | `head ~/ past1, past2.` (identical!) |
| Export past (</) | `head </ past1, past2.` | `head </ past1, past2.` (identical!) |
| Export past (?/) | `head ?/ past1, past2.` | `head ?/ past1, past2.` (identical!) |
| Residue goals | `tenta_residuo(goal)` | `tenta_residuo(goal)` or `achieve(goal)` |
| Condition-action | `cond :< action.` | `cond :< action.` (identical!) |
| Present events | `condN :- body.` | `condN :- body.` (identical!) |
| Multi-events | `ev1E, ev2E :> body.` | `ev1E, ev2E :> body.` (identical!) |
| Constraints | `:~ constraint.` | `:~ constraint.` (identical!) |
| Ontologies | `meta/3` + OWL files | `ontology(same_as(a,b)).` + `ontology_file` |
| Learning | `learning.pl` + constraints | `learn_from(event, outcome) :- body.` |
| Goals | `obt_goal(goal) :- plan.` | `obt_goal(goal) :- plan.` (identical!) |
| Periodic tasks | — | `every(seconds, goal).` |
| Condition monitors | — | `when(condition) :- body.` |
| Helpers | — | `helper(head) :- body.` |
| AI Oracle | — | `ask_ai(context, result)` |
| Blackboard | Linda (TCP) | `bb_read`/`bb_write`/`bb_remove` (Redis) |

## License

Apache License 2.0
