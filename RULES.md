# DALI2 Language Reference

Complete reference for the DALI2 agent-oriented programming language.

## Table of Contents

- [Agent Declaration](#agent-declaration)
- [Reactive Rules (`on`)](#reactive-rules)
- [Internal Events (`internal`)](#internal-events)
- [Periodic Tasks (`every`)](#periodic-tasks)
- [Condition Monitors (`when`)](#condition-monitors)
- [Condition-Action Rules (`on_change`)](#condition-action-rules)
- [Present/Environment Events (`on_present`)](#presentenvironment-events)
- [Multi-Events (`on_all`)](#multi-events)
- [Constraints (`constraint`)](#constraints)
- [Goals (`goal`)](#goals)
- [Tell/Told Communication Filtering](#telltold-communication-filtering)
- [Ontology Declarations (`ontology`)](#ontology-declarations)
- [Learning Rules (`learn_from`)](#learning-rules)
- [Actions (`do`)](#actions)
- [Beliefs (`believes`)](#beliefs)
- [Helpers (`helper`)](#helpers)
- [DSL Predicates Reference](#dsl-predicates-reference)
- [Agent Lifecycle](#agent-lifecycle)
- [Comparison with DALI 1.0 Syntax](#comparison-with-dali-10-syntax)

---

## Agent Declaration

Every agent must be declared with `:- agent(Name, Options).`

```prolog
:- agent(my_agent, [cycle(1)]).
```

**Options:**

| Option | Description | Default |
|--------|-------------|---------|
| `cycle(N)` | Cycle duration in seconds | `1` |

Agents without options:

```prolog
:- agent(simple_agent).
```

All agents in a single `.pl` file share the same file. Each rule is prefixed with the agent name.

---

## Reactive Rules

React to external events (messages from other agents or injected events).

**Syntax:**

```prolog
agent:on(EventPattern) :- Body.
```

**Examples:**

```prolog
%% React to a simple event
sensor:on(reading(Value)) :-
    log("Sensor reading: ~w", [Value]),
    send(analyzer, data(Value)).

%% React to a message with pattern matching
coordinator:on(alarm(Type, Location)) :-
    log("Alarm: ~w at ~w", [Type, Location]),
    assert_belief(active_alarm(Type, Location)),
    send(responder, respond(Location, Type)).

%% React without a body (just acknowledge)
logger:on(ping).
```

When a message arrives, the engine matches it against all `on` handlers for the receiving agent. If the agent has ontology declarations, matching is ontology-aware (e.g., `on(hot(X))` will also match `warm(X)` if `same_as(hot, warm)` is declared).

---

## Internal Events

Proactive events that fire automatically based on conditions. These are the DALI2 equivalent of DALI's `internal_event/5`.

**Syntax:**

```prolog
agent:internal(Event) :- Body.                     %% forever (default)
agent:internal(Event, Options) :- Body.             %% with conditions
agent:internal(Event, Options).                     %% body = true
```

**Options** (can be a single option or a list):

| Option | Description |
|--------|-------------|
| `forever` | Fire every cycle (default) |
| `times(N)` | Fire at most N times total |
| `until(Condition)` | Fire until Condition becomes true |
| `trigger(Condition)` | Fire only when Condition is true (start condition) |
| `between(time(H1,M1), time(H2,M2))` | Fire only during a time window (hours:minutes) |
| `between(date(Y1,Mo1,D1), date(Y2,Mo2,D2))` | Fire only during a date range |

Options can be combined in a list: `[times(10), between(time(9,0), time(17,0))]`.

The `trigger(Condition)` option is particularly important: it acts as a **start condition** (or guard) that must be satisfied before the internal event fires. The condition is evaluated each cycle using the same condition evaluation as `when` rules (supports `believes(...)`, `has_past(...)`, `learned(...)`, `bb_read(...)`, arithmetic comparisons, etc.). This mirrors DALI's internal events which also had start conditions.

**Examples:**

```prolog
%% Fire forever (every cycle)
monitor:internal(heartbeat) :-
    log("Agent is alive").

%% Fire at most 3 times
greeter:internal(say_hello, times(3)) :-
    log("Hello!").

%% Fire until a condition is met
searcher:internal(search_step, until(believes(found(target)))) :-
    log("Still searching..."),
    do(search_next).

%% Fire only between 14:00 and 17:00
worker:internal(afternoon_check, between(time(14,0), time(17,0))) :-
    log("Afternoon check"),
    send(supervisor, status_report).

%% Combined: at most 5 times, only during work hours
reporter:internal(report, [times(5), between(time(9,0), time(18,0))]) :-
    send(manager, daily_report).

%% Fire only during a specific date range
event_agent:internal(countdown, between(date(2026,3,1), date(2026,3,15))) :-
    log("Event period active!").

%% Fire only when a condition holds (trigger/start condition)
thermostat:internal(cooling_monitor, [forever, trigger(believes(mode(cooling)))]) :-
    believes(current_temp(T)),
    log("Monitoring cooling, temp: ~w", [T]).

%% Combined: triggered + limited repetitions
robot:internal(charge_check, [times(10), trigger(believes(battery_low))]) :-
    log("Battery low! Checking charge level..."),
    do(check_battery).
```

Each internal event is tracked: the engine counts how many times it has fired and records each firing in past memory as `internal(Event)`.

---

## Periodic Tasks

Run a task at fixed time intervals.

**Syntax:**

```prolog
agent:every(Seconds, Goal).
agent:every(Seconds) :- Body.
```

**Examples:**

```prolog
%% Simple periodic log
sensor:every(10, log("Heartbeat")).

%% Periodic with body
monitor:every(30) :-
    log("Checking system health"),
    send(dashboard, health_check).
```

Unlike internal events, periodic tasks don't have conditional options — they simply fire every N seconds.

---

## Condition Monitors

Check a condition every cycle. If true, execute the body. **Level-triggered**: fires every cycle while the condition holds.

**Syntax:**

```prolog
agent:when(Condition) :- Body.
agent:when(Condition1, Condition2) :- Body.     %% both must hold
```

**Examples:**

```prolog
%% Fire every cycle while temperature is high
thermostat:when(believes(temperature(T)), T > 30) :-
    send(ac_controller, cool_down).

%% Check a past event condition
alarm:when(has_past(intrusion_detected)) :-
    send(security, alert).
```

---

## Condition-Action Rules

**Edge-triggered**: fires exactly once when a condition transitions from false to true. Does not fire again until the condition becomes false and then true again.

**Syntax:**

```prolog
agent:on_change(Condition) :- Body.
```

**Examples:**

```prolog
%% Fire once when battery becomes low
robot:on_change(believes(battery_level(L)), L < 20) :-
    log("Battery low! Requesting charge."),
    send(charger, request_charge).

%% Fire once when an event occurs for the first time
monitor:on_change(has_past(system_error)) :-
    send(admin, notify(first_error_detected)).
```

**Difference from `when`:**
- `when` fires **every cycle** while the condition is true (level-triggered)
- `on_change` fires **once** when the condition becomes true (edge-triggered), then waits for it to become false before it can fire again

---

## Present/Environment Events

Monitor the environment (blackboard, external state) every cycle. Similar to `when` but semantically represents observations from the agent's environment rather than internal reasoning.

**Syntax:**

```prolog
agent:on_present(Condition) :- Body.
```

**Examples:**

```prolog
%% React to blackboard data (e.g., sensor publishes to blackboard)
analyzer:on_present(bb_read(sensor_data(temp, T))) :-
    log("Environment temperature: ~w", [T]),
    ( T > 50 -> send(alarm, overheat(T)) ; true ).

%% React to a belief representing an observable state
robot:on_present(believes(obstacle_ahead)) :-
    do(turn_around).
```

---

## Multi-Events

Fire when **all** listed events have occurred in the agent's past memory. The body fires once when all events are present; it resets if any event is removed from the past.

**Syntax:**

```prolog
agent:on_all([Event1, Event2, ...]) :- Body.
```

**Examples:**

```prolog
%% Fire when both initialization steps complete
system:on_all([config_loaded, db_connected]) :-
    log("System fully initialized"),
    send(coordinator, system_ready).

%% Fire when all sensor readings received
analyzer:on_all([soil_data(_, _, _), weather_data(_, _, _)]) :-
    log("All data received, starting analysis"),
    do(full_analysis).
```

The engine checks past events (received, injected, and internal) for matches. Each event in the list must have occurred at least once.

---

## Constraints

Invariant conditions that are checked every cycle. If a constraint is violated (condition is false), the handler body executes.

**Syntax:**

```prolog
agent:constraint(Condition) :- HandlerBody.     %% with handler
agent:constraint(Condition).                     %% log-only (no handler)
```

**Examples:**

```prolog
%% Safety constraint: temperature must stay below 100
reactor:constraint(believes(temperature(T)), T < 100) :-
    log("CRITICAL: Temperature constraint violated!"),
    send(safety_system, emergency_shutdown).

%% Invariant: agent must always have a valid config
server:constraint(believes(config_loaded)).

%% Resource constraint
pool:constraint(believes(connections(N)), N =< 100) :-
    log("Too many connections!"),
    do(reject_new_connections).
```

When a constraint has no handler body, the engine logs a warning when violated but takes no action.

---

## Goals

Goal-directed behavior. Two types:

- **`achieve`**: keep trying the plan every cycle until the goal condition is met
- **`test`**: try the plan once, record whether the goal succeeded or failed

**Syntax:**

```prolog
agent:goal(achieve, GoalCondition) :- Plan.
agent:goal(test, GoalCondition) :- Plan.
```

**Examples:**

```prolog
%% Keep sending calibration requests until calibrated
sensor:goal(achieve, believes(calibrated)) :-
    send(calibrator, calibrate_request).

%% Try once to connect to a database
server:goal(test, believes(db_connected)) :-
    do(connect_database),
    assert_belief(db_connected).
```

**Goal lifecycle:**
- **achieve**: at each cycle, check if `GoalCondition` holds. If yes, mark as `achieved`. If not, execute `Plan`. Once achieved, the goal is done (will not re-execute).
- **test**: execute `Plan` once, then check `GoalCondition`. Record result as `succeeded`, `failed`, or `error`. Will not retry.

Use `reset_goal(GoalCondition)` in rule bodies to allow a goal to be re-attempted.

---

## Tell/Told Communication Filtering

Control which messages an agent can send and receive. Inspired by DALI's FIPA-based communication filtering.

### Told (receive filter)

Defines which message patterns an agent is willing to accept.

```prolog
agent:told(Pattern).                   %% accept messages matching Pattern
agent:told(Pattern, Priority).         %% accept with priority (numeric)
```

If an agent has **any** `told` rules, only messages matching at least one `told` pattern are accepted. Messages not matching are rejected with a log entry. If an agent has **no** `told` rules, all messages are accepted (backward compatible).

### Tell (send filter)

Defines which message patterns an agent is allowed to send.

```prolog
agent:tell(Pattern).                   %% allowed to send Pattern
```

If an agent has **any** `tell` rules, only messages matching at least one `tell` pattern can be sent. Others are blocked. If an agent has **no** `tell` rules, all messages are allowed.

### AI Oracle Filtering

Tell/told rules also apply to **AI Oracle** queries and responses:

- **Tell rules** filter the query context sent to the oracle. If the query doesn't match any `tell` pattern, the oracle call is blocked and returns `blocked(Context)`.
- **Told rules** filter the response received from the oracle. If the response doesn't match any `told` pattern, it is rejected and returns `rejected(RawResponse)`.

This ensures agents can control what information they share with the AI oracle and what advice they accept back.

**Examples:**

```prolog
%% Sensor can only send readings
sensor:tell(reading(_)).
sensor:tell(status(_)).

%% Coordinator accepts alarms and reports
coordinator:told(alarm(_,_), 100).     %% high priority
coordinator:told(report(_,_), 50).     %% lower priority
coordinator:told(status(_)).           %% default priority 0

%% Tell/told for AI Oracle:
%% Agent can query the oracle with analyze(...) terms
advisor:tell(analyze(_)).
%% Agent only accepts suggestion(...) responses from the oracle
advisor:told(suggestion(_), 100).
advisor:told(recommendation(_,_), 50).

%% In a rule body:
advisor:on(critical_event(Data)) :-
    ask_ai(analyze(Data), Response),
    %% Response will be:
    %%   - The actual AI response if both tell and told checks pass
    %%   - blocked(analyze(Data)) if tell rule blocks the query
    %%   - rejected(RawResponse) if told rule rejects the response
    log("AI response: ~w", [Response]).
```

---

## Ontology Declarations

Define semantic equivalences between terms. Ontology declarations make event matching, belief checking, and condition evaluation aware of synonyms and equivalences.

**Syntax:**

```prolog
agent:ontology(same_as(Term1, Term2)).           %% Term1 and Term2 are synonyms
agent:ontology(eq_property(Functor1, Functor2)). %% Functors are equivalent properties
agent:ontology(eq_class(Class1, Class2)).         %% Classes are equivalent
agent:ontology(symmetric(Relation)).              %% Relation(A,B) = Relation(B,A)
```

**Examples:**

```prolog
agent:ontology(same_as(hot, warm)).
agent:ontology(eq_property(temperature, temp)).
agent:ontology(eq_class(vehicle, car)).
agent:ontology(symmetric(near)).
```

**Effects:**
- `believes(warm(room1))` will match a belief `hot(room1)` if `same_as(hot, warm)` is declared
- `on(temp(30))` will match an incoming event `temperature(30)` if `eq_property(temperature, temp)` is declared
- `on(near(a, b))` will match an incoming event `near(b, a)` if `symmetric(near)` is declared
- Use `onto_match(T1, T2)` in rule bodies to explicitly check ontology equivalence

---

## Learning Rules

Agents can learn from experience. Learning rules are triggered when matching events occur. Learned associations are stored and can be queried later.

**Syntax:**

```prolog
agent:learn_from(EventPattern, Outcome) :- Condition.
agent:learn_from(EventPattern, Outcome).              %% unconditional
```

When an event matching `EventPattern` occurs (received, injected, or internal), and `Condition` succeeds, the agent records `learned(Event, Outcome)`.

**Examples:**

```prolog
%% Learn that high readings indicate overheating
sensor:learn_from(reading(T), overheating) :- T > 80.

%% Learn that low readings are normal
sensor:learn_from(reading(T), normal) :- T =< 80.

%% Unconditional learning
logger:learn_from(error(_), incident).
```

**Using learned knowledge in rules:**

```prolog
analyzer:on(new_reading(T)) :-
    ( learned(reading(_), overheating) ->
        log("Previously learned overheating pattern"),
        send(alarm, warning(T))
    ;
        log("No overheating pattern learned yet")
    ).
```

**DSL predicates for learning:**
- `learn(Pattern, Outcome)` — manually record a learned association
- `learned(Pattern, Outcome)` — check if something was learned
- `forget(Pattern)` — remove all learned associations for a pattern

---

## Actions

Named, reusable actions. Actions are recorded in past memory as `did(Action)`.

**Syntax:**

```prolog
agent:do(ActionPattern) :- Body.
```

**Examples:**

```prolog
robot:do(move_forward(Distance)) :-
    log("Moving forward ~w meters", [Distance]),
    assert_belief(position_changed).

robot:do(turn(Degrees)) :-
    log("Turning ~w degrees", [Degrees]).
```

**Calling actions:**

```prolog
robot:on(navigate(X, Y)) :-
    do(move_forward(10)),
    do(turn(90)),
    do(move_forward(5)).
```

---

## Beliefs

Initial beliefs are declared as facts. Beliefs can be added and removed at runtime.

**Syntax:**

```prolog
agent:believes(Fact).
```

**Examples:**

```prolog
robot:believes(battery_level(100)).
robot:believes(position(0, 0)).
server:believes(status(idle)).
```

**Runtime operations:**
- `assert_belief(Fact)` — add a belief
- `retract_belief(Fact)` — remove a belief
- `believes(Fact)` — check if a belief exists (ontology-aware)

---

## Helpers

Utility predicates that can be called from rule bodies.

**Syntax:**

```prolog
agent:helper(Head) :- Body.
```

**Examples:**

```prolog
math_agent:helper(fibonacci(0, 0)).
math_agent:helper(fibonacci(1, 1)).
math_agent:helper(fibonacci(N, F)) :-
    N > 1,
    N1 is N - 1, N2 is N - 2,
    helper(fibonacci(N1, F1)),
    helper(fibonacci(N2, F2)),
    F is F1 + F2.
```

---

## DSL Predicates Reference

These predicates are available inside rule bodies:

### Communication

| Predicate | Description |
|-----------|-------------|
| `send(Agent, Content)` | Send a message to another agent (filtered by tell/told) |
| `broadcast(Content)` | Send to all other agents |

### Logging

| Predicate | Description |
|-----------|-------------|
| `log(Format, Args)` | Log a formatted message (uses `format/2` syntax) |
| `log(Message)` | Log a simple message |

### Beliefs

| Predicate | Description |
|-----------|-------------|
| `assert_belief(Fact)` | Add a belief |
| `retract_belief(Fact)` | Remove a belief |
| `believes(Fact)` | Check if a belief exists (ontology-aware) |

### Past Memory

| Predicate | Description |
|-----------|-------------|
| `has_past(Event)` | Check if event is in past memory |
| `has_past(Event, Time)` | Check past with timestamp |

### Actions & Helpers

| Predicate | Description |
|-----------|-------------|
| `do(Action)` | Execute a named action (recorded in past as `did(Action)`) |
| `helper(Goal)` | Call a helper predicate |

### Learning

| Predicate | Description |
|-----------|-------------|
| `learn(Pattern, Outcome)` | Record a learned association |
| `learned(Pattern, Outcome)` | Check if something was learned |
| `forget(Pattern)` | Remove learned associations |

### Ontology

| Predicate | Description |
|-----------|-------------|
| `onto_match(Term1, Term2)` | Check if terms are equivalent via ontology |

### Goals

| Predicate | Description |
|-----------|-------------|
| `achieve(Goal)` | Manually trigger an achieve goal |
| `reset_goal(Goal)` | Reset a goal for re-attempt |

### Blackboard

| Predicate | Description |
|-----------|-------------|
| `bb_read(Pattern)` | Read from shared blackboard (non-destructive) |
| `bb_write(Tuple)` | Write to shared blackboard |
| `bb_remove(Pattern)` | Remove from shared blackboard |

### AI Oracle

| Predicate | Description |
|-----------|-------------|
| `ask_ai(Context, Result)` | Query ChatGPT, get a Prolog fact back (filtered by tell/told) |
| `ask_ai(Context, Prompt, Result)` | Query with custom system prompt (filtered by tell/told) |
| `ai_available` | Check if AI oracle is configured |

Tell/told rules apply to oracle calls: **tell** filters the query context, **told** filters the response. If blocked, `Result` is `blocked(Context)` or `rejected(RawResponse)`.

### Standard Prolog

All standard Prolog predicates are available: arithmetic (`is`, `>`, `<`, `>=`, `=<`), unification (`=`, `\=`), list operations (`member`, `append`, `length`, `sort`, `reverse`, `flatten`, etc.), type checking (`number`, `atom`, `is_list`, `var`, `nonvar`, `ground`), term manipulation (`functor`, `arg`, `copy_term`), I/O (`write`, `writeln`, `nl`, `format`, `print`), and control (`findall/3`, `sleep/1`, `get_time/1`, `between/3`).

---

## Agent Lifecycle

Each agent runs as a thread with a cycle-based event loop:

```
┌─────────────────────────────────────────┐
│              Agent Cycle                │
├─────────────────────────────────────────┤
│  1. Process incoming messages (on)      │
│  2. Process injected events (on)        │
│  3. Process internal events (internal)  │
│  4. Process periodic tasks (every)      │
│  5. Process condition monitors (when)   │
│  6. Process condition-actions (on_change)│
│  7. Process present events (on_present) │
│  8. Process multi-events (on_all)       │
│  9. Check constraints (constraint)      │
│ 10. Process goals (goal)                │
│ 11. Sleep for cycle duration            │
│     └─── repeat ───┘                    │
└─────────────────────────────────────────┘
```

### Past Memory

Every event is recorded in past memory with a timestamp and source type:
- `received(Content, From)` — external message
- `injected(Event)` — injected via API/UI
- `internal(Event)` — internal event that fired
- `did(Action)` — action that was executed
- `goal_achieved(Goal)` — goal that was achieved

---

## Comparison with DALI 1.0 Syntax

| Feature | DALI 1.0 (SICStus) | DALI2 (SWI-Prolog) |
|---------|---------------------|---------------------|
| External event | `eventE(X) :> body.` | `agent:on(event(X)) :- body.` |
| Internal event | `internal_event(ev, 3, forever, true, until_cond(past(ev)))` | `agent:internal(ev, [forever]) :- body.` |
| Internal with time | `internal_event(ev, 3, forever, true, in_date(D1, D2))` | `agent:internal(ev, [between(time(H1,M1), time(H2,M2))]) :- body.` |
| Condition-action | `cond(X) :< action(X).` | `agent:on_change(cond(X)) :- action(X).` |
| Present event | `en(event)` with suffix N | `agent:on_present(condition) :- body.` |
| Multiple events | `mul([eve, event1, event2])` | `agent:on_all([event1, event2]) :- body.` |
| Constraint | `:~ constraint.` | `agent:constraint(condition) :- handler.` |
| Told rule | `told(_, inform(_), 70) :- true.` | `agent:told(inform(_), 70).` |
| Tell rule | `tell(_, _, send_message(_)) :- true.` | `agent:tell(send_message(_)).` |
| Send message | `messageA(dest, send_message(ev(X), Me))` | `send(dest, ev(X))` |
| Past check | `evp(event)` / `clause(past(event,_,_),_)` | `has_past(event)` |
| Belief check | `clause(isa(fact,_,_),_)` | `believes(fact)` |
| Obtaining goal | `obt_goal(goal)` | `agent:goal(achieve, goal) :- plan.` |
| Test goal | `test_goal(goal)` | `agent:goal(test, goal) :- plan.` |
| Ontology | `meta/3` with OWL, `eq_property`, `same_as` | `agent:ontology(same_as(a, b)).` |
| Learning | `learning.pl` + `learning_constraints.pl` | `agent:learn_from(event, outcome) :- condition.` |
| Action | Suffix A: `actionA(X) :- body.` | `agent:do(action(X)) :- body.` |
