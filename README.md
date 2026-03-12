# DALI2

> Simplified Multi-Agent System Framework built on SWI-Prolog

DALI2 is a complete rewrite of the [DALI](https://github.com/AAAI-DISIM-UnivAQ/DALI) multi-agent system framework, designed for simplicity and ease of use.

## Key Features

- **Single-file agent definitions** — define all agents in one `.pl` file
- **Full DALI feature set** — reactive rules, internal events, goals, constraints, learning, ontologies, tell/told filtering, and more
- **Integrated web UI** — dashboard, log viewer, message sender, agent inspector
- **Docker-ready** — runs in a container, no local installation needed
- **Single-process architecture** — all agents run as threads in one SWI-Prolog instance
- **Simplified syntax** — no tokenizer, no intermediate files, no E/I/A suffixes
- **In-memory blackboard** — no TCP-based Linda server needed

**Documentation:** [RULES.md](RULES.md) (language reference) · [EXAMPLES.md](EXAMPLES.md) (examples guide)

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

### Distributed Mode — Running Agents Across Multiple Devices

DALI2 supports splitting agents from the **same** agent file across multiple nodes.
Each node loads the full file but starts only selected agents via `--agents`.
Nodes discover each other's agents and route messages transparently over HTTP.

Below is a complete walkthrough using the **agriculture** example, splitting 6 agents across 2 nodes.

#### Agent split

| Node | Name | Agents | Role |
|------|------|--------|------|
| Node A | `sensors` | `soil_sensor`, `weather_monitor`, `logger` | Field sensors + logging |
| Node B | `advisors` | `crop_advisor`, `irrigation_controller`, `farmer_agent` | Decision-making |

When `soil_sensor` sends a message to `crop_advisor`, DALI2 automatically forwards it over HTTP to Node B.
When `irrigation_controller` sends to `logger`, it goes back to Node A. No code changes needed.

#### Option 1: Two Docker containers on the same machine

Open **two terminals** and run one container each:

```sh
# Terminal 1 — sensors node (port 8081)
docker run --rm --init -p 8081:8080 \
  -v ./examples:/dali2/examples \
  --name agri-sensors \
  dali2 8080 examples/agriculture.pl --name sensors \
  --agents soil_sensor,weather_monitor,logger

# Terminal 2 — advisors node (port 8082)
docker run --rm --init -p 8082:8080 \
  -v ./examples:/dali2/examples \
  --name agri-advisors \
  dali2 8080 examples/agriculture.pl --name advisors \
  --agents crop_advisor,irrigation_controller,farmer_agent
```

Then connect the peers. Since Docker containers are isolated, create a shared network:

```sh
docker network create dali2-net
docker network connect dali2-net agri-sensors
docker network connect dali2-net agri-advisors
```

Register each node as a peer of the other (use container names as hostnames):

```sh
# Tell sensors node about advisors
curl -X POST http://localhost:8081/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"advisors","url":"http://agri-advisors:8080"}'

# Tell advisors node about sensors
curl -X POST http://localhost:8082/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"sensors","url":"http://agri-sensors:8080"}'
```

> **PowerShell equivalent:**
> ```powershell
> Invoke-RestMethod -Uri "http://localhost:8081/api/peers/register" -Method Post `
>   -ContentType "application/json" `
>   -Body '{"name":"advisors","url":"http://agri-advisors:8080"}'
>
> Invoke-RestMethod -Uri "http://localhost:8082/api/peers/register" -Method Post `
>   -ContentType "application/json" `
>   -Body '{"name":"sensors","url":"http://agri-sensors:8080"}'
> ```

#### Option 2: Two separate machines

On **Machine A** (e.g. `192.168.1.10`):

```sh
docker run --rm --init -p 8080:8080 \
  -v ./examples:/dali2/examples \
  dali2 8080 examples/agriculture.pl --name sensors \
  --agents soil_sensor,weather_monitor,logger
```

On **Machine B** (e.g. `192.168.1.20`):

```sh
docker run --rm --init -p 8080:8080 \
  -v ./examples:/dali2/examples \
  dali2 8080 examples/agriculture.pl --name advisors \
  --agents crop_advisor,irrigation_controller,farmer_agent
```

Connect them using real IP addresses:

```sh
# From Machine A (or any machine)
curl -X POST http://192.168.1.10:8080/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"advisors","url":"http://192.168.1.20:8080"}'

curl -X POST http://192.168.1.20:8080/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"sensors","url":"http://192.168.1.10:8080"}'
```

> You can also connect peers from the **Web UI**: open the Federation panel in the left sidebar,
> enter the peer name and URL, and click **Connect**.

#### Option 3: Without Docker (two shells, SWI-Prolog)

Requires [SWI-Prolog](https://www.swi-prolog.org/) installed locally.

```sh
# Shell 1 — sensors on port 8081
swipl -l src/server.pl -g main -t halt -- 8081 examples/agriculture.pl \
  --name sensors --agents soil_sensor,weather_monitor,logger

# Shell 2 — advisors on port 8082
swipl -l src/server.pl -g main -t halt -- 8082 examples/agriculture.pl \
  --name advisors --agents crop_advisor,irrigation_controller,farmer_agent
```

Connect them (both are on localhost, different ports):

```sh
curl -X POST http://localhost:8081/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"advisors","url":"http://localhost:8082"}'

curl -X POST http://localhost:8082/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"sensors","url":"http://localhost:8081"}'
```

#### Testing the distributed setup

Send a soil reading to the sensor on Node A:

```sh
curl -X POST http://localhost:8081/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"soil_sensor","content":"read_soil(25, 6.5, north_field)"}'
```

Expected chain of events across both nodes:

1. **soil_sensor** (Node A) receives `read_soil`, sends `soil_data` → **crop_advisor** (Node B) via federation
2. **crop_advisor** (Node B) detects low moisture (25 < 30), sends `irrigate` → **irrigation_controller** (Node B, local)
3. **crop_advisor** sends `notify(low_moisture)` → **farmer_agent** (Node B, local)
4. **irrigation_controller** (Node B) activates irrigation, sends `log_event` → **logger** (Node A) via federation
5. **farmer_agent** (Node B) logs the notification
6. **logger** (Node A) receives and logs events from both local and remote agents

Check the logs of each node to verify:

```sh
# Node A logs
docker logs agri-sensors

# Node B logs
docker logs agri-advisors
```

#### Pre-configured distributed example (emergency)

A ready-made two-node example is also included:

```sh
docker compose -f docker-compose.distributed.yml up --build
```

This starts `sensors` on port 8081 and `responders` on port 8082, auto-connected via `DALI2_PEERS` env var.

#### Cleanup

When using **Option 1** (two containers on the same machine), stop and clean up with:

```sh
# Stop both containers (or press CTRL+C in each terminal)
docker stop agri-sensors agri-advisors

# Remove the shared network
docker network rm dali2-net
```

For `docker compose` setups, simply use:

```sh
# Single instance
docker compose down

# Distributed
docker compose -f docker-compose.distributed.yml down
```

> **Tip:** The `--init` flag (used above) and `init: true` in docker-compose files ensure that
> CTRL+C stops containers cleanly. Without it, `swipl` as PID 1 may not handle signals correctly.

### Windows

Run `run.bat` — choose single or distributed mode interactively:

```sh
run.bat
```

## Agent Language

Agents are defined in a single `.pl` file. Here are the key constructs — see **[RULES.md](RULES.md)** for the complete language reference (all 24 rule types and 30+ DSL predicates) and **[EXAMPLES.md](EXAMPLES.md)** for walkthroughs with test commands.

```prolog
:- agent(my_agent, [cycle(1)]).

%% React to events/messages
my_agent:on(alarm(Type, Location)) :-
    log("Alarm: ~w at ~w", [Type, Location]),
    assert_belief(active(Type, Location)),
    send(responder, dispatch(Type, Location)).

%% Internal event — proactive, fires when body conditions are met
my_agent:internal(check_status, [forever, interval(5)]) :-
    believes(active(Type, Location)),
    log("Still active: ~w at ~w", [Type, Location]).

%% Tell/told communication filtering (priority queue)
my_agent:told(alarm(_), 100).    %% Accept alarms (high priority)
my_agent:told(status(_), 50).    %% Accept status (lower priority)
my_agent:tell(report(_)).        %% Only allowed to send reports

%% Initial beliefs
my_agent:believes(status(idle)).
```

Other rule types: `every` (periodic), `when` (monitor), `on_change` (edge-triggered), `on_present` (environment), `on_all` (multi-event), `constraint`, `goal`, `on_proposal`, `on_past`, `learn_from`, `ontology`, and more — all documented in [RULES.md](RULES.md).

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
| GET | `/api/learned?agent=X` | Get learned patterns |
| GET | `/api/goals?agent=X` | Get goal statuses |
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
| Internal events | `internal_event/5` with `forever`/`until_cond`/`in_date` | `agent:internal(event, [options]) :- body.` with `interval`/`trigger`/`change` |
| Tell/told | `told(_,inform(_),70)` in communication.con | `agent:told(pattern, priority).` (priority queue + AI oracle filter) |
| FIPA messages | `confirm`/`disconfirm`/`propose`/`query_ref`/etc. | `send(to, confirm(fact))` — full FIPA-ACL support |
| Action proposal | `propose(A,C,Ag)` + `call_propose` | `agent:on_proposal(action) :- body.` |
| Past lifetime | `past_event(ev, 60)` + `remember_event(ev, 3600)` | `agent:past_lifetime(ev, 60).` + `remember_lifetime`/`remember_limit` |
| Export past (~/) | `head ~/ body` | `agent:on_past([events]) :- body.` |
| Export past (</) | `head </ body` | `agent:on_past_not_done(action, [events]) :- body.` |
| Export past (?/) | `head ?/ body` | `agent:on_past_done(action, [events]) :- body.` |
| Residue goals | `tenta_residuo(goal)` | `achieve(goal)` (auto-queued as residue) |
| Condition-action | `cond :< action.` | `agent:on_change(cond) :- body.` |
| Present events | `en(X)` with suffix N | `agent:on_present(cond) :- body.` |
| Multi-events | `mul/1` | `agent:on_all([e1, e2]) :- body.` |
| Constraints | `:~ constraint.` | `agent:constraint(cond) :- body.` |
| Ontologies | `meta/3` + OWL files | `agent:ontology(same_as(a,b)).` + `agent:ontology_file('f.pl').` |
| Learning | `learning.pl` + constraints | `agent:learn_from(event, outcome) :- body.` |
| Goals | `obt_goal`/`test_goal` | `agent:goal(achieve/test, goal) :- plan.` |

## License

Apache License 2.0
