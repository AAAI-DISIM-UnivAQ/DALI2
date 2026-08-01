# DALI2 Examples Guide

This guide explains all included examples, how to run them, and the commands to test each feature.

DALI2 supports **DALI-compatible syntax** — the same operators (`:>`, `:<`, `~/`, `</`, `?/`) and suffixes (`E`, `I`, `A`, `N`, `P`) as the original DALI framework, plus the `?>` operator for DALI2's edge-triggered condition-action rules. Agents communicate using FIPA-style messages: `messageA(Dest, performative(Content, Me))` for FIPA performatives (inform, confirm, propose, etc.) and `messageA(Dest, send_message(Content, Me))` for plain messages. See [RULES.md → FIPA Message Types](RULES.md#fipa-message-types) for the full table. Each agent runs as a **separate OS process**.

## Table of Contents

- [Running Examples](#running-examples)
- [1. Smart Agriculture (`agriculture.pl`)](#1-smart-agriculture)
- [2. Emergency Response (`emergency.pl`)](#2-emergency-response)
- [3. Original DALI Features Showcase (`showcase_original_features.pl`)](#3-original-dali-features-showcase)
- [4. New Features Showcase (`showcase_new_features.pl`)](#4-new-features-showcase)
- [5. Distributed Emergency (`emergency_sensors.pl` + `emergency_responders.pl`)](#5-distributed-emergency)
- [API Quick Reference](#api-quick-reference)

---

## Running Examples

### With Docker

Docker Compose starts Redis automatically — no separate install needed.

**Linux / macOS:**
```bash
# Default (agriculture example)
docker compose up --build

# Choose agent file
AGENT_FILE=examples/emergency.pl docker compose up --build

# Distributed (two nodes)
docker compose -f docker-compose.distributed.yml up --build
```

**PowerShell (Windows):**
```powershell
# Default (agriculture example)
docker compose up --build

# Choose agent file
$env:AGENT_FILE="examples/emergency.pl"; docker compose up --build

# Distributed (two nodes)
docker compose -f docker-compose.distributed.yml up --build
```

### Without Docker (SWI-Prolog + Redis)

**Redis must be running** before starting DALI2 (see [Prerequisites](README.md#prerequisites) in README).

```bash
# Step 1: Start Redis (if not already running)
redis-server                # local install
# or
docker run -d --name dali2-redis -p 6379:6379 redis:7-alpine   # via Docker

# Step 2: Start DALI2
swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl
```

### With run.bat (Windows)

```
run.bat
```

After starting, open **http://localhost:8080** for the web UI.

### Sending Events

You can send events to agents via the **Web UI** or the **REST API**.

#### Option A: Web UI (recommended for interactive testing)

1. Open **http://localhost:8080** in your browser
2. In the **Send Event** panel (top-right area):
   - **To**: select the target agent from the dropdown (e.g. `sensor`)
   - **Content**: type the event term (e.g. `read_temp(85)`)
   - Click **Send**
3. Watch the **Event Log** panel (center) for real-time results
4. Click any agent name in the **Agents** panel (left) to inspect its beliefs, past events, and goals

> **Tip:** The "Send Event" panel uses the `/api/send` endpoint. For direct injection (bypasses normal message routing), use the REST API with `/api/inject`.

#### Option B: REST API (curl)

**PowerShell (Windows):**

```powershell
# Send to a specific agent
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""agent_name"",""content"":""event(args)""}"

# Inject directly into an agent's event queue
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""agent_name"",""event"":""event(args)""}"
```

> **Note:** On Windows, use `curl.exe` (not `curl`, which is a PowerShell alias). Use `""` to escape double quotes inside double-quoted strings.

**bash (Linux/Mac):**

```bash
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"agent_name","content":"event(args)"}'
```

---

## 1. Smart Agriculture

**File:** `examples/agriculture.pl` — Ported from the original DALI case study (`dalia/case_study_smart_agriculture`).

A precision agriculture system with 6 agents. Sensors validate readings inline (only abnormal readings are forwarded), the crop advisor decides actions (irrigate, reduce water, advisory), and the farmer receives notifications. All communication uses `messageA(Dest, send_message(Content, Me))` for plain messages and `messageA(Dest, performative(Content, Me))` for FIPA performatives.

### Agents

| Agent | Role |
|-------|------|
| `soil_sensor` | Receives soil readings, validates and forwards abnormal ones |
| `weather_monitor` | Receives weather data, validates and forwards risks |
| `crop_advisor` | Analyzes reports with AI, decides: irrigate / reduce_water / advisory |
| `irrigation_controller` | Activates irrigation or reduces water supply |
| `farmer_agent` | Receives advisories and status updates |
| `logger` | Logs all events centrally |

### Features Demonstrated

- **Reactive rules** (`E` suffix + `:>`) — all agents react to incoming events
- **Inline validation** — sensors check thresholds directly in the event handler body
- **Belief management** — irrigation controller tracks active/reduced state per field
- **Multi-agent communication** — `messageA`/`send_message` chains across 4+ agents
- **AI Oracle** — crop_advisor uses AI for soil/weather analysis (if API key configured)
- **Conditional logic** — crop_advisor branches on moisture/pH/temperature thresholds

### Test Commands

```bash
# Start
swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl
```

#### Via Web UI

Open http://localhost:8080 and use the **Send Event** panel:

| Step | To | Content | Expected |
|------|----|---------|----------|
| 1 | `soil_sensor` | `read_soil(25, 6.5, north_field)` | Low moisture → irrigate north_field |
| 2 | `soil_sensor` | `read_soil(85, 6.5, south_field)` | High moisture → reduce_water south_field |
| 3 | `soil_sensor` | `read_soil(50, 6.8, east_field)` | Normal soil → "SOIL NORMAL", no action |
| 4 | `weather_monitor` | `weather_update(40, 15, sunny)` | Drought risk → irrigate all_fields |
| 5 | `weather_monitor` | `weather_update(0, 60, clear)` | Frost warning → advisory to farmer |

Click any agent in the **Agents** panel to inspect beliefs and past events.

#### Via REST API (curl)

```powershell
# 1. Low moisture (25 < 30) → soil alert → irrigate
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""soil_sensor"",""content"":""read_soil(25, 6.5, north_field)""}"
```

**Expected flow:**
```
soil_sensor: receives read_soil(25, 6.5, north_field) → validates inline (25 < 30)
soil_sensor → crop_advisor: soil_report(25, 6.5, north_field)
crop_advisor: low moisture → irrigate
crop_advisor → irrigation_controller: irrigate(north_field)
crop_advisor → farmer_agent: advisory(irrigate, north_field)
irrigation_controller → farmer_agent: status(irrigating, north_field)
```

```powershell
# 2. High moisture (85 > 80) → reduce water
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""soil_sensor"",""content"":""read_soil(85, 6.5, south_field)""}"
```

**Expected:** soil alert → crop_advisor sends `reduce_water(south_field)` to irrigation controller.

```powershell
# 3. Normal soil (50, 6.8) → no action
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""soil_sensor"",""content"":""read_soil(50, 6.8, east_field)""}"
```

**Expected:** "SOIL NORMAL" logged inline, no report sent.

```powershell
# 4. Drought risk (temp > 38) → emergency irrigation
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""weather_monitor"",""content"":""weather_update(40, 15, sunny)""}"
```

**Expected:** weather risk → crop_advisor sends `irrigate(all_fields)` + `advisory(drought_risk)`.

```powershell
# 5. Frost warning (temp < 2)
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""weather_monitor"",""content"":""weather_update(0, 60, clear)""}"
```

**Expected:** weather risk → `advisory(frost_warning, all_fields)` to farmer.

```powershell
# 6. Check state
curl.exe http://localhost:8080/api/beliefs?agent=irrigation_controller
curl.exe http://localhost:8080/api/beliefs?agent=farmer_agent
```

---

## 2. Emergency Response

**File:** `examples/emergency.pl` — Ported from the original DALI emergency example (`dalia/example`).

A 9-agent emergency response system. The sensor validates alarms inline (real vs false alarm). The coordinator uses **internal events** (default fire-once behavior) for multi-step coordination: it waits for equipment from the manager before dispatching the responder, and waits for evacuation + response completion before declaring the emergency resolved. All communication uses `messageA(Dest, send_message(Content, Me))` for plain messages and `messageA(Dest, performative(Content, Me))` for FIPA performatives.

### Agents

| Agent | Role |
|-------|------|
| `sensor` | Detects events, validates alarms inline (real vs false) |
| `coordinator` | Multi-step dispatch: AI analysis, waits for equipment, tracks done |
| `manager` | Determines equipment (firetruck/bulldozer/respirator) based on type |
| `evacuator` | Handles evacuation, reports back |
| `responder` | Responds with equipment, reports back |
| `communicator` | Notifies civilians (mary, john) |
| `mary`, `john` | Person agents — receive evacuation messages |
| `logger` | Logs all events |

### Features Demonstrated

- **Internal events** (default fire-once) — coordinator: `dispatch_responseI` (waits for equipment + location), `check_doneI` (waits for evacuated + responded)
- **Inline validation** — sensor checks alarm type directly in the event handler body
- **Reactive rules** (`E` suffix + `:>`) — full chain from detection to resolution
- **Belief management** — coordinator tracks pending_location, equipment_ready, evacuated, responded
- **Multi-step coordination** — responder is only dispatched after manager provides equipment
- **AI Oracle** — coordinator analyzes emergency (if API key configured)

### Test Commands

```bash
# Start
swipl -l src/server.pl -g main -- 8080 examples/emergency.pl
```

#### Via Web UI

Open http://localhost:8080 and use the **Send Event** panel:

| Step | To | Content | Expected |
|------|----|---------|----------|
| 1 | `sensor` | `sense(fire, building_a)` | Fire emergency → full multi-step response chain |
| 2 | `sensor` | `sense(wind, park)` | False alarm → "FALSE ALARM: wind at park" |
| 3 | `sensor` | `sense(earthquake, downtown)` | Earthquake → bulldozer selected, same chain |

Click `coordinator` in the **Agents** panel to inspect beliefs (pending_location, equipment_ready, etc.).

#### Via REST API (curl)

```powershell
# 1. Fire emergency — full multi-step flow
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""sense(fire, building_a)""}"
```

**Expected flow:**
```
sensor: receives sense(fire, building_a) → validates inline (fire ∈ alarm list)
sensor → coordinator: alarm(fire, building_a)
coordinator → evacuator + communicator + manager (dispatches all three)
manager: fire → firetruck → coordinator: equipped(firetruck)
communicator → mary + john: message(fire, building_a)
evacuator → coordinator: evacuated(building_a)
coordinator internal dispatch_responseI: location + equipment ready → responder: respond(firetruck, building_a)
responder → coordinator: responded(building_a)
coordinator internal check_doneI: evacuated + responded → "EMERGENCY RESOLVED"
```

```powershell
# 2. False alarm — wind is not in [smoke, fire, earthquake]
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""sense(wind, park)""}"
```

**Expected:** inline validation fails (wind not in alarm list) — "FALSE ALARM: wind at park". No alarm sent to coordinator.

```powershell
# 3. Earthquake (different equipment)
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""sense(earthquake, downtown)""}"
```

**Expected:** manager selects bulldozer, same multi-step flow as fire.

```powershell
# 4. Check state
curl.exe http://localhost:8080/api/beliefs?agent=coordinator
curl.exe http://localhost:8080/api/past?agent=coordinator
```

---

## 3. Original DALI Features Showcase

**File:** `examples/showcase_original_features.pl`

A comprehensive showcase using **only standard DALI syntax** — the same operators (`:>`, `:<`, `~/`, `</`, `?/`, `:~`), suffixes (`E`, `I`, `A`, `N`, `P`), and FIPA-style communication that work in the original DALI framework. FIPA performatives use the direct form `messageA(Dest, performative(Content..., Me))` with DALI-original arity (e.g. `messageA(worker, propose(analyze(Data), [], Me))`, `messageA(worker, query_ref(status(_), _, Me))`). Internal events use the default fire-once behavior (no `internal_event/5` declarations). No DALI2-only extensions (`?>`, `every`, `when`, `helper`, `learn_from`, `ontology`, `on_proposal`, `bb_write`/`bb_read`/`bb_remove`). This is the recommended starting point for students learning DALI semantics.

**DALI retrocompatibility features demonstrated:**
- `cd/1` event precondition (DALI `eve_cond` style) — sensor agent
- `:<` on E-suffix external events — worker agent
- `deltat/1` global simultaneity directive — coordinator agent
- Direct `message/2` form (auto-converted to `send/2`) — coordinator agent
- `messageA/3` with explicit ReplyTo — worker agent

**Additional DALI retrocompatibility (recognized but not exercised in this file):**
- `t<N>.` shorthand (e.g. `t60.`) — DALI tokenizer form of `deltat(N)`
- `:- assert(ev_normal/ev_high(...))` — DALI load-time event injection (ignored with warning)
- `now(Time)` / `datime(D)` — SICStus time built-ins (mapped to SWI-Prolog)
- `request` FIPA performative — now in the supported performatives list

### Agents

| Agent | Role | Features Demonstrated |
|-------|------|----------------------|
| `thermostat` | Temperature control | Internal events (default fire-once), constraints |
| `sensor` | Sensor readings | Past lifetime/remember, goals, event preconditions (`cd/1`) |
| `coordinator` | Central coordination | Tell/told (priority queue + body conditions), FIPA messages, multi-events (`within/1` + `deltat/1`), goals, residue goals, export past rules, DALI message forms (`message/2`) |
| `logger` | Semantic logging | Reactive rules, belief tracking |
| `worker` | Task execution | FIPA proposal handling (`proposeE`), actions (`A` suffix), preconditions (`:<`), event preconditions (`:<` on E-suffix), `messageA/3` with ReplyTo, export past rules, told rules (body conditions) |

### Features Demonstrated

- **Reactive rules** (`E` suffix + `:>`) — all agents
- **Internal events** (`I` suffix + `:>`, default fire-once) — thermostat
- **Constraints** (`:~` operator) — thermostat (temp < 50)
- **Goals** (`obt_goal`/`test_goal`) — sensor (calibration), coordinator (alert test)
- **Tell/told filtering** with priority queue — coordinator, worker
- **FIPA messages** — confirm, inform, query_ref, propose, accept/reject_proposal
- **Multi-events** (`E` suffix conjunction + `within/1`) — coordinator
- **Multi-events with `deltat/1`** (DALI compat) — coordinator
- **Event preconditions** (`cd/1`) — sensor (DALI compat)
- **Event preconditions** (`:<` on E-suffix) — worker (DALI compat)
- **DALI message forms** (`message/2`) — coordinator (DALI compat)
- **`messageA/3` with ReplyTo** — worker (DALI compat)
- **Export past rules** (`~/`, `</`) — coordinator, worker
- **Residue goals** (`tenta_residuo`/`evp`) — coordinator
- **Past lifetime + remember tier** — sensor
- **Actions** (`A` suffix) with preconditions (`:<`) — worker
- **Beliefs** — all agents
- **AI Oracle** — coordinator (if API key configured, graceful fallback)

### Test Commands

```bash
# Start
swipl -l src/server.pl -g main -- 8080 examples/showcase_original_features.pl
```

See [Section 4 (New Features Showcase)](#4-new-features-showcase) for the full step-by-step test procedure — the same commands apply, since both showcases share the same agent structure and event names.

---

## 4. New Features Showcase

**File:** `examples_new_features/showcase_new_features.pl`

The comprehensive reference example covering **all 32 DALI2 features**, including DALI2-only extensions: `internal_event/5` declarations (interval, change, trigger, between), `every`, `when`, `helper`, `on_proposal`, `learn_from`, `ontology`/`ontology_file`, `bb_read`/`bb_write`/`bb_remove`, and `ask_ai`. Communication uses `messageA(Dest, send_message(Content, Me))` for plain messages and `messageA(Dest, performative(Content, Me))` for FIPA performatives.

### Agents

| Agent | Role | Features Demonstrated |
|-------|------|----------------------|
| `thermostat` | Temperature control | Internal events (interval, change, trigger, between), constraints, condition-action (`?>`) |
| `sensor` | Sensor readings | Periodic tasks, learning, blackboard, past lifetime/remember |
| `coordinator` | Central coordination | Tell/told (priority queue + body conditions), FIPA messages, multi-events, goals, residue goals, export past rules, proposal sending, AI oracle |
| `logger` | Semantic logging | Ontology (inline + external file), helpers, condition monitor |
| `worker` | Task execution | Action proposals (on_proposal), FIPA responses, export past rules, told rules (body conditions) |

### Features Tested

| # | Feature | Agent | How to Trigger |
|---|---------|-------|----------------|
| 1 | **Reactive rules** (`E` + `:>`) | all | Send events to agents |
| 2 | **Internal event interval** | thermostat | Automatic — `temp_check` fires every 5s (not every cycle) |
| 3 | **Internal event change** | thermostat | Send `update_temp` — `startup_diagnostic` counter resets |
| 4 | **Internal event trigger** | thermostat | `cooling_monitor` fires only when `mode(cooling)` |
| 5 | **Internal event between** | thermostat | `work_hours_check` fires in time window |
| 6 | **Periodic tasks** (`every`) | sensor | Automatic — heartbeat every 15 seconds |
| 7 | **Condition monitors** (`when`) | logger | Warns when log volume > 10 |
| 8 | **Condition-action** (`?>`) | thermostat | Edge-triggered when cooling mode activates |
| 9 | **Present events** | — | Atomic observations (cannot be defined with `:-`) |
| 10 | **Multi-events with `within/1`** | coordinator | Both `sensor_data` + `alert` within 10s → fires |
| 11 | **Constraints** | thermostat | Temperature > 50 triggers violation |
| 12 | **Goals (achieve)** | sensor | Calibration goal keeps trying until achieved |
| 13 | **Goals (test)** | coordinator | Tests if alerts received |
| 14 | **Tell/told filtering (body conditions)** | coordinator, worker | Accept/reject based on pattern + body conditions |
| 15 | **Priority queue** | coordinator | Messages sorted by told priority (200→10) |
| 16 | **FIPA confirm** | coordinator→worker | Inject `send_confirm(system_ok)` into coordinator |
| 17 | **FIPA query_ref** | coordinator→worker | Inject `query_worker(status(_))` — auto-response |
| 18 | **FIPA propose/accept** | coordinator→worker | Inject `request_analysis(data)` |
| 19 | **FIPA propose/reject** | coordinator→worker | Inject `test_reject` |
| 20 | **FIPA inform** | worker→coordinator | Worker sends analysis results |
| 21 | **Action proposals** (`on_proposal`) | worker | Accepts/rejects proposals from coordinator |
| 22 | **Past lifetime + remember** | sensor | `sensor_data` expires after 30s, remembered 5min |
| 23 | **Export past** (`~/`) | coordinator | Alert + sensor_data consumed together |
| 24 | **Export past NOT done** (`</`) | coordinator | Fires if backup NOT done |
| 25 | **Residue goals** | coordinator | Inject `start_residue_test` then `residue_resolved` |
| 26 | **External ontology file** | logger | Loads `test_ontology.pl` on startup |
| 27 | **Inline ontology** | logger | `log_event` matches `log_entry` via `same_as` |
| 28 | **Learning** | sensor | `read_temp(85)` → learns overheating pattern |
| 29 | **Actions** (`A` suffix) | worker | `analyze(Data)` action definition |
| 30 | **Helpers** | logger | `count_logs` helper |
| 31 | **Blackboard** | sensor | Writes environment data |
| 32 | **AI Oracle** | coordinator | Emergency analysis (if API key configured) |

### Test Commands — Step by Step

```bash
# Start the showcase
swipl -l src/server.pl -g main -- 8080 examples_new_features/showcase_new_features.pl
```

#### Via Web UI

Open http://localhost:8080 and use the **Send Event** panel. Steps 1–2 use "Send" (message routing); steps 3–8 require the REST API with `/api/inject` (direct injection).

| Step | To | Content | Expected |
|------|----|---------|----------|
| 1 | `sensor` | `read_temp(85)` | Learning, blackboard, cooling mode, constraint violation |
| 2 | `sensor` | `read_temp(90)` | Learned pattern warning, multi-event with `within(10)` fires |
| 10 | `thermostat` | `update_temp(20)` | Constraint resolves, mode → idle |

Steps 3–9 inject events directly into the coordinator (FIPA, export past, residue goals). Use curl or the REST API for these — see below.

#### Via REST API (curl)

**Automatic behavior on startup:**
- thermostat: `temp_check` fires every 5s (interval), `startup_diagnostic` fires 3 times (change resets on temp change), `work_hours_check` fires (between), `cooling_monitor` does NOT fire (mode=idle)
- sensor: periodic heartbeat, achieve goal sends calibration requests
- coordinator: calibrates sensor, test goal checks for alerts
- logger: loads `test_ontology.pl` (external ontology)
- After ~4 seconds: sensor calibration achieved

```powershell
# STEP 1: Send first temperature reading
# Triggers: learning, blackboard, condition-action (?>), triggered internal,
#           constraint, export past (~/), change condition reset, priority queue
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""read_temp(85)""}"
```

**Expected:**
- Sensor reads 85, writes to blackboard, sends `sensor_data(85)` to coordinator
- **Learning**: learns overheating pattern
- **Condition-action (?>)**: "Cooling mode just activated" (edge-triggered, fires once)
- **Triggered internal**: `cooling_monitor` starts firing (mode=cooling)
- **Constraint violated**: 85 > 50 → emergency sent to coordinator
- **Change condition**: thermostat's `startup_diagnostic` counter resets (current_temp changed)
- **Priority queue**: coordinator processes `emergency(200)` before `sensor_data(30)`
- Logger receives log_event → **ontology** matching works

```powershell
# STEP 2: Send second reading (triggers learned pattern + multi-event + export past)
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""read_temp(90)""}"
```

**Expected:**
- **Learned knowledge**: "WARNING: Previously learned overheating pattern!"
- **Multi-event (`within(10)`)**: `sensor_data` + `alert` both in past within 10s → fires
- **Export past (`~/`)**: `alert` + `sensor_data` consumed from past memory

```powershell
# STEP 3: Test FIPA confirm — coordinator sends confirm to worker
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""send_confirm(system_ok)""}"
```

**Expected:** Worker receives `confirm(system_ok)` → "Fact confirmed: system_ok" + "FIPA CONFIRM received"

```powershell
# STEP 4: Test FIPA query_ref — coordinator queries worker's beliefs
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""query_worker(status(_))""}"
```

**Expected:** Worker auto-responds with `inform(query_ref(status(_)), values([status(ready)]))` → coordinator logs "FIPA QUERY_REF response"

```powershell
# STEP 5: Test FIPA proposals — coordinator proposes to worker
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""request_analysis(sample_data)""}"
```

**Expected:** Worker accepts → executes `analyze(sample_data)` → sends `inform(analysis_result, complete)` back → coordinator logs "FIPA PROPOSAL ACCEPTED"

```powershell
# STEP 6: Test rejected proposal
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""test_reject""}"
```

**Expected:** Worker rejects `impossible_task` → coordinator logs "FIPA PROPOSAL REJECTED"

```powershell
# STEP 7: Test export past not_done
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""critical_data(important_backup)""}"
```

**Expected:** "EXPORT PAST NOT_DONE: backup NOT done! critical_data(important_backup) needs attention!"

```powershell
# STEP 8: Test residue goals
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""start_residue_test""}"
# Wait 2 seconds, then inject the resolution:
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""coordinator"",""event"":""residue_resolved""}"
```

**Expected:** "Goal queued as residue: has_past(residue_resolved)" → then "Residue goal achieved" after injection

```powershell
# STEP 9: Test tell/told filtering — send an unaccepted message
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""coordinator"",""content"":""unknown_message(test)""}"
```

**Expected:** Message rejected by told rule (coordinator only accepts defined patterns)

```powershell
# STEP 10: Lower temperature — constraint resolves, change condition resets diagnostic
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""thermostat"",""content"":""update_temp(20)""}"
```

**Expected:** Temperature drops to 20, constraint no longer violated, mode goes to idle, `startup_diagnostic` counter resets (change detected)

```powershell
# STEP 11: Check all state via APIs
curl.exe http://localhost:8080/api/agents
curl.exe http://localhost:8080/api/beliefs?agent=thermostat
curl.exe http://localhost:8080/api/beliefs?agent=coordinator
curl.exe http://localhost:8080/api/beliefs?agent=worker
curl.exe http://localhost:8080/api/past?agent=coordinator
curl.exe http://localhost:8080/api/learned?agent=sensor
curl.exe http://localhost:8080/api/goals?agent=sensor
curl.exe http://localhost:8080/api/blackboard
```

---

## 5. Distributed Emergency

**Files:** `examples/emergency_sensors.pl` + `examples/emergency_responders.pl`

Two separate DALI2 nodes communicating via a shared Redis instance (star topology).

### Node 1: Sensors (`emergency_sensors.pl`)

| Agent | Role |
|-------|------|
| `sensor` | Detects emergencies |
| `logger` | Logs events |

### Node 2: Responders (`emergency_responders.pl`)

| Agent | Role |
|-------|------|
| `coordinator` | Dispatches responders |
| `evacuator` | Handles evacuation |
| `responder` | First response |
| `communicator` | Public notification |

### Running Distributed

**With Docker Compose (recommended):**
```bash
docker compose -f docker-compose.distributed.yml up --build
```
This starts a shared Redis, sensors on port 8081, and responders on port 8082.

**Manually (three terminals — Redis + two nodes):**
```bash
# Terminal 1 — Start Redis
docker run -d --name dali2-redis -p 6379:6379 redis:7-alpine

# Terminal 2 — Sensor node on port 8080
swipl -l src/server.pl -g main -- 8080 examples/emergency_sensors.pl --name sensors

# Terminal 3 — Responder node on port 8081
swipl -l src/server.pl -g main -- 8081 examples/emergency_responders.pl --name responders
```

Both nodes connect to `localhost:6379` automatically. No peer registration needed.

**Test via Web UI:**

Open **http://localhost:8081** (sensors node) and use the **Send Event** panel:

| To | Content | Expected |
|----|---------|----------|
| `sensor` | `detect(fire, building_a)` | Alarm crosses to node 2 → full response chain |

Open **http://localhost:8082** (responders node) to see coordinator, evacuator, and responder activity.

**Test via REST API:**
```powershell
# Send emergency to sensor on node 1 (port 8081)
curl.exe -X POST http://localhost:8081/api/send -H "Content-Type: application/json" -d "{""to"":""sensor"",""content"":""detect(fire, building_a)""}"
```

**Expected:** sensor on node 1 sends alarm to coordinator on node 2 via Redis. Coordinator dispatches to evacuator, responder, communicator (all on node 2). Logger messages go back to node 1 via Redis.

---

## API Quick Reference

### Sending Events

```powershell
# Send to a specific agent
curl.exe -X POST http://localhost:8080/api/send -H "Content-Type: application/json" -d "{""to"":""AGENT"",""content"":""EVENT(ARGS)""}"

# Inject directly into an agent's event queue
curl.exe -X POST http://localhost:8080/api/inject -H "Content-Type: application/json" -d "{""agent"":""AGENT"",""event"":""EVENT(ARGS)""}"
```

### Querying State

```powershell
# List all agents
curl.exe http://localhost:8080/api/agents

# Agent beliefs
curl.exe http://localhost:8080/api/beliefs?agent=AGENT

# Past events
curl.exe http://localhost:8080/api/past?agent=AGENT

# Learned patterns
curl.exe http://localhost:8080/api/learned?agent=AGENT

# Goal statuses
curl.exe http://localhost:8080/api/goals?agent=AGENT

# Blackboard contents
curl.exe http://localhost:8080/api/blackboard

# System logs
curl.exe http://localhost:8080/api/logs?agent=AGENT

# Cluster view (all agents across all nodes)
curl.exe http://localhost:8080/api/cluster
```

### Agent Control

```powershell
# Start/stop individual agents
curl.exe -X POST http://localhost:8080/api/start -H "Content-Type: application/json" -d "{""agent"":""AGENT""}"
curl.exe -X POST http://localhost:8080/api/stop -H "Content-Type: application/json" -d "{""agent"":""AGENT""}"

# Reload agent file
curl.exe -X POST http://localhost:8080/api/reload -H "Content-Type: application/json" -d "{""file"":""examples/agriculture.pl""}"
```
