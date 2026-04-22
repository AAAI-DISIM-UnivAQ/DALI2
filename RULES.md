# DALI2 Language Reference

Complete reference for the DALI2 agent-oriented programming language.
DALI2 uses **DALI-compatible syntax** — the same operators and suffixes as the original DALI framework — while adding new features for modern multi-agent systems.

## Syntax Overview

DALI2 uses **identical syntax** to the original DALI — no prefix needed. Each `:- agent(name).` directive sets the context for all subsequent rules until the next agent declaration.

| Construct | Syntax (identical to DALI) |
|-----------|---------------------------|
| Agent declaration | `:- agent(name, [options]).` |
| External event | `eventE(X) :> body.` |
| Internal event | `eventI(X) :> body.` |
| Internal config | `internal_event(ev, 3, forever, true, stop).` |
| Action definition | `actionA(X) :- body.` |
| Present event | `condN` (atomic, body only) |
| Condition-action | `cond :< action.` |
| Export past | `head ~/ past1, past2.` |
| Export past (not done) | `head </ past1, past2.` |
| Export past (done) | `head ?/ past1, past2.` |
| Constraint | `:~ condition.` |
| Past lifetime | `past_event(ev, 60).` |
| Remember | `remember_event(ev, 3600).` |
| Remember limit | `remember_event_mod(ev, number(5), last).` |
| Obtain goal | `obt_goal(goal) :- plan.` |
| Test goal | `test_goal(goal) :- plan.` |
| Told rule | `told(_, pattern, priority) :- body.` |
| Told rule (no priority) | `told(_, pattern) :- body.` |
| Tell rule | `tell(_, _, pattern) :- body.` |
| Message sending | `messageA(dest, send_message(content, Me))` |
| Past check | `evp(event)` or `eventP(args)` |
| Residue goal | `tenta_residuo(goal)` |
| Belief | `believes(fact).` or bare fact |

**Additional features** (no DALI equivalent):
- `every(Seconds, Goal).` — periodic tasks
- `when(Condition) :- Body.` — condition monitors
- `helper(Head) :- Body.` — utility predicates
- `on_proposal(Action) :- Body.` — action proposal handlers
- `learn_from(Event, Outcome) :- Body.` — learning rules
- `ontology(same_as(a, b)).` — inline ontology
- `ontology_file('file.pl').` — external ontology file
- `ask_ai(Context, Result)` — AI Oracle integration (body predicate)
- `bb_read/bb_write/bb_remove` — Redis blackboard operations (body predicates)

## Table of Contents

