# DALI2

> Multi-Agent System Framework built on SWI-Prolog — DALI-compatible syntax, process-based agents

DALI2 is the evolution of the [DALI](https://github.com/AAAI-DISIM-UnivAQ/DALI) multi-agent system framework, now running on SWI-Prolog with DALI-compatible syntax and a process-per-agent architecture.

## Key Features

- **Identical DALI syntax** — no prefix needed, same operators (`:>`, `:<`, `~/`, `</`, `?/`) and suffixes (`E`, `I`, `A`, `N`, `P`) as the original DALI, plus `?>` for DALI2's edge-triggered condition-action rules
- **Single-file multi-agent** — define all agents in one `.pl` file; `:- agent(name).` sets the context for subsequent rules
- **Full DALI feature set** — reactive rules, internal events, goals, constraints, learning (pattern-association + code-injection via FIPA), ontologies, tell/told filtering (with body conditions), multi-events (with delta-t), and more
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

%% Internal event (I suffix + :> operator)
%% internal_event/5 is optional (DALI2 extension) — without it, defaults apply
check_statusI :>
    believes(active(Type, Location)),
    log("Still active: ~w at ~w", [Type, Location]).
internal_event(check_status, 5, forever, true, forever).  %% DALI2 extension

%% Condition-action rule (?> operator, edge-triggered — DALI2 extension)
believes(active(_, _)) ?>
    log("Alert condition activated!"),
    messageA(logger, send_message(log_event(alert_active, my_agent), Me)).

%% Export past (~/ operator)
messageA(logger, send_message(report(Type, Loc), Me)) ~/
    alarm(Type, Loc), response(Loc).

%% Told rules (DALI communication.con style)
told(_, alarm(_,_), 100) :- true.
told(_, status(_), 50) :- true.

%% Past event lifetime
past_event(alarm(_,_), 60).
remember_event(alarm(_,_), 3600).

%% Obtain goal
obt_goal(believes(all_clear)) :-
    messageA(coordinator, send_message(check_status_request, Me)).

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
        messageA(coordinator, send_message(ai_recommendation(Advice), Me))
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

### Infrastructure (transparent to agent code)

| Aspect | DALI (SICStus) | DALI2 (SWI-Prolog) |
|--------|----------------|---------------------|
| Source files | ~20 | 8 |
| Agent definition | Multiple files (instances + type files) | Single `.pl` file (multi-agent via `:- agent(name).`) |
| Process model | Separate process per agent + Linda server | Separate OS process per agent + Redis pub/sub |
| Communication | TCP sockets (Linda) | Redis star topology (pub/sub) |
| Tokenizer | Complex (tokefun + togli_var + metti_var) | None (direct parsing with DALI operators) |
| UI | Separate Python project (dalia) | Integrated web UI |
| AI integration | External Python TCP service | Built-in (OpenRouter API) |
| Docker setup | Complex (SICStus install) | Simple (swipl base image) |

### Agent language syntax

All DALI syntax works in DALI2. The table below shows what DALI2 **also** accepts beyond the original forms.

| Feature | DALI | DALI2 accepts DALI form? | DALI2 additional forms |
|---------|------|--------------------------|----------------------|
| External events | `eventE(X) :> body.` | Yes — identical | — |
| Internal events | `eventI :> body.` (config auto-generated) | Yes — identical | Optional `internal_event/5` for explicit config |
| Actions | `actionA(X) :- body.` | Yes — identical | — |
| Action preconditions | `actionA :< precondition.` | Yes — same syntax | Now actually enforced (DALI had a bug — see below) |
| Event preconditions | `cd(event) :- body.` / `eve_cond/1` | Yes — `cd/1` accepted | Also `eventE :< precondition.` |
| Constraints | `:~ constraint.` | Yes — identical | — |
| Tell/told | `told(_, pattern, pri) :- body.` | Yes — identical | — |
| FIPA messages | `messageA(to, perf(content, Me))` | Yes — identical (all performatives incl. `request`) | Also `send(to, content)` shorthand |
| All DALI message forms | `messageA/2,3`, `message/2`, `message/7` | Yes — all auto-converted to `send/2` | — |
| Multi-events | `ev1E, ev2E :> body.` + `deltat/1` / `t60.` | Yes — `deltat/1` and `t<N>` shorthand accepted | Also `within(N)` inline (per-rule interval) |
| Goals | `obt_goal(goal) :- plan.` | Yes — identical | — |
| Test goals | `test_goal(goal) :- plan.` | Yes — identical | — |
| Residue goals | `tenta_residuo(goal)` | Yes — identical | Also `achieve(goal)` |
| Past check | `evp(event)` / `eventP(args)` / `past(event,_,_)` | Yes — all accepted | Also `has_past(event)` |
| Belief check | `clause(isa(fact,_,_),_)` / `isa(fact,_,_)` | Yes — both accepted | Also `believes(fact)` |
| Export past (~/) | `head ~/ past1, past2.` | Yes — identical | — |
| Export past (</) | `head </ past1, past2.` | Yes — identical | — |
| Export past (?/) | `head ?/ past1, past2.` | Yes — identical | — |
| Past lifetime | `past_event(ev, 60).` | Yes — identical | — |
| Remember | `remember_event(ev, 3600).` | Yes — identical | — |
| Ontology | `meta/3` + OWL files | Yes — `meta/3` accepted as no-op | Also `ontology(same_as(a,b)).` inline |
| assert/retract on facts | `assert(Fact)` / `retract(Fact)` | Yes — routes to per-agent belief store | — |
| Arbitrary Prolog clauses | `head :- body.` | Yes — stored as per-agent KB | — |

### DALI2 new features (not in DALI, all optional)

| Feature | Syntax |
|---------|--------|
| Edge-triggered condition-action | `cond ?> action.` |
| Periodic tasks | `every(seconds, goal).` |
| Condition monitors | `when(condition) :- body.` |
| Helpers | `helper(head) :- body.` |
| Action proposal handlers | `on_proposal(action) :- body.` |
| Pattern-association learning | `learn_from(event, outcome) :- body.` |
| AI Oracle | `ask_ai(context, result)` |
| Blackboard (Redis) | `bb_read`/`bb_write`/`bb_remove` |

## Migrating from DALI to DALI2

DALI2 is designed to be **highly retrocompatible** with DALI. In most cases, you can take existing DALI code, paste it into a DALI2 `.pl` file, add `:- agent(name).` at the top, and it will work — no other syntax changes required.

### The only required change

| What | Why |
|------|-----|
| Add `:- agent(name).` before each agent's rules | DALI2 supports multiple agents in a single file; the directive tells the loader which agent owns the subsequent rules |

That's it. All DALI operators (`:>`, `:<`, `~/`, `</`, `?/`, `:~`), suffixes (`E`, `I`, `A`, `N`, `P`, `R`, `G`, `T`), and rule forms work identically.

### DALI constructs accepted as-is

These DALI-specific constructs are recognized directly by DALI2 — no rewriting needed:

| DALI construct | DALI2 behavior |
|----------------|----------------|
| `deltat(60).` / `deltaT(60).` | Works as global simultaneity interval for multi-events without inline `within/1` |
| `t60.` (DALI shorthand) | Recognized as `deltat(60)` — the DALI tokenizer rewrites any `t<digits>` atom to `deltat(N)` |
| `cd(event) :- body.` | Works as external-event precondition (DALI `eve_cond` semantics) |
| `eventE :< precondition.` | Works — routes to event precondition gate |
| `messageA(To, send_message(C, Me), ReplyTo)` | Works — 3-arg form with explicit reply-to |
| `message(To, performative(Content, Me))` | Works — direct DALI message form (all FIPA performatives including `request`) |
| `message(IndTo, To, IndS, S, Lang, O, M)` | Works — DALI 7-arg internal transport format |
| `meta/3`, `ontology/3` | Accepted silently (DALI2 uses inline `ontology/1` instead) |
| `told(AgM, IndM, Lang, Ont, Content, Pri)` | DALI 6-arg told — extracts Content + Priority, ignores transport fields |
| `past(Event, _, _)` / `past(Event)` in body | Mapped to `has_past(Event)` |
| `isa(Fact, _, _)` in body | Mapped to `believes(Fact)` |
| `save_on_log_file(X)` in body | Mapped to `log(X)` |
| `now(Time)` in body | SICStus built-in — mapped to SWI `get_time/1` (integer seconds) |
| `datime(D)` in body | SICStus built-in — mapped to SWI `stamp_date_time/2` → `datime(Y,Mo,D,H,Mi,S)` |
| `drop_past(Event)` / `add_past(Event)` / `look_up_past(Event)` | Runtime past management primitives — work as in DALI |
| `set_past(Event, Config)` | Reconfigures past lifetime — executes Config as body term |
| `learn_if(Head, Trigger, Cond) :- Body` | Stored in `agent_learn_if/5` for runtime evaluation |
| `manage_lg(Clause)` / `manage_lg(Clause, From)` | Injects clause into agent KB via `confirm(learn(...))` |
| `send_msg_learn(Clause, Author, Target)` | Sends clause to another agent via FIPA `confirm(learn(...))` |
| `:- assert(ev_normal(Ag, Ev, Pri))` | DALI load-time event injection directive — recognized and ignored with warning (use web UI / REST API to inject events in DALI2) |
| `:- assert(ev_high(Ag, Ev, Pri))` | Same as above for high-priority events |
| `modified_clause/2`, `txt_clause/2` | DALI SICStus file-based persistence — silently ignored (DALI2 uses Redis) |

### DALI2 additional syntax (not in DALI)

These are **new features** that don't exist in DALI. They are optional — DALI code doesn't use them, and DALI2 code doesn't require them.

| Feature | Syntax | Notes |
|---------|--------|-------|
| Edge-triggered condition-action | `cond ?> action.` | Fires once on false→true transition |
| Inline multi-event interval | `within(N)` in event list | More precise than global `deltat/1` — per-rule instead of per-agent |
| Internal event configuration | `internal_event/5` | Optional — defaults match DALI if omitted |
| Periodic tasks | `every(seconds, goal).` | |
| Condition monitors | `when(condition) :- body.` | |
| Helpers | `helper(head) :- body.` | |
| Action proposal handlers | `on_proposal(action) :- body.` | DALI2 exposes this as user syntax |
| Inline ontology | `ontology(same_as(a,b)).` | Replaces external OWL/SPARQL |
| Pattern-association learning | `learn_from(event, outcome) :- body.` | DALI2 native learning paradigm |
| AI Oracle | `ask_ai(context, result)` | |
| Blackboard | `bb_read`/`bb_write`/`bb_remove` | Replaces Linda tuple space |

### Behavioral differences (two)

| Behavior | DALI | DALI2 | Why |
|----------|------|-------|-----|
| Action preconditions (`:<`) | Never checked (DALI bug — key mismatch in `term_expansion`) | Enforced correctly | DALI2 fixes the bug; agents relying on preconditions being ignored may behave differently |
| Constraints (`:~`) | Expanded to `vincolo :- Cond` but never checked at runtime | Checked every cycle; violations logged | DALI2 enforces constraints as invariants |

Everything else — event preconditions, multi-events, goals, tell/told, FIPA messages, export past rules, past lifetime, remember — behaves the same.

## License

Apache License 2.0

## References

To cite our work, please use this information:

> AAAI-DISIM-UnivAQ. (2026). *AAAI-DISIM-UnivAQ/DALI2*. Zenodo. https://doi.org/10.5281/zenodo.19858727

```bibtex
@software{dali2zenodo,
  author       = {AAAI-DISIM-UnivAQ},
  title        = {{AAAI-DISIM-UnivAQ/DALI2}},
  year         = {2026},
  publisher    = {Zenodo},
  doi          = {10.5281/zenodo.19858727},
  url          = {https://doi.org/10.5281/zenodo.19858727}
}
```

### DALI original references

- **DALI 1.0 original website** (no longer active): <http://www.di.univaq.it/stefcost/Sito-Web-DALI/WEB-DALI>

- COSTANTINI, Stefania. *The DALI Agent-Oriented Logic Programming Language: Summary and References.* 2015.

- COSTANTINI S., TOCCHIO A. *A logic programming language for multi-agent systems.* In: Logics in Artificial Intelligence, Springer Berlin Heidelberg, 2002, pp. 1–13.

- COSTANTINI S., TOCCHIO A. *The DALI logic programming agent-oriented language.* In: Logics in Artificial Intelligence, Springer Berlin Heidelberg, 2004, pp. 685–688.

- COSTANTINI S., TOCCHIO A. *DALI: An Architecture for Intelligent Logical Agents.* In: AAAI Spring Symposium: Emotion, Personality, and Social Behavior, 2008, pp. 13–18.

- BEVAR V., COSTANTINI S., TOCCHIO A., DE GASPERIS G. *A multi-agent system for industrial fault detection and repair.* In: Advances on Practical Applications of Agents and Multi-Agent Systems, Springer Berlin Heidelberg, 2012, pp. 47–55.

- DE GASPERIS G., BEVAR V., COSTANTINI S., TOCCHIO A., PAOLUCCI A. *Demonstrator of a multi-agent system for industrial fault detection and repair.* In: Advances on Practical Applications of Agents and Multi-Agent Systems, Springer Berlin Heidelberg, 2012, pp. 237–240.

- DE GASPERIS, Giovanni. *DETF 1st Release (Version 14.08a).* Zenodo, 2014. DOI: 10.5281/zenodo.10683 (August 6, 2014).

- COSTANTINI, Stefania; DE GASPERIS, Giovanni; NAZZICONE, Giulio. *DALI for cognitive robotics: principles and prototype implementation.* In: International Symposium on Practical Aspects of Declarative Languages, Springer, Cham, 2017, pp. 152–162.

- COSTANTINI, Stefania; DE GASPERIS, Giovanni; PITONI, Valentina; SALUTARI, Agnese. *DALI: A multi agent system framework for the web, cognitive robotic and complex event processing.* CILC 2017, 32nd Italian Conference on Computational Logic, 26–28 September 2017, Naples, Italy.

- RAFANELLI, Andrea; COSTANTINI, Stefania; DE GASPERIS, Giovanni. *A Multi-Agent-System framework for flooding events.* WOA 2022, 23rd Workshop From Objects to Agents, 1–2 September 2022, Genova, Italy.

- COSTANTINI, Stefania. *Ensuring trustworthy and ethical behaviour in intelligent logical agents.* Journal of Logic and Computation, 2022, 32(2): 443–478.