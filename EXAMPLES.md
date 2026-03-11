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

**File:** `examples/agriculture.pl`

A precision agriculture system with 6 agents that monitor soil, weather, and automate irrigation decisions.

### Agents

| Agent | Role |
|-------|------|
| `soil_sensor` | Receives soil readings, forwards to crop_advisor |
| `weather_monitor` | Receives weather data, forwards to crop_advisor |
| `crop_advisor` | Analyzes data, decides irrigation and alerts |
| `irrigation_controller` | Activates irrigation on command |
| `farmer_agent` | Receives notifications and stores them |
| `logger` | Logs all events centrally |

### Features Demonstrated

- **Reactive rules** (`on`) — all agents react to incoming events
- **Belief management** — farmer stores notifications, irrigation tracks active fields
- **Multi-agent communication** — message chains across 4+ agents
- **AI Oracle** — crop_advisor uses AI for critical conditions (if API key configured)
- **Conditional logic** — crop_advisor branches on moisture/pH thresholds

### Test Commands

```bash
# 1. Soil reading with low moisture → triggers irrigation
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"soil_sensor","content":"read_soil(25, 6.5, field_north)"}'
```

**Expected flow:**
```
soil_sensor → crop_advisor: soil_data(25, 6.5, field_north)
crop_advisor detects low moisture (25 < 30)
crop_advisor → irrigation_controller: irrigate(field_north, 25)
crop_advisor → farmer_agent: notify(low_moisture, field_north, 25)
irrigation_controller → farmer_agent: notify(irrigation_started, field_north, 25)
```

```bash
# 2. Abnormal pH reading
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"soil_sensor","content":"read_soil(50, 8.2, field_south)"}'
```

**Expected:** pH alert sent to farmer_agent (8.2 > 7.5).

```bash
# 3. Drought conditions (high temp + low humidity)
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"weather_monitor","content":"weather_update(38, 20, sunny)"}'
```

**Expected:** Drought risk detected → emergency irrigation for all fields.

```bash
# 4. Frost warning
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"weather_monitor","content":"weather_update(1, 80, cloudy)"}'
```

**Expected:** Frost warning sent to farmer_agent (temp < 2).

```bash
# 5. Check agent beliefs
curl http://localhost:8080/api/beliefs?agent=farmer_agent
curl http://localhost:8080/api/beliefs?agent=irrigation_controller
```

---

## 2. Emergency Response

**File:** `examples/emergency.pl`

A multi-agent emergency response system with detection, coordination, evacuation, and communication.

### Agents

| Agent | Role |
|-------|------|
| `sensor` | Detects emergencies, reports to coordinator |
| `coordinator` | Dispatches responders, tracks reports |
| `evacuator` | Handles evacuation procedures |
| `responder` | First response on-site |
| `communicator` | Notifies civilians |
| `logger` | Logs all events |

### Features Demonstrated

- **Reactive rules** — full chain from detection to response
- **Belief management** — coordinator tracks active emergencies and reports
- **Broadcast coordination** — coordinator dispatches to multiple agents simultaneously

### Test Commands

```bash
# 1. Fire emergency
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"sense(fire, building_a)"}'
```

**Expected flow:**
```
sensor → coordinator: alarm(fire, building_a)
coordinator → evacuator: evacuate(building_a, fire)
coordinator → communicator: notify_civilians(building_a, fire)
coordinator → responder: respond(building_a, fire)
evacuator → coordinator: report(evacuator, evacuation_complete, building_a)
responder → coordinator: report(responder, response_active, building_a)
```

```bash
# 2. Earthquake emergency
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"sense(earthquake, downtown)"}'

# 3. Chemical spill
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"sense(chemical_spill, factory_zone)"}'

# 4. Check coordinator beliefs (active emergencies + reports)
curl http://localhost:8080/api/beliefs?agent=coordinator

# 5. Check past events
curl http://localhost:8080/api/past?agent=coordinator
```

---

## 3. Feature Showcase

**File:** `examples/showcase.pl`

Demonstrates **all DALI2 rule types** and DSL predicates. This is the comprehensive reference example.

### Agents

| Agent | Role | Features Demonstrated |
|-------|------|----------------------|
| `thermostat` | Temperature control | Internal events (incl. triggered), constraints, on_change, beliefs |
| `sensor` | Sensor readings | Periodic tasks, present events, learning, goals, blackboard |
| `coordinator` | Central coordination | Reactive rules, tell/told filtering (incl. AI oracle), multi-events, goals |
| `logger` | Semantic logging | Ontology-aware matching, helpers |

### Features Tested