- [Agent Declaration](#agent-declaration)
- [Reactive Rules (`:>`)](#reactive-rules)
- [Internal Events (`:>` + `I` suffix)](#internal-events)
- [Periodic Tasks (`every`)](#periodic-tasks)
- [Condition Monitors (`when`)](#condition-monitors)
- [Condition-Action Rules (`:<`)](#condition-action-rules)
- [Present/Environment Events (`N` suffix)](#presentenvironment-events)
- [Multi-Events (conjunction)](#multi-events)
- [Constraints (`:~`)](#constraints)
- [Goals (`obt_goal`/`test_goal`)](#goals)
- [Tell/Told Communication Filtering](#telltold-communication-filtering)
- [FIPA Message Types](#fipa-message-types)
- [Action Proposals (`on_proposal`)](#action-proposals)
- [Past Event Lifetime & Remember](#past-event-lifetime--remember)
- [Export Past Rules (`~/` `</` `?/`)](#export-past-rules)
- [Residue Goals](#residue-goals)
- [Ontology Declarations (`ontology`)](#ontology-declarations)
- [Learning Rules (`learn_from`)](#learning-rules)
- [Actions (`A` suffix)](#actions)
- [Beliefs (`believes`)](#beliefs)
- [Helpers (`helper`)](#helpers)
- [DSL Predicates Reference](#dsl-predicates-reference)
- [Agent Lifecycle](#agent-lifecycle)

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
eventE(Args) :> Body.
```

The `E` suffix marks external events. The `:>` operator separates the head from the body. The suffix is stripped when matching incoming events (e.g., `readingE(V)` matches incoming event `reading(V)`).

**Examples:**

```prolog
:- agent(sensor, [cycle(1)]).

%% React to a simple event
readingE(Value) :>
    log("Sensor reading: ~w", [Value]),
    send(analyzer, data(Value)).

:- agent(coordinator, [cycle(1)]).

%% React with pattern matching
alarmE(Type, Location) :>
    log("Alarm: ~w at ~w", [Type, Location]),
    assert_belief(active_alarm(Type, Location)),
    send(responder, respond(Location, Type)).
```

When a message arrives, the engine matches it against all handlers for the receiving agent. If the agent has ontology declarations, matching is ontology-aware (e.g., `alarmE(hot(X))` will also match `alarm(warm(X))` if `same_as(hot, warm)` is declared).

**Body predicates:** Inside `:>` bodies, you can use both DALI-style predicates (`messageA`, `eventP`, `actionA`, `evp`, `tenta_residuo`) and DALI2-style predicates (`send`, `has_past`, `do`, `achieve`). They are equivalent.

---

## Internal Events

Proactive events that fire automatically based on conditions.

**Syntax:**

```prolog
eventI(Args) :> Body.                                          %% handler
internal_event(Event, Period, Repetition, StartCond, StopCond). %% configuration
```

The `I` suffix marks internal events. The handler (`:>`) defines what to execute, and `internal_event/5` configures timing and conditions.

**Options** (can be a single option or a list):

| Option | Description |
|--------|-------------|
| `forever` | Fire every cycle (default) |
| `times(N)` | Fire at most N times total |
| `until(Condition)` | Fire until Condition becomes true |
| `trigger(Condition)` | Fire only when Condition is true (start condition) |
| `interval(N)` | Fire at most once every N seconds (per-event frequency) |
| `change([FactList])` | Reset `times(N)` counter when any listed fact/past event changes |
| `between(time(H1,M1), time(H2,M2))` | Fire only during a time window (hours:minutes) |
| `between(date(Y1,Mo1,D1), date(Y2,Mo2,D2))` | Fire only during a date range |

Options can be combined in a list: `[times(10), between(time(9,0), time(17,0))]`.

The `trigger(Condition)` option is particularly important: it acts as a **start condition** (or guard) that must be satisfied before the internal event fires. The condition is evaluated each cycle using the same condition evaluation as `when` rules (supports `believes(...)`, `has_past(...)`, `learned(...)`, `bb_read(...)`, arithmetic comparisons, etc.). This mirrors DALI's internal events which also had start conditions.

**Examples (DALI syntax):**

```prolog
:- agent(thermostat, [cycle(2)]).

%% Fire every 5 seconds (interval)
temp_checkI :>
    believes(current_temp(T)),
    log("Temperature check, current=~w", [T]).
internal_event(temp_check, 5, forever, true, forever).

%% Fire with change condition — resets when current_temp changes
startup_diagnosticI :>
    log("Startup diagnostic"),
    assert_belief(diagnostic_done).
internal_event(startup_diagnostic, 0, change([current_temp(_)]), true, forever).

%% Fire only when mode is cooling (trigger/start condition)
cooling_monitorI :>
    believes(current_temp(T)),
    log("Monitoring cooling, temp: ~w", [T]).
internal_event(cooling_monitor, 0, forever, believes(mode(cooling)), forever).

%% Fire only during work hours (between time window)
work_hours_checkI :>
    log("Work hours system check").
internal_event(work_hours_check, 10, forever, true, in_date(time(9,0), time(17,0))).
```

The `interval(N)` option mirrors DALI's per-event time period (`internal_event/5` Arg 2). Without it, internal events fire every cycle.

The `change([FactList])` option mirrors DALI's change condition (`internal_event/5` Arg 4). When any belief or past event in the list changes, the `times(N)` counter resets to zero, allowing the event to fire again.

Each internal event is tracked: the engine counts how many times it has fired and records each firing in past memory as `internal(Event)`.

---

## Periodic Tasks

Run a task at fixed time intervals.

**Syntax:**

```prolog
every(Seconds, Goal).
every(Seconds) :- Body.
```

**Examples:**

```prolog
:- agent(sensor, [cycle(1)]).

%% Simple periodic log
every(10, log("Heartbeat")).

%% Periodic with body
every(30) :-
    log("Checking system health"),
    send(dashboard, health_check).
```

Unlike internal events, periodic tasks don't have conditional options — they simply fire every N seconds.

---

## Condition Monitors

Check a condition every cycle. If true, execute the body. **Level-triggered**: fires every cycle while the condition holds. **[NEW in DALI2]**

**Syntax:**

```prolog
when(Condition) :- Body.
when(Condition1, Condition2) :- Body.     %% both must hold
```

**Examples:**

```prolog
:- agent(thermostat, [cycle(2)]).

%% Fire every cycle while temperature is high
when(believes(temperature(T)), T > 30) :-
    send(ac_controller, cool_down).

:- agent(alarm, [cycle(1)]).

%% Check a past event condition
when(has_past(intrusion_detected)) :-
    send(security, alert).
```

---

## Condition-Action Rules

**Edge-triggered**: fires exactly once when a condition transitions from false to true. Does not fire again until the condition becomes false and then true again.

**Syntax:**

```prolog
Condition :< Action.
```

**Examples:**

```prolog
:- agent(thermostat, [cycle(2)]).

%% Fire once when cooling mode activates (DALI :< syntax)
believes(mode(cooling)) :< (
    log("Cooling mode just activated"),
    send(logger, log_event(mode_change, thermostat, cooling))
).

:- agent(robot, [cycle(1)]).

%% Fire once when battery becomes low
believes(battery_level(L)), L < 20 :< (
    log("Battery low! Requesting charge."),
    send(charger, request_charge)
).
```

**Difference from `when`:**
- `when` fires **every cycle** while the condition is true (level-triggered)
- `:<` fires **once** when the condition becomes true (edge-triggered), then waits for it to become false before it can fire again

---

## Present/Environment Events

Present events (suffix `N`) represent **atomic environmental observations**. They cannot be "defined" with `:-` — they are set by the environment and checked as conditions in other rules.

This matches the original DALI semantics where present events (`en/1`) are flags that the environment sets, and the agent uses them as triggers/conditions in reactive rules.

**Usage:** Present events appear only in the **body** of `:>`, `:<`, or `when` rules:

```prolog
:- agent(robot, [cycle(1)]).

%% React to an environmental observation via reactive rule
obstacle_detectedE(Distance) :>
    Distance < 5,
    log("Obstacle detected at ~w meters, turning around", [Distance]),
    do(turn_around).

%% Or use when() to monitor an environmental condition each cycle
when(believes(obstacle_ahead(true))) :-
    do(turn_around),
    log("Obstacle ahead — turning").
```

**Important:** Writing `condN :- body.` (N suffix in the head of `:-`) is **not allowed** and will produce a loader warning. Present events are atomic — they don't have definitions.

---

## Multi-Events

Fire when **all** listed events have occurred in the agent's past memory. The body fires once when all events are present; it resets if any event is removed from the past.

**Syntax:**

```prolog
event1E(Args), event2E(Args) :> Body.                      %% no time constraint
event1E(Args), event2E(Args), within(Seconds) :> Body.     %% with delta-t
```

The optional `within(Seconds)` specifies a **delta-t** (simultaneity interval): all events must have occurred within the given time window. This mirrors DALI's original `deltat/1` mechanism. Without `within`, events are matched regardless of when they occurred.

**Examples:**

```prolog
:- agent(coordinator, [cycle(2)]).

%% Fire when both sensor data AND alert received within 10 seconds
sensor_dataE(_), alertE(_, _), within(10) :>
    log("Both events received within 10s!"),
    send(logger, log_event(combined_alert, coordinator, multi_trigger)).

%% Fire when all three events occurred (no time constraint)
loginE(User), verifyE(User), authorizeE(User) :>
    log("User ~w fully authenticated", [User]).
```

The engine checks past events (received, injected, and internal) for matches. Each event in the list must have occurred at least once. With `within(N)`, the timestamps of all matched events must fall within an N-second window.

---

## Constraints

Invariant conditions that are checked every cycle. If a constraint is violated (condition is false), the engine logs a warning.

**Syntax:**

```prolog
:~ Condition.                      %% prefix syntax, identical to original DALI
```

**Examples:**

```prolog
:- agent(thermostat, [cycle(2)]).

%% Safety constraint: temperature must stay below 50
%% :~ Condition. — fires when Condition is FALSE (violated)
:~ (believes(current_temp(T)), T < 50).

:- agent(server, [cycle(1)]).

%% Invariant: agent must always have a valid config
:~ believes(config_loaded).
```

When a constraint is violated (condition is false), the engine logs a warning. This matches the original DALI semantics where `:~ Cond.` is transformed into `vincolo :- Cond.` and the runtime checks it every cycle.

---

## Goals

Goal-directed behavior. Two types:

- **`achieve`** (`obt_goal`): keep trying the plan every cycle until the goal condition is met
- **`test`** (`test_goal`): try the plan once, record whether the goal succeeded or failed

**Syntax:**

```prolog
obt_goal(GoalCondition) :- Plan.    %% achieve goal
test_goal(GoalCondition) :- Plan.   %% test goal
```

**Examples:**

```prolog
:- agent(sensor, [cycle(2)]).

%% Keep sending calibration requests until calibrated (DALI obt_goal)
obt_goal(believes(calibrated(true))) :-
    log("Attempting calibration..."),
    send(coordinator, calibration_request).

:- agent(coordinator, [cycle(2)]).

%% Test that we have received at least one alert (DALI test_goal)
test_goal(believes(alerts_received(N)), N > 0) :-
    log("Testing if any alerts received...").
```

**Goal lifecycle:**
- **achieve**: at each cycle, check if `GoalCondition` holds. If yes, mark as `achieved`. If not, execute `Plan`. Once achieved, the goal is done (will not re-execute).
- **test**: execute `Plan` once, then check `GoalCondition`. Record result as `succeeded`, `failed`, or `error`. Will not retry.

Use `reset_goal(GoalCondition)` in rule bodies to allow a goal to be re-attempted.

---

## Tell/Told Communication Filtering

Control which messages an agent can send and receive. Mirrors DALI's `communication.con` filtering.

### Told (receive filter)

Defines which message patterns an agent is willing to accept. The body can contain **conditions** that must be satisfied for the message to be accepted.

**Syntax:**

```prolog
told(_, Pattern, Priority) :- Body.    %% 3-arg: accept with priority and condition
told(_, Pattern) :- Body.              %% 2-arg: accept with condition (priority=0)
told(_, Pattern, Priority).            %% 3-arg bare: accept unconditionally
told(_, Pattern).                      %% 2-arg bare: accept unconditionally (priority=0)
```

If an agent has **any** `told` rules, only messages matching at least one `told` pattern **and** whose body condition succeeds are accepted. Messages not matching are rejected with a log entry. If an agent has **no** `told` rules, all messages are accepted (backward compatible).

**Priority Queue**: When an agent has `told` rules with priority values, incoming messages are **sorted by priority** (highest first) before processing. This mirrors DALI's priority-based message queue.

**Body conditions**: The body of a told rule is evaluated as a condition when a matching message arrives. This allows filtering based on agent state (beliefs, past events, etc.). Using `true` as body means unconditional acceptance.

### Tell (send filter)

Defines which message patterns an agent is allowed to send. The body can contain **conditions**.

**Syntax:**

```prolog
tell(_, _, Pattern) :- Body.           %% allowed to send Pattern if Body holds
tell(_, _, Pattern).                   %% allowed unconditionally
```

If an agent has **any** `tell` rules, only messages matching at least one `tell` pattern **and** whose body condition succeeds can be sent. Others are blocked. If an agent has **no** `tell` rules, all messages are allowed.

### AI Oracle Filtering

Tell/told rules also apply to **AI Oracle** queries and responses:

- **Tell rules** filter the query context sent to the oracle. If the query doesn't match any `tell` pattern, the oracle call is blocked and returns `blocked(Context)`.
- **Told rules** filter the response received from the oracle. If the response doesn't match any `told` pattern, it is rejected and returns `rejected(RawResponse)`.

This ensures agents can control what information they share with the AI oracle and what advice they accept back.

**Examples:**

```prolog
:- agent(coordinator, [cycle(2)]).

%% Told rules with body conditions
told(_, emergency(_, _), 200) :- true.                     %% always accept emergencies
told(_, alert(_, _), 100) :- true.
told(_, sensor_data(_), 30) :- believes(status(active)).   %% accept only when active
told(_, calibration_request, 10) :- true.
told(_, heartbeat).                                        %% 2-arg form (priority=0)

%% Told with complex body condition (like DALI communication.con)
told(_, refuse(_, Xp)) :- functor(Xp, Fp, _), Fp = agree. %% only accept refuse if about agree

%% Tell rules with body conditions
tell(_, _, calibration_done) :- true.
tell(_, _, propose(_)) :- believes(status(active)).        %% send proposals only when active
tell(_, _, log_event(_, _, _)) :- true.
tell(_, _, analyze(_)) :- true.
```

---

## FIPA Message Types

DALI2 supports FIPA-ACL message types for structured inter-agent communication. FIPA types are sent as regular messages but have special semantics on the receiving side.

**Supported FIPA types:**

| Type | Syntax | Receiver Semantics |
|------|--------|--------------------|
| `inform(Content)` | `send(To, inform(Content))` | Normal handler + past record |
| `inform(Content, Meta)` | `send(To, inform(Content, Meta))` | Normal handler + past record |
| `confirm(Fact)` | `send(To, confirm(Fact))` | Records `confirmed(Fact)` as past event |
| `disconfirm(Fact)` | `send(To, disconfirm(Fact))` | Removes `confirmed(Fact)` from past |
| `propose(Action)` | `send(To, propose(Action))` | Fires `on_proposal` handler |
| `accept_proposal(Action)` | `send(To, accept_proposal(A))` | Normal handler |
| `reject_proposal(Action)` | `send(To, reject_proposal(A))` | Normal handler |
| `query_ref(Query)` | `send(To, query_ref(Query))` | Auto-responds with matching beliefs |
| `agree(Content)` | `send(To, agree(Content))` | Normal handler |
| `refuse(Content)` | `send(To, refuse(Content))` | Normal handler |
| `failure(Action, Reason)` | `send(To, failure(A, R))` | Normal handler |
| `cancel(Action)` | `send(To, cancel(Action))` | Normal handler |

**Special semantics:**

- **`confirm(Fact)`**: The receiver records `confirmed(Fact)` as a past event. Check with `has_confirmed(Fact)`.
- **`disconfirm(Fact)`**: The receiver removes `confirmed(Fact)` from past events.
- **`query_ref(Query)`**: The receiver automatically responds with `inform(query_ref(Query), values(Results))` containing all matching beliefs.
- **`propose(Action)`**: Fires any `on_proposal(Action)` handlers (see [Action Proposals](#action-proposals)).

**Examples:**

```prolog
:- agent(sensor, [cycle(1)]).

%% Confirm a fact to another agent
measurement_completeE(Data) :>
    send(coordinator, confirm(measurement(Data))).

:- agent(coordinator, [cycle(2)]).

%% Query another agent's beliefs
need_statusE :>
    send(sensor, query_ref(status(_))).

%% Handle the query response
informE(query_ref(Q), values(V)) :>
    log("Query ~w returned: ~w", [Q, V]).
```

---

## Action Proposals

The proposal mechanism enables negotiation between agents using FIPA propose/accept/reject.

**Syntax:**

```prolog
on_proposal(ActionPattern) :- Body.
```

When an agent receives a `propose(Action)` message, all matching `on_proposal` handlers fire. Inside the handler, `from(Sender)` retrieves the proposer, and `accept_proposal(To, Action)` or `reject_proposal(To, Action)` send the response.

**Examples:**

```prolog
:- agent(worker, [cycle(2)]).

%% Worker handles proposals
on_proposal(analyze(Data)) :-
    believes(skill(data_analysis)),
    from(Sender),
    log("Accepting analyze(~w) from ~w", [Data, Sender]),
    accept_proposal(Sender, analyze(Data)),
    do(analyze(Data)).

on_proposal(impossible_task) :-
    from(Sender),
    reject_proposal(Sender, impossible_task).

:- agent(coordinator, [cycle(2)]).

%% Coordinator sends a proposal
request_analysisE(Data) :>
    send(worker, propose(analyze(Data))).

%% Coordinator handles response
accept_proposalE(Action) :>
    log("Worker accepted: ~w", [Action]).
reject_proposalE(Action) :>
    log("Worker rejected: ~w", [Action]).
```

---

## Past Event Lifetime & Remember

Control how long past events are kept in memory. Mirrors DALI's `past_event/2` and `remember_event/2`.

### Past Lifetime

**Syntax:**

```prolog
past_event(Pattern, Duration).
```

When a past event matching `Pattern` exceeds `Duration` seconds, it is moved to the **remember** tier (if a remember lifetime exists) or deleted.

| Duration | Meaning |
|----------|----------|
| Number (seconds) | Expire after N seconds |
| `forever` | Never expire |

### Remember Lifetime

**Syntax:**

```prolog
remember_event(Pattern, Duration).
```

Expired past events move to the remember tier. When a remember event exceeds its own `Duration`, it is permanently deleted.

### Remember Limit

**Syntax:**

```prolog
remember_event_mod(Pattern, number(N), Mode).
```

Keep only `N` remember events matching `Pattern`. `Mode` is `last` (keep newest) or `first` (keep oldest).

**Examples:**

```prolog
:- agent(sensor, [cycle(2)]).

%% Sensor readings expire after 30 seconds, then remembered for 5 minutes
past_event(sensor_data(_), 30).
remember_event(sensor_data(_), 300).
remember_event_mod(sensor_data(_), number(10), last).

%% Alarms never expire from past
past_event(alarm(_), forever).
```

**DSL predicates:**
- `has_remember(Event)` — check if event is in remember tier
- `has_remember(Event, Time)` — check with timestamp
- `has_confirmed(Fact)` — check if fact was confirmed via FIPA

---

## Export Past Rules

Reactive rules that fire when past event patterns match, **consuming** (deleting) the matched past events. Mirrors DALI's `~/`, `</`, `?/` operators.

### Export Past (~/ operator)

Fires when all listed events exist in past memory, then consumes them.

**Syntax:**

```prolog
Action ~/ past_event1, past_event2.
```

### Export Past Done (?/ operator)

Fires only if the action WAS done (exists in past as `did(Action)`) and all listed events exist.

**Syntax:**

```prolog
Action ?/ past_event1, past_event2.
```

### Export Past NOT Done (</ operator)

Fires only if the action was NOT done and all listed events exist.

**Syntax:**

```prolog
Action </ past_event1, past_event2.
```

**Examples:**

```prolog
:- agent(coordinator, [cycle(2)]).

%% When both alert and sensor_data in past, consume and react (DALI ~/ syntax)
send(logger, log_event(past_consumed, coordinator, [Type, Value])) ~/
    alert(Type, _), sensor_data(Value).

%% Warn if backup was NOT done but critical data exists (DALI </ syntax)
log("Backup NOT done! critical_data needs attention!") </
    critical_data(_).
```

The matched past events are **consumed** (removed from past memory) when the rule fires. This prevents the rule from firing again with the same events.

---

## Residue Goals

When `achieve(Goal)` is called in a rule body but the goal condition is not yet satisfiable, the goal is queued as a **residue**. Residue goals are automatically retried each cycle until the condition becomes true.

This mirrors DALI's `residue_goal` / `tenta_residuo` mechanism.

```prolog
:- agent(coordinator, [cycle(2)]).

%% The achieve call queues the goal as residue if not immediately satisfiable
start_residue_testE :>
    log("Starting residue goal test..."),
    achieve(has_past(residue_resolved)).

%% Later, when residue_resolved is injected, the residue goal resolves automatically
```

**Lifecycle:**
1. `achieve(Goal)` is called — if `Goal` is true, it's immediately achieved
2. If `Goal` is not yet true, it's queued as a **residue goal**
3. Each cycle, all residue goals are re-checked
4. When the condition becomes true, the goal is marked `achieved` and removed from residue

---

## Ontology Declarations

Define semantic equivalences between terms. Replaces DALI's OWL/`meta/3` ontology with a simpler Prolog-native format. Ontology declarations make event matching, belief checking, and condition evaluation aware of synonyms and equivalences.

**Syntax:**

```prolog
ontology(same_as(Term1, Term2)).           %% Term1 and Term2 are synonyms
ontology(eq_property(Functor1, Functor2)). %% Functors are equivalent properties
ontology(eq_class(Class1, Class2)).         %% Classes are equivalent
ontology(symmetric(Relation)).              %% Relation(A,B) = Relation(B,A)
```

**Examples:**

```prolog
:- agent(logger, [cycle(2)]).

ontology(same_as(log_event, log_entry)).
ontology(eq_property(log_event, record)).
ontology(symmetric(related_to)).
```

**Effects:**
- `believes(warm(room1))` will match a belief `hot(room1)` if `same_as(hot, warm)` is declared
- `readingE(temp(30))` will match an incoming event `reading(temperature(30))` if `eq_property(temperature, temp)` is declared
- `nearE(a, b)` will match an incoming event `near(b, a)` if `symmetric(near)` is declared
- Use `onto_match(T1, T2)` in rule bodies to explicitly check ontology equivalence

### Ontology File Loading

Load ontology declarations from an external Prolog file:

```prolog
ontology_file('path/to/ontology.pl').
```

The file should contain `same_as/2`, `eq_property/2`, `eq_class/2`, and/or `symmetric/1` facts:

```prolog
%% ontology.pl
same_as(temperature, temp).
eq_property(location, position).
eq_class(sensor, detector).
symmetric(connected_to).
```

Ontology files are loaded when the agent starts.

---

## Learning Rules

Agents can learn from experience. Learning rules are triggered when matching events occur. Learned associations are stored and can be queried later.

**Syntax:**

```prolog
learn_from(EventPattern, Outcome) :- Condition.
learn_from(EventPattern, Outcome).              %% unconditional
```

When an event matching `EventPattern` occurs (received, injected, or internal), and `Condition` succeeds, the agent records `learned(Event, Outcome)`.

**Examples:**

```prolog
:- agent(sensor, [cycle(2)]).

%% Learn that high readings indicate overheating
learn_from(read_temp(T), overheating) :- T > 80.

%% Learn that low readings are normal
learn_from(read_temp(T), normal) :- T =< 80.
```

**Using learned knowledge in rules:**

```prolog
read_tempE(T) :>
    log("Sensor read: ~w", [T]),
    ( learned(read_temp(_), overheating) ->
        log("WARNING: Previously learned overheating pattern!"),
        send(coordinator, alert(repeated_overheating, T))
    ;
        true
    ),
    send(coordinator, sensor_data(T)).
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
actionA(Args) :- Body.
```

The `A` suffix marks action definitions.

**Examples:**

```prolog
:- agent(worker, [cycle(2)]).

%% Action definition (DALI A suffix style)
analyzeA(Data) :-
    log("Executing analysis: ~w", [Data]),
    assert_belief(analysis_complete(Data)),
    send(coordinator, inform(analysis_result(Data), complete)).
```

**Calling actions:**

```prolog
request_analysisE(Data) :>
    do(analyze(Data)).
```

---

## Beliefs

Initial beliefs are declared as facts. Beliefs can be added and removed at runtime.

**Syntax:**

```prolog
believes(Fact).
```

**Examples:**

```prolog
:- agent(thermostat, [cycle(2)]).

believes(target_temp(22)).
believes(current_temp(20)).
believes(mode(idle)).
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
helper(Head) :- Body.
```

**Examples:**

```prolog
:- agent(logger, [cycle(2)]).

helper(count_logs) :-
    findall(_, believes(logged(_, _)), Logs),
    length(Logs, N),
    log("Total log entries: ~w", [N]).
```

---

## DSL Predicates Reference

These predicates are available inside rule bodies:

### Communication

| Predicate | Description |
|-----------|-------------|
| `send(Agent, Content)` | Send a message to another agent (filtered by tell/told) |
| `broadcast(Content)` | Send to all other agents |
| `from(Sender)` | Get sender of current message (use in handlers/proposals) |
| `reply_to(Content)` | Reply to current message sender |
| `accept_proposal(To, Action)` | Send accept\_proposal FIPA message |
| `reject_proposal(To, Action)` | Send reject\_proposal FIPA message |

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
| `has_remember(Event)` | Check if event is in remember tier |
| `has_remember(Event, Time)` | Check remember with timestamp |
| `has_confirmed(Fact)` | Check if fact was confirmed via FIPA confirm |

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
| `achieve(Goal)` | Trigger achieve goal (queued as residue if not satisfiable) |
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

Each agent runs as a **separate OS process** with a cycle-based event loop. The master server spawns one `swipl` process per agent. Agents communicate via Redis pub/sub (LINDA channel).

```
┌─────────────────────────────────────────┐
│              Agent Cycle                │
├─────────────────────────────────────────┤
│  1. Process messages (priority queue)   │
│  2. Process injected events             │
│  3. Process internals (interval/change) │
│  4. Process periodic tasks              │
│  5. Process condition monitors          │
│  6. Process condition-actions           │
│  7. Process present events              │
│  8. Process multi-events                │
│  9. Process past reactions (on_past)    │
│ 10. Check constraints                   │
│ 11. Process goals + residue goals       │
│ 12. Clean up expired past events        │
│ 13. Sleep for cycle duration            │
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
- `confirmed(Fact)` — fact confirmed via FIPA confirm

Past events can have **lifetimes** (via `past_event/2`) and move to a **remember** tier when they expire.

---

## DALI Syntax Comparison

DALI2 uses the **same syntax** as the original DALI. No agent prefix is needed — use `:- agent(name).` to set context.

| Feature | DALI (SICStus) | DALI2 (SWI-Prolog) |
|---------|----------------|---------------------|
| External event | `eventE(X) :> body.` | `eventE(X) :> body.` (identical) |
| Internal event | `eventI :> body.` + `internal_event/5` | `eventI :> body.` + `internal_event/5` (identical) |
| Condition-action | `cond :< action.` | `cond :< action.` (identical) |
| Present event | Atomic (`en/1`) | Atomic (use in body of `:>`, `:<`, `when`) |
| Multi-events | `ev1E, ev2E :> body.` + `deltat/1` | `ev1E, ev2E, within(N) :> body.` |
| Constraint | `:~ constraint.` | `:~ constraint.` (identical) |
| Export past (~/) | `head ~/ past1, past2.` | `head ~/ past1, past2.` (identical) |
| Export past (</) | `head </ past1, past2.` | `head </ past1, past2.` (identical) |
| Export past (?/) | `head ?/ past1, past2.` | `head ?/ past1, past2.` (identical) |
| Action definition | `actionA(X) :- body.` | `actionA(X) :- body.` (identical) |
| Obtain goal | `obt_goal(goal) :- plan.` | `obt_goal(goal) :- plan.` (identical) |
| Test goal | `test_goal(goal) :- plan.` | `test_goal(goal) :- plan.` (identical) |
| Past lifetime | `past_event(ev, 60).` | `past_event(ev, 60).` (identical) |
| Remember | `remember_event(ev, 3600).` | `remember_event(ev, 3600).` (identical) |
| Remember limit | `remember_event_mod(ev, number(5), last).` | `remember_event_mod(ev, number(5), last).` (identical) |
| Told | `told(_, pattern, pri) :- body.` | `told(_, pattern, pri) :- body.` (identical) |
| Told (no priority) | `told(_, pattern) :- body.` | `told(_, pattern) :- body.` (identical) |
| Tell | `tell(_, _, pattern) :- body.` | `tell(_, _, pattern) :- body.` (identical) |
| Send message | `messageA(dest, send_message(content, Me))` | Same, or `send(dest, content)` |
| Past check | `evp(event)` / `eventP(args)` | Same, or `has_past(event)` |
| Residue goal | `tenta_residuo(goal)` | Same, or `achieve(goal)` |
| Belief check | `clause(isa(fact,_,_),_)` | Same, or `believes(fact)` |
| Ontology | `meta/3` + OWL | `ontology(same_as(a,b)).` |
| Learning | — | `learn_from(event, outcome) :- cond.` |
| Periodic | — | `every(seconds, goal).` |
| Condition monitor | — | `when(condition) :- body.` |
| Helper | — | `helper(head) :- body.` |
| Proposal handler | — | `on_proposal(action) :- body.` |
| AI Oracle | — | `ask_ai(context, result)` (in body) |
| Blackboard | Linda (TCP) | `bb_read`/`bb_write`/`bb_remove` (in body) |
