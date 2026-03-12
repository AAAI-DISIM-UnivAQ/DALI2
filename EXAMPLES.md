# DALI2 Examples Guide

This guide explains all included examples, how to run them, and the commands to test each feature.

## Table of Contents

- [Running Examples](#running-examples)
- [1. Smart Agriculture (`agriculture.pl`)](#1-smart-agriculture)
- [2. Emergency Response (`emergency.pl`)](#2-emergency-response)
- [3. Feature Showcase (`showcase.pl`)](#3-feature-showcase)
- [4. Distributed Emergency (`emergency_sensors.pl` + `emergency_responders.pl`)](#4-distributed-emergency)
- [API Quick Reference](#api-quick-reference)

---

## Running Examples

### With Docker

```bash
# Single instance
AGENT_FILE=examples/agriculture.pl docker compose up --build

# Distributed (two nodes)
docker compose -f docker-compose.distributed.yml up --build
```

### With SWI-Prolog (local)

```bash
swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl
```

### With run.bat (Windows)

```
run.bat
```

After starting, open **http://localhost:8080** for the web UI.

### Sending Events

All examples use the REST API to inject events. Use `curl` (Linux/Mac) or `Invoke-RestMethod` (PowerShell):

```bash
# curl (Linux/Mac)
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"agent_name","content":"event(args)"}'

# PowerShell (Windows)
Invoke-RestMethod -Uri "http://localhost:8080/api/send" `
  -Method Post -ContentType "application/json" `
  -Body '{"to":"agent_name","content":"event(args)"}'
```

---

## 1. Smart Agriculture

**File:** `examples/agriculture.pl` — Ported from the original DALI case study (`dalia/case_study_smart_agriculture`).

A precision agriculture system with 6 agents. Sensors validate readings via **internal events** (only abnormal readings are forwarded), the crop advisor decides actions (irrigate, reduce water, advisory), and the farmer receives notifications.

### Agents

| Agent | Role |
|-------|------|
| `soil_sensor` | Receives soil readings, validates via internal events (alert vs normal) |
| `weather_monitor` | Receives weather data, validates via internal events (risk vs normal) |
| `crop_advisor` | Analyzes reports with AI, decides: irrigate / reduce_water / advisory |
| `irrigation_controller` | Activates irrigation or reduces water supply |
| `farmer_agent` | Receives advisories and status updates |
| `logger` | Logs all events centrally |

### Features Demonstrated

- **Internal events** — sensors validate readings (soil_alert_check, soil_normal_check, weather_risk_check, weather_normal_check)
- **Reactive rules** (`on`) — all agents react to incoming events
- **Belief management** — irrigation controller tracks active/reduced state per field
- **Multi-agent communication** — message chains across 4+ agents
- **AI Oracle** — crop_advisor uses AI for soil/weather analysis (if API key configured)
- **Conditional logic** — crop_advisor branches on moisture/pH/temperature thresholds

### Test Commands

```bash
# Start
swipl -l src/server.pl -g main -- 8080 examples/agriculture.pl
```

```bash
# 1. Low moisture (25 < 30) → soil alert → irrigate
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"soil_sensor","event":"read_soil(25, 6.5, north_field)"}'
```

**Expected flow:**
```
soil_sensor: stores soil_state → internal soil_alert_check fires (25 < 30)
soil_sensor → crop_advisor: soil_report(25, 6.5, north_field)
crop_advisor: low moisture → irrigate
crop_advisor → irrigation_controller: irrigate(north_field)
crop_advisor → farmer_agent: advisory(irrigate, north_field)
irrigation_controller → farmer_agent: status(irrigating, north_field)
```

```bash
# 2. High moisture (85 > 80) → reduce water
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"soil_sensor","event":"read_soil(85, 6.5, south_field)"}'
```

**Expected:** soil alert → crop_advisor sends `reduce_water(south_field)` to irrigation controller.

```bash
# 3. Normal soil (50, 6.8) → no action
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"soil_sensor","event":"read_soil(50, 6.8, east_field)"}'
```

**Expected:** internal soil_normal_check fires — "SOIL NORMAL" logged, no report sent.

```bash
# 4. Drought risk (temp > 38) → emergency irrigation
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"weather_monitor","event":"weather_update(40, 15, sunny)"}'
```

**Expected:** weather risk → crop_advisor sends `irrigate(all_fields)` + `advisory(drought_risk)`.

```bash
# 5. Frost warning (temp < 2)
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"weather_monitor","event":"weather_update(0, 60, clear)"}'
```

**Expected:** weather risk → `advisory(frost_warning, all_fields)` to farmer.

```bash
# 6. Check state
curl http://localhost:8080/api/beliefs?agent=irrigation_controller
curl http://localhost:8080/api/beliefs?agent=farmer_agent
```

---

## 2. Emergency Response

**File:** `examples/emergency.pl` — Ported from the original DALI emergency example (`dalia/example`).

A 9-agent emergency response system. The sensor validates alarms via **internal events** (real vs false alarm). The coordinator uses **multi-step coordination** with internal events: it waits for equipment from the manager before dispatching the responder. The communicator notifies person agents (mary, john).

### Agents

| Agent | Role |
|-------|------|
| `sensor` | Detects events, validates alarms via internal events (real vs false) |
| `coordinator` | Multi-step dispatch: AI analysis, waits for equipment, tracks done |
| `manager` | Determines equipment (firetruck/bulldozer/respirator) based on type |
| `evacuator` | Handles evacuation, reports back |
| `responder` | Responds with equipment, reports back |
| `communicator` | Notifies civilians (mary, john) |
| `mary`, `john` | Person agents — receive evacuation messages |
| `logger` | Logs all events |

### Features Demonstrated

- **Internal events** — sensor: alarm validation (check_alarm, check_false_alarm); coordinator: dispatch_response (waits for equipment + location), check_done (waits for evacuated + responded)
- **Reactive rules** — full chain from detection to resolution
- **Belief management** — coordinator tracks pending_location, equipment_ready, evacuated, responded
- **Multi-step coordination** — responder is only dispatched after manager provides equipment
- **AI Oracle** — coordinator analyzes emergency (if API key configured)

### Test Commands

```bash
# Start
swipl -l src/server.pl -g main -- 8080 examples/emergency.pl
```

```bash
# 1. Fire emergency — full multi-step flow
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"sensor","event":"sense(fire, building_a)"}'
```

**Expected flow:**
```
sensor: stores detected(fire, building_a) → internal check_alarm fires (fire ∈ alarm list)
sensor → coordinator: alarm(fire, building_a)
coordinator → evacuator + communicator + manager (dispatches all three)
manager: fire → firetruck → coordinator: equipped(firetruck)
communicator → mary + john: message(fire, building_a)
evacuator → coordinator: evacuated(building_a)
coordinator internal dispatch_response: location + equipment ready → responder: respond(firetruck, building_a)
responder → coordinator: responded(building_a)
coordinator internal check_done: evacuated + responded → "EMERGENCY RESOLVED"
```

```bash
# 2. False alarm — wind is not in [smoke, fire, earthquake]
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"sensor","event":"sense(wind, park)"}'
```

**Expected:** internal check_false_alarm fires — "FALSE ALARM: wind at park". No alarm sent to coordinator.

```bash
# 3. Earthquake (different equipment)
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"sensor","event":"sense(earthquake, downtown)"}'
```

**Expected:** manager selects bulldozer, same multi-step flow as fire.

```bash
# 4. Check state
curl http://localhost:8080/api/beliefs?agent=coordinator
curl http://localhost:8080/api/past?agent=coordinator
```

---

## 3. Feature Showcase

**File:** `examples/showcase.pl`

Demonstrates **all 32 DALI2 features** in a single file. This is the comprehensive reference example that covers every rule type, DSL predicate, and advanced feature ported from DALI.

### Agents

| Agent | Role | Features Demonstrated |
|-------|------|----------------------|
| `thermostat` | Temperature control | Internal events (interval, change, trigger, between), constraints, on_change |
| `sensor` | Sensor readings | Periodic tasks, present events, learning, blackboard, past lifetime/remember |
| `coordinator` | Central coordination | Tell/told (priority queue), FIPA messages, multi-events, goals, residue goals, export past rules, proposal sending, AI oracle |
| `logger` | Semantic logging | Ontology (inline + external file), helpers, condition monitor |
| `worker` | Task execution | Action proposals (on_proposal), FIPA responses, export past rules, told rules |

### Features Tested

| # | Feature | Agent | How to Trigger |
|---|---------|-------|----------------|
| 1 | **Reactive rules** (`on`) | all | Send events to agents |
| 2 | **Internal event interval** | thermostat | Automatic — `temp_check` fires every 5s (not every cycle) |
| 3 | **Internal event change** | thermostat | Send `update_temp` — `startup_diagnostic` counter resets |
| 4 | **Internal event trigger** | thermostat | `cooling_monitor` fires only when `mode(cooling)` |
| 5 | **Internal event between** | thermostat | `work_hours_check` fires in time window |
| 6 | **Periodic tasks** | sensor | Automatic — heartbeat every 15 seconds |
| 7 | **Condition monitors** (`when`) | logger | Warns when log volume > 10 |
| 8 | **Condition-action** (`on_change`) | thermostat | Edge-triggered when cooling mode activates |
| 9 | **Present events** | sensor | Blackboard data triggers environment observation |
| 10 | **Multi-events** (`on_all`) | coordinator | Both `sensor_data` + `alert` → fires |
| 11 | **Constraints** | thermostat | Temperature > 50 triggers violation |
| 12 | **Goals (achieve)** | sensor | Calibration goal keeps trying until achieved |
| 13 | **Goals (test)** | coordinator | Tests if alerts received |
| 14 | **Tell/told filtering** | coordinator | Only accepts specific patterns; rejects others |
| 15 | **Priority queue** | coordinator | Messages sorted by told priority (200→10) |
| 16 | **FIPA confirm** | coordinator→worker | Inject `send_confirm(system_ok)` into coordinator |
| 17 | **FIPA query_ref** | coordinator→worker | Inject `query_worker(status(_))` — auto-response |
| 18 | **FIPA propose/accept** | coordinator→worker | Inject `request_analysis(data)` |
| 19 | **FIPA propose/reject** | coordinator→worker | Inject `test_reject` |
| 20 | **FIPA inform** | worker→coordinator | Worker sends analysis results |
| 21 | **Action proposals** (`on_proposal`) | worker | Accepts/rejects proposals from coordinator |
| 22 | **Past lifetime + remember** | sensor | `sensor_data` expires after 30s, remembered 5min |
| 23 | **Export past** (`on_past`) | coordinator | Alert + sensor_data consumed together |
| 24 | **Export past** (`on_past_not_done`) | coordinator | Fires if backup NOT done |
| 25 | **Residue goals** | coordinator | Inject `start_residue_test` then `residue_resolved` |
| 26 | **External ontology file** | logger | Loads `test_ontology.pl` on startup |
| 27 | **Inline ontology** | logger | `log_event` matches `log_entry` via `same_as` |
| 28 | **Learning** | sensor | `read_temp(85)` → learns overheating pattern |
| 29 | **Actions** (`do`) | worker | `analyze(Data)` action definition |
| 30 | **Helpers** | logger | `count_logs` helper |
| 31 | **Blackboard** | sensor | Writes environment data |
| 32 | **AI Oracle** | coordinator | Emergency analysis (if API key configured) |

### Test Commands — Step by Step

```bash
# Start the showcase
swipl -l src/server.pl -g main -- 8080 examples/showcase.pl
```

**Automatic behavior on startup:**
- thermostat: `temp_check` fires every 5s (interval), `startup_diagnostic` fires 3 times (change resets on temp change), `work_hours_check` fires (between), `cooling_monitor` does NOT fire (mode=idle)
- sensor: periodic heartbeat, achieve goal sends calibration requests
- coordinator: calibrates sensor, test goal checks for alerts
- logger: loads `test_ontology.pl` (external ontology)
- After ~4 seconds: sensor calibration achieved

```bash
# STEP 1: Send first temperature reading
# Triggers: learning, blackboard, present event, on_change, triggered internal,
#           constraint, export past (on_past), change condition reset, priority queue
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"read_temp(85)"}'
```

**Expected:**
- Sensor reads 85, writes to blackboard, sends `sensor_data(85)` to coordinator
- **Learning**: learns overheating pattern
- **Present event**: blackboard → thermostat gets `update_temp(85)`
- **On_change**: "Cooling mode just activated" (edge-triggered, fires once)
- **Triggered internal**: `cooling_monitor` starts firing (mode=cooling)
- **Constraint violated**: 85 > 50 → emergency sent to coordinator
- **Change condition**: thermostat's `startup_diagnostic` counter resets (current_temp changed)
- **Priority queue**: coordinator processes `emergency(200)` before `sensor_data(30)`
- Logger receives log_event → **ontology** matching works

```bash
# STEP 2: Send second reading (triggers learned pattern + multi-event + export past)
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"read_temp(90)"}'
```

**Expected:**
- **Learned knowledge**: "WARNING: Previously learned overheating pattern!"
- **Multi-event**: `sensor_data` + `alert` both in past → fires
- **Export past (on_past)**: `alert` + `sensor_data` consumed from past memory

```bash
# STEP 3: Test FIPA confirm — coordinator sends confirm to worker
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"send_confirm(system_ok)"}'
```

**Expected:** Worker receives `confirm(system_ok)` → "Fact confirmed: system_ok" + "FIPA CONFIRM received"

```bash
# STEP 4: Test FIPA query_ref — coordinator queries worker's beliefs
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"query_worker(status(_))"}'
```

**Expected:** Worker auto-responds with `inform(query_ref(status(_)), values([status(ready)]))` → coordinator logs "FIPA QUERY_REF response"

```bash
# STEP 5: Test FIPA proposals — coordinator proposes to worker
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"request_analysis(sample_data)}"'
```

**Expected:** Worker accepts → executes `analyze(sample_data)` → sends `inform(analysis_result, complete)` back → coordinator logs "FIPA PROPOSAL ACCEPTED"

```bash
# STEP 6: Test rejected proposal
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"test_reject"}'
```

**Expected:** Worker rejects `impossible_task` → coordinator logs "FIPA PROPOSAL REJECTED"

```bash
# STEP 7: Test export past not_done
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"critical_data(important_backup)"}'
```

**Expected:** "EXPORT PAST NOT_DONE: backup NOT done! critical_data(important_backup) needs attention!"

```bash
# STEP 8: Test residue goals
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"start_residue_test"}'
# Wait 2 seconds, then inject the resolution:
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"coordinator","event":"residue_resolved"}'
```

**Expected:** "Goal queued as residue: has_past(residue_resolved)" → then "Residue goal achieved" after injection

```bash
# STEP 9: Test tell/told filtering — send an unaccepted message
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"coordinator","content":"unknown_message(test)"}'
```

**Expected:** Message rejected by told rule (coordinator only accepts defined patterns)

```bash
# STEP 10: Lower temperature — constraint resolves, change condition resets diagnostic
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"thermostat","content":"update_temp(20)"}'
```

**Expected:** Temperature drops to 20, constraint no longer violated, mode goes to idle, `startup_diagnostic` counter resets (change detected)

```bash
# STEP 11: Check all state via APIs
curl http://localhost:8080/api/agents
curl http://localhost:8080/api/beliefs?agent=thermostat
curl http://localhost:8080/api/beliefs?agent=coordinator
curl http://localhost:8080/api/beliefs?agent=worker
curl http://localhost:8080/api/past?agent=coordinator
curl http://localhost:8080/api/learned?agent=sensor
curl http://localhost:8080/api/goals?agent=sensor
curl http://localhost:8080/api/blackboard
```

---

## 4. Distributed Emergency

**Files:** `examples/emergency_sensors.pl` + `examples/emergency_responders.pl`

Two separate DALI2 nodes communicating via HTTP federation.

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

**With Docker Compose:**
```bash
docker compose -f docker-compose.distributed.yml up --build
```

**Manually (two terminals):**
```bash
# Terminal 1 — Sensor node on port 8080
swipl -l src/server.pl -g main -- 8080 examples/emergency_sensors.pl

# Terminal 2 — Responder node on port 8081
swipl -l src/server.pl -g main -- 8081 examples/emergency_responders.pl
```

**Register peers:**
```bash
# Tell node 1 about node 2
curl -X POST http://localhost:8080/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"responders","url":"http://localhost:8081"}'

# Tell node 2 about node 1
curl -X POST http://localhost:8081/api/peers/register \
  -H "Content-Type: application/json" \
  -d '{"name":"sensors","url":"http://localhost:8080"}'

# Sync agent lists
curl -X POST http://localhost:8080/api/peers/sync
curl -X POST http://localhost:8081/api/peers/sync
```

**Test:**
```bash
# Send emergency to sensor on node 1
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"detect(fire, building_a)"}'
```

**Expected:** sensor on node 1 sends alarm to coordinator on node 2 via federation. Coordinator dispatches to evacuator, responder, communicator (all on node 2). Logger messages go back to node 1.

---

## API Quick Reference

### Sending Events

```bash
# Send to a specific agent
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"AGENT","content":"EVENT(ARGS)"}'

# Inject directly into an agent's event queue
curl -X POST http://localhost:8080/api/inject \
  -H "Content-Type: application/json" \
  -d '{"agent":"AGENT","event":"EVENT(ARGS)"}'
```

### Querying State

```bash
# List all agents
curl http://localhost:8080/api/agents

# Agent beliefs
curl http://localhost:8080/api/beliefs?agent=AGENT

# Past events
curl http://localhost:8080/api/past?agent=AGENT

# Learned patterns
curl http://localhost:8080/api/learned?agent=AGENT

# Goal statuses
curl http://localhost:8080/api/goals?agent=AGENT

# Blackboard contents
curl http://localhost:8080/api/blackboard

# System logs
curl http://localhost:8080/api/logs?agent=AGENT
```

### Agent Control

```bash
# Start/stop individual agents
curl -X POST http://localhost:8080/api/start -H "Content-Type: application/json" -d '{"agent":"AGENT"}'
curl -X POST http://localhost:8080/api/stop -H "Content-Type: application/json" -d '{"agent":"AGENT"}'

# Reload agent file
curl -X POST http://localhost:8080/api/reload -H "Content-Type: application/json" -d '{"file":"examples/showcase.pl"}'
```