| # | Feature | Agent | How to Trigger |
|---|---------|-------|----------------|
| 1 | **Internal events** | thermostat | Automatic — `temp_check` fires every cycle, `startup_diagnostic` fires 3 times, `cooling_monitor` fires only when mode=cooling |
| 2 | **Periodic tasks** | sensor | Automatic — heartbeat every 15 seconds |
| 3 | **Goals (achieve)** | sensor | Automatic — calibration goal keeps trying until achieved |
| 4 | **Goals (test)** | coordinator | Automatic — tests if alerts received (fires once) |
| 5 | **Reactive rules** | all | Send events to agents (see commands below) |
| 6 | **Learning** | sensor | Send `read_temp(85)` — learns overheating pattern |
| 7 | **Learned knowledge** | sensor | Send `read_temp(90)` after first — detects repeated pattern |
| 8 | **Constraints** | thermostat | Temperature > 50 triggers constraint violation |
| 9 | **On_change** | thermostat | First time mode becomes `cooling` triggers edge event |
| 10 | **Present events** | sensor | Blackboard data triggers environment observation |
| 11 | **Multi-events** | coordinator | Both `sensor_data` AND `alert` in past triggers on_all |
| 12 | **Tell/told filtering** | coordinator | Only accepts specific message patterns |
| 13 | **Tell/told for AI oracle** | coordinator | Oracle queries filtered by tell, responses by told |
| 14 | **Triggered internal** | thermostat | `cooling_monitor` fires only when `believes(mode(cooling))` |
| 15 | **Ontology** | logger | `log_event` matches `log_entry` via `same_as` |
| 16 | **Helpers** | logger | `count_logs` helper tracks log entries |
| 17 | **Blackboard** | sensor | Writes environment data to shared blackboard |

### Test Commands — Step by Step

```bash
# Start the showcase
swipl -l src/server.pl -g main -- 8080 examples/showcase.pl
```

**Automatic behavior on startup:**
- thermostat: internal events fire (`temp_check` every cycle, `startup_diagnostic` 3 times). The `cooling_monitor` does **not** fire yet (mode is `idle`)
- sensor: periodic heartbeat, achieve goal sends calibration requests
- coordinator: calibrates sensor, test goal checks for alerts
- After ~4 seconds: sensor calibration achieved

```bash
# STEP 1: Send first temperature reading (triggers learning)
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"read_temp(85)"}'
```

**Expected:**
- Sensor reads 85, writes to blackboard, sends `sensor_data(85)` to coordinator
- **Learning**: `Learned from read_temp(85): overheating`
- **Present event**: blackboard data detected, sends `update_temp(85)` to thermostat
- Thermostat updates temp to 85, activates cooling mode
- **On_change**: "Cooling mode just activated" (fires once)
- **Triggered internal**: `cooling_monitor` now fires: "TRIGGERED INTERNAL: Monitoring cooling, current temp: 85" (was inactive while mode=idle)
- **Constraint violated**: 85 > 50 → "Temperature 85 exceeds safe limit!"
- Thermostat sends `emergency(overheating, 85)` to coordinator
- **Tell/told for AI oracle**: coordinator's emergency handler calls `ask_ai` if AI is configured (tell rule `analyze(_)` allows the query; told rules filter the response)
- Logger receives `log_event` → ontology-aware matching works

```bash
# STEP 2: Send second temperature reading (triggers learned pattern + multi-event)
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"sensor","content":"read_temp(90)"}'
```

**Expected:**
- Sensor detects previously learned overheating pattern: "WARNING: Previously learned overheating pattern!"
- Sensor sends `alert(repeated_overheating, 90)` to coordinator
- Coordinator receives both `sensor_data` and `alert`
- **Multi-event fires**: "All events occurred" → "MULTI-EVENT: Both sensor data and alert received!"
- Coordinator tracks alert count in beliefs

```bash
# STEP 3: Check all state via APIs
curl http://localhost:8080/api/learned?agent=sensor
curl http://localhost:8080/api/goals?agent=sensor
curl http://localhost:8080/api/goals?agent=coordinator
curl http://localhost:8080/api/beliefs?agent=thermostat
curl http://localhost:8080/api/beliefs?agent=coordinator
curl http://localhost:8080/api/blackboard
curl http://localhost:8080/api/past?agent=coordinator
```

```bash
# STEP 4: Test tell/told filtering — send an unaccepted message to coordinator
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"coordinator","content":"unknown_message(test)"}'
```

**Expected:** "Message rejected by told rule: unknown_message(test)"

```bash
# STEP 5: Lower temperature to see constraint resolve
curl -X POST http://localhost:8080/api/send \
  -H "Content-Type: application/json" \
  -d '{"to":"thermostat","content":"update_temp(20)"}'
```

**Expected:** Temperature drops to 20, constraint no longer violated, mode goes to idle.

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
