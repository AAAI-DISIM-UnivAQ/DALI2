%% DALI2 Loader - Agent definition parser
%%
%% Uses DALI syntax. Rules are associated with the most recently
%% declared agent via :- agent(Name).
%%
%% Supported syntax:
%%   eventE(X) :> body.                       External event
%%   eventI(X) :> body.                       Internal event
%%   internal_event(Ev, Period, Rep, S, St).  Internal event configuration
%%   actionA(X) :- body.                      Action definition
%%   condN                                    Present event (atomic, body only)
%%   cond :< action.                          Condition-action
%%   head ~/ past1, past2.                    Export past
%%   head </ past1, past2.                    Export past NOT done
%%   head ?/ past1, past2.                    Export past done
%%   :~ condition.                            Constraint
%%   told(_, Pattern, Priority) :- Body.      Told rule (3-arg)
%%   told(_, Pattern) :- Body.                Told rule (2-arg, priority=0)
%%   tell(_, _, Pattern) :- Body.             Tell rule
%%   past_event(Event, Duration).             Past lifetime
%%   remember_event(Event, Duration).         Remember lifetime
%%   remember_event_mod(Ev, number(N), M).    Remember limit
%%   obt_goal(Goal) :- Plan.                  Obtain goal
%%   test_goal(Goal) :- Plan.                 Test goal
%%   believes(Fact).                          Belief
%%   every(Seconds, Goal).                    Periodic task
%%   when(Condition) :- Body.                 Condition monitor
%%   helper(Head) :- Body.                    Utility predicate
%%   on_proposal(Action) :- Body.             Proposal handler
%%   learn_from(Event, Outcome) :- Body.      Learning rule
%%   ontology(Declaration).                   Inline ontology
%%   ontology_file(File).                     External ontology file
%%

:- module(loader, [
    load_agents/1,
    load_agents_from_string/1,
    agent_def/2,
    agent_handler/3,
    agent_periodic/3,
    agent_monitor/3,
    agent_action/3,
    agent_belief/2,
    agent_helper/3,
    agent_internal/4,
    agent_told/4,
    agent_tell/3,
    agent_condition_action/3,
    agent_present/3,
    agent_multi_event/4,
    agent_constraint/3,
    agent_ontology/2,
    agent_learn_rule/4,
    agent_goal/4,
    agent_past_lifetime/3,
    agent_remember_lifetime/3,
    agent_remember_limit/4,
    agent_past_reaction/3,
    agent_past_done_reaction/4,
    agent_past_not_done_reaction/4,
    agent_ontology_file/2,
    agent_on_proposal/3,
    agent_internal_config/6,
    clear_definitions/0,
    transform_body/2
]).

:- use_module(library(lists)).

%% ============================================================
%% DALI OPERATORS
%% Note: DALI original (SICStus) used mixed precedences (500/10/200/1200 xfy)
%% plus dual declarations like op(1200,xfx,[:-,:>]).
%% SWI-Prolog does not allow the same operator with two precedences,
%% so we use uniform 1200/xfx which correctly handles top-level clauses.
%% ============================================================
:- op(1200, xfx, :>).
:- op(1200, xfx, :<).
:- op(1200, xfx, ~/).
:- op(1200, xfx, </).
:- op(1200, xfx, ?/).
:- op(1200, fy, :~).

%% Suppress discontiguous warnings for process_term/1 — clauses are
%% intentionally grouped by feature (DALI operators, then DALI2 compat).
:- discontiguous process_term/1.

%% ============================================================
%% STORED DEFINITIONS
%% ============================================================
:- dynamic agent_def/2.
:- dynamic agent_handler/3.
:- dynamic agent_periodic/3.
:- dynamic agent_monitor/3.
:- dynamic agent_action/3.
:- dynamic agent_belief/2.
:- dynamic agent_helper/3.
:- dynamic agent_internal/4.
:- dynamic agent_told/4.       % agent_told(Agent, Pattern, Priority, Body)
:- dynamic agent_tell/3.        % agent_tell(Agent, Pattern, Body)
:- dynamic agent_condition_action/3.
:- dynamic agent_present/3.
:- dynamic agent_multi_event/4. % agent_multi_event(Agent, EventList, Body, DeltaT)
:- dynamic agent_constraint/3.
:- dynamic agent_ontology/2.
:- dynamic agent_learn_rule/4.
:- dynamic agent_goal/4.
:- dynamic agent_past_lifetime/3.
:- dynamic agent_remember_lifetime/3.
:- dynamic agent_remember_limit/4.
:- dynamic agent_past_reaction/3.
:- dynamic agent_past_done_reaction/4.
:- dynamic agent_past_not_done_reaction/4.
:- dynamic agent_ontology_file/2.
:- dynamic agent_on_proposal/3.
:- dynamic agent_internal_config/6.
:- dynamic current_agent/1.           % tracks the "current" agent for prefix-less rules

%% ============================================================
%% CLEAR / LOAD
%% ============================================================

clear_definitions :-
    retractall(agent_def(_, _)),
    retractall(agent_handler(_, _, _)),
    retractall(agent_periodic(_, _, _)),
    retractall(agent_monitor(_, _, _)),
    retractall(agent_action(_, _, _)),
    retractall(agent_belief(_, _)),
    retractall(agent_helper(_, _, _)),
    retractall(agent_internal(_, _, _, _)),
    retractall(agent_told(_, _, _, _)),
    retractall(agent_tell(_, _, _)),
    retractall(agent_condition_action(_, _, _)),
    retractall(agent_present(_, _, _)),
    retractall(agent_multi_event(_, _, _, _)),
    retractall(agent_constraint(_, _, _)),
    retractall(agent_ontology(_, _)),
    retractall(agent_learn_rule(_, _, _, _)),
    retractall(agent_goal(_, _, _, _)),
    retractall(agent_past_lifetime(_, _, _)),
    retractall(agent_remember_lifetime(_, _, _)),
    retractall(agent_remember_limit(_, _, _, _)),
    retractall(agent_past_reaction(_, _, _)),
    retractall(agent_past_done_reaction(_, _, _, _)),
    retractall(agent_past_not_done_reaction(_, _, _, _)),
    retractall(agent_ontology_file(_, _)),
    retractall(agent_on_proposal(_, _, _)),
    retractall(agent_internal_config(_, _, _, _, _, _)),
    retractall(current_agent(_)).

load_agents(File) :-
    clear_definitions,
    read_file_terms(File, Terms),
    process_terms(Terms),
    post_process_internals.

load_agents_from_string(String) :-
    clear_definitions,
    term_string(Terms, String),
    (is_list(Terms) -> process_terms(Terms) ; process_terms([Terms])),
    post_process_internals.

read_file_terms(File, Terms) :-
    setup_call_cleanup(
        open(File, read, Stream, []),
        read_all_terms(Stream, Terms),
        close(Stream)
    ).

read_all_terms(Stream, Terms) :-
    read_term(Stream, Term, [module(loader)]),
    (Term == end_of_file ->
        Terms = []
    ;
        Terms = [Term | Rest],
        read_all_terms(Stream, Rest)
    ).

process_terms([]).
process_terms([Term | Rest]) :-
    (process_term(Term) -> true ;
        format(atom(Msg), "Warning: could not process term: ~w~n", [Term]),
        print_message(warning, format(Msg, []))
    ),
    process_terms(Rest).

%% ctx(-Name) — get the current agent context; fails if none set
ctx(Name) :- current_agent(Name), !.
ctx(Name) :- agent_def(Name, _), !.  % fallback: first declared agent

%% ============================================================
%% SUFFIX UTILITIES
%% ============================================================

extract_suffix(Atom, Base, Suffix) :-
    atom(Atom),
    atom_chars(Atom, Chars),
    Chars \= [],
    last(Chars, LastChar),
    member(LastChar, ['E', 'I', 'A', 'N', 'P']),
    append(BaseChars, [LastChar], Chars),
    BaseChars \= [],
    atom_chars(Base, BaseChars),
    atom_chars(Suffix, [LastChar]).

strip_suffix_term(Term, BaseTerm, Suffix) :-
    (compound(Term) ->
        Term =.. [Functor | Args],
        extract_suffix(Functor, BaseFunctor, Suffix),
        BaseTerm =.. [BaseFunctor | Args]
    ;
        atom(Term),
        extract_suffix(Term, BaseTerm, Suffix)
    ).

%% ============================================================
%% BODY TRANSFORMATION
%% ============================================================

transform_body(Var, Var) :- var(Var), !.
transform_body(true, true) :- !.
transform_body((A, B), (TA, TB)) :- !,
    transform_body(A, TA), transform_body(B, TB).
transform_body((A ; B), (TA ; TB)) :- !,
    transform_body(A, TA), transform_body(B, TB).
transform_body((A -> B), (TA -> TB)) :- !,
    transform_body(A, TA), transform_body(B, TB).
transform_body(\+(A), \+(TA)) :- !,
    transform_body(A, TA).
transform_body(not(A), not(TA)) :- !,
    transform_body(A, TA).
transform_body(messageA(Dest, send_message(Content, _Me)), send(Dest, Content)) :- !.
transform_body(messageA(Dest, send_message(Content)), send(Dest, Content)) :- !.
transform_body(evp(Event), has_past(Event)) :- !.
transform_body(clause(past(Event,_,_),_), has_past(Event)) :- !.
transform_body(clause(isa(Fact,_,_),_), believes(Fact)) :- !.
transform_body(tenta_residuo(Goal), achieve(Goal)) :- !.
transform_body(Term, do(BaseTerm)) :-
    nonvar(Term), \+ functor(Term, messageA, _),
    strip_suffix_term(Term, BaseTerm, 'A'), !.
transform_body(Term, has_past(BaseTerm)) :-
    nonvar(Term),
    strip_suffix_term(Term, BaseTerm, 'P'), !.
transform_body(Term, Term).

parse_past_list((A, B), [A | Rest]) :- !,
    parse_past_list(B, Rest).
parse_past_list(A, [A]).

%% ============================================================
%% AGENT DECLARATION  —  :- agent(Name) / :- agent(Name, Opts)
%% Sets the "current agent context" for all subsequent rules.
%% ============================================================

process_term(:- agent(Name, Options)) :- !,
    assert(agent_def(Name, Options)),
    retractall(current_agent(_)),
    assert(current_agent(Name)).
process_term(:- agent(Name)) :- !,
    assert(agent_def(Name, [])),
    retractall(current_agent(_)),
    assert(current_agent(Name)).

%% Other directives
process_term(:- Goal) :- !,
    catch(call(Goal), _, true).

%% ============================================================
%% :> OPERATOR  (external / internal events)
%% Supports:  eventE(X) :> body.           (no prefix — uses current agent)
%%            agent:eventE(X) :> body.     (explicit prefix)
%% ============================================================

process_term(:>(Name:Head, Body)) :- !,
    transform_body(Body, TB),
    process_reactive_rule(Name, Head, TB).
process_term(:>(Head, Body)) :- !,
    transform_body(Body, TB),
    (ctx(Ag) ->
        process_reactive_rule(Ag, Head, TB)
    ;
        format(user_error, "loader: :> rule but no agent declared: ~w~n", [Head])
    ).

process_reactive_rule(Name, Head, Body) :-
    (Head = (_H1, _H2) ->
        collect_multi_events(Head, EventList, DeltaT),
        assert(agent_multi_event(Name, EventList, Body, DeltaT))
    ;
        (strip_suffix_term(Head, BaseHead, Suffix) ->
            process_suffixed_reactive(Name, BaseHead, Suffix, Body)
        ;
            assert(agent_handler(Name, Head, Body))
        )
    ).

process_suffixed_reactive(Name, BaseHead, 'E', Body) :- !,
    assert(agent_handler(Name, BaseHead, Body)).
process_suffixed_reactive(Name, BaseHead, 'I', Body) :- !,
    assert(agent_internal(Name, BaseHead, [forever], Body)).
process_suffixed_reactive(Name, BaseHead, _, Body) :-
    assert(agent_handler(Name, BaseHead, Body)).

collect_multi_events(Events, EventList, DeltaT) :-
    collect_multi_events_acc(Events, RawList),
    (select(within(DT), RawList, EventList) -> DeltaT = DT ; EventList = RawList, DeltaT = 0).

collect_multi_events_acc((H1, H2), [Parsed | Rest]) :- !,
    parse_multi_event_term(H1, Parsed),
    collect_multi_events_acc(H2, Rest).
collect_multi_events_acc(H, [Parsed]) :-
    parse_multi_event_term(H, Parsed).

parse_multi_event_term(within(DT), within(DT)) :- !.
parse_multi_event_term(H, Base) :-
    (strip_suffix_term(H, Base, 'E') -> true ; Base = H).

%% ============================================================
%% :< OPERATOR  (condition-action)
%% ============================================================

process_term(:<(Name:Cond, Action)) :- !,
    transform_body(Action, TA),
    assert(agent_condition_action(Name, Cond, TA)).
process_term(:<(Cond, Action)) :- !,
    transform_body(Action, TA),
    (ctx(Ag) -> assert(agent_condition_action(Ag, Cond, TA)) ; true).

%% ============================================================
%% ~/ OPERATOR  (export past)
%% ============================================================

process_term(~/(Name:Action, PB)) :- !,
    parse_past_list(PB, EL), transform_body(Action, TA),
    assert(agent_past_reaction(Name, EL, TA)).
process_term(~/(Action, PB)) :- !,
    parse_past_list(PB, EL), transform_body(Action, TA),
    (ctx(Ag) -> assert(agent_past_reaction(Ag, EL, TA)) ; true).

%% ============================================================
%% </ OPERATOR  (export past NOT done)
%% ============================================================

process_term(</(Name:Action, PB)) :- !,
    parse_past_list(PB, EL),
    transform_body(Action, TA),
    assert(agent_past_not_done_reaction(Name, TA, EL, true)).
process_term(</(Action, PB)) :- !,
    parse_past_list(PB, EL),
    transform_body(Action, TA),
    (ctx(Ag) -> assert(agent_past_not_done_reaction(Ag, TA, EL, true)) ; true).

%% ============================================================
%% ?/ OPERATOR  (export past done)
%% ============================================================

process_term(?/(Name:Action, PB)) :- !,
    parse_past_list(PB, EL),
    transform_body(Action, TA),
    assert(agent_past_done_reaction(Name, TA, EL, true)).
process_term(?/(Action, PB)) :- !,
    parse_past_list(PB, EL),
    transform_body(Action, TA),
    (ctx(Ag) -> assert(agent_past_done_reaction(Ag, TA, EL, true)) ; true).

%% ============================================================
%% :~ OPERATOR  (constraints) — prefix, like original DALI
%%   :~ Condition.             (constraint checked every cycle)
%%   Matches DALI's :~ Cond. → vincolo :- Cond.
%%   If Condition fails, constraint is violated (logged by runtime).
%% ============================================================

process_term(:~(Cond)) :- !,
    (ctx(Ag) -> assert(agent_constraint(Ag, Cond, true)) ; true).

%% ============================================================
%% DALI DECLARATIONS (no prefix needed)
%% ============================================================

%% internal_event/5
process_term(Name:internal_event(Ev, P, R, S, St)) :- !,
    assert(agent_internal_config(Name, Ev, P, R, S, St)).
process_term(internal_event(Ev, P, R, S, St)) :- !,
    (ctx(Ag) -> assert(agent_internal_config(Ag, Ev, P, R, S, St)) ; true).

%% past_event/2
process_term(Name:past_event(Pat, Dur)) :- !, assert(agent_past_lifetime(Name, Pat, Dur)).
process_term(past_event(Pat, Dur)) :- !,
    (ctx(Ag) -> assert(agent_past_lifetime(Ag, Pat, Dur)) ; true).

%% remember_event/2
process_term(Name:remember_event(Pat, Dur)) :- !, assert(agent_remember_lifetime(Name, Pat, Dur)).
process_term(remember_event(Pat, Dur)) :- !,
    (ctx(Ag) -> assert(agent_remember_lifetime(Ag, Pat, Dur)) ; true).

%% remember_event_mod/3
process_term(Name:remember_event_mod(Pat, number(N), M)) :- !,
    assert(agent_remember_limit(Name, Pat, N, M)).
process_term(remember_event_mod(Pat, number(N), M)) :- !,
    (ctx(Ag) -> assert(agent_remember_limit(Ag, Pat, N, M)) ; true).

%% obt_goal / test_goal
process_term((Name:obt_goal(G) :- Plan)) :- !,
    transform_body(Plan, TP), assert(agent_goal(Name, achieve, G, TP)).
process_term(Name:obt_goal(G)) :- !,
    assert(agent_goal(Name, achieve, G, true)).
process_term((obt_goal(G) :- Plan)) :- !,
    transform_body(Plan, TP),
    (ctx(Ag) -> assert(agent_goal(Ag, achieve, G, TP)) ; true).
process_term(obt_goal(G)) :- !,
    (ctx(Ag) -> assert(agent_goal(Ag, achieve, G, true)) ; true).
process_term((Name:test_goal(G, ExtraCond) :- Plan)) :- !,
    transform_body(Plan, TP), assert(agent_goal(Name, test, (G, ExtraCond), TP)).
process_term((Name:test_goal(G) :- Plan)) :- !,
    transform_body(Plan, TP), assert(agent_goal(Name, test, G, TP)).
process_term(Name:test_goal(G, ExtraCond)) :- !,
    assert(agent_goal(Name, test, (G, ExtraCond), true)).
process_term(Name:test_goal(G)) :- !,
    assert(agent_goal(Name, test, G, true)).
process_term((test_goal(G, ExtraCond) :- Plan)) :- !,
    transform_body(Plan, TP),
    (ctx(Ag) -> assert(agent_goal(Ag, test, (G, ExtraCond), TP)) ; true).
process_term((test_goal(G) :- Plan)) :- !,
    transform_body(Plan, TP),
    (ctx(Ag) -> assert(agent_goal(Ag, test, G, TP)) ; true).
process_term(test_goal(G, ExtraCond)) :- !,
    (ctx(Ag) -> assert(agent_goal(Ag, test, (G, ExtraCond), true)) ; true).
process_term(test_goal(G)) :- !,
    (ctx(Ag) -> assert(agent_goal(Ag, test, G, true)) ; true).

%% told/tell  —  DALI communication filtering rules
%% Supports arbitrary body conditions (not just true).
%% told(From, Pattern, Priority) :- Body.   3-arg with body
%% told(From, Pattern, Priority).           3-arg bare (body=true)
%% told(From, Pattern) :- Body.             2-arg with body (priority=0)
%% told(From, Pattern).                     2-arg bare (priority=0, body=true)
%% tell(To, From, Pattern) :- Body.         3-arg with body
%% tell(To, From, Pattern).                 3-arg bare (body=true)
process_term((told(_, Pat, Pri) :- Body)) :- !,
    transform_body(Body, TB),
    (ctx(Ag) -> assert(agent_told(Ag, Pat, Pri, TB)) ; true).
process_term(told(_, Pat, Pri)) :- !,
    (ctx(Ag) -> assert(agent_told(Ag, Pat, Pri, true)) ; true).
process_term((told(_, Pat) :- Body)) :- !,
    transform_body(Body, TB),
    (ctx(Ag) -> assert(agent_told(Ag, Pat, 0, TB)) ; true).
process_term(told(_, Pat)) :- !,
    (ctx(Ag) -> assert(agent_told(Ag, Pat, 0, true)) ; true).
process_term((tell(_, _, Pat) :- Body)) :- !,
    transform_body(Body, TB),
    (ctx(Ag) -> assert(agent_tell(Ag, Pat, TB)) ; true).
process_term(tell(_, _, Pat)) :- !,
    (ctx(Ag) -> assert(agent_tell(Ag, Pat, true)) ; true).

%% believes (no prefix)
process_term(Name:believes(Fact)) :- !, assert(agent_belief(Name, Fact)).
process_term(believes(Fact)) :- !,
    (ctx(Ag) -> assert(agent_belief(Ag, Fact)) ; true).

%% ============================================================
%% DALI2 NEW FEATURES (no prefix needed)
%% ============================================================

%% every (periodic)
process_term(Name:every(S, G)) :- !, assert(agent_periodic(Name, S, G)).
process_term(every(S, G)) :- !,
    (ctx(Ag) -> assert(agent_periodic(Ag, S, G)) ; true).
process_term((Name:every(S) :- B)) :- !,
    transform_body(B, TB), assert(agent_periodic(Name, S, TB)).
process_term((every(S) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_periodic(Ag, S, TB)) ; true).

%% when (condition monitor)
process_term((Name:when(C) :- B)) :- !,
    transform_body(B, TB), assert(agent_monitor(Name, C, TB)).
process_term((when(C) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_monitor(Ag, C, TB)) ; true).
process_term((Name:when(C1, C2) :- B)) :- !,
    transform_body(B, TB), assert(agent_monitor(Name, (C1, C2), TB)).
process_term((when(C1, C2) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_monitor(Ag, (C1, C2), TB)) ; true).

%% helper
process_term((Name:helper(H) :- B)) :- !,
    transform_body(B, TB), assert(agent_helper(Name, H, TB)).
process_term(Name:helper(H)) :- !, assert(agent_helper(Name, H, true)).
process_term((helper(H) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_helper(Ag, H, TB)) ; true).
process_term(helper(H)) :- !,
    (ctx(Ag) -> assert(agent_helper(Ag, H, true)) ; true).

%% on_proposal
process_term((Name:on_proposal(A) :- B)) :- !,
    transform_body(B, TB), assert(agent_on_proposal(Name, A, TB)).
process_term((on_proposal(A) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_on_proposal(Ag, A, TB)) ; true).

%% learn_from
process_term((Name:learn_from(E, O) :- B)) :- !,
    transform_body(B, TB), assert(agent_learn_rule(Name, E, O, TB)).
process_term(Name:learn_from(E, O)) :- !,
    assert(agent_learn_rule(Name, E, O, true)).
process_term((learn_from(E, O) :- B)) :- !,
    transform_body(B, TB),
    (ctx(Ag) -> assert(agent_learn_rule(Ag, E, O, TB)) ; true).
process_term(learn_from(E, O)) :- !,
    (ctx(Ag) -> assert(agent_learn_rule(Ag, E, O, true)) ; true).

%% ontology / ontology_file
process_term(Name:ontology(D)) :- !, assert(agent_ontology(Name, D)).
process_term(ontology(D)) :- !,
    (ctx(Ag) -> assert(agent_ontology(Ag, D)) ; true).
process_term(Name:ontology_file(F)) :- !, assert(agent_ontology_file(Name, F)).
process_term(ontology_file(F)) :- !,
    (ctx(Ag) -> assert(agent_ontology_file(Ag, F)) ; true).

%% ============================================================
%% PREFIX-LESS Action (A suffix)
%% These must be AFTER all specific functor matches to avoid
%% accidentally matching told/tell/believes/etc.
%% ============================================================

%% actionA(Args) :- Body.   (no prefix)
process_term((Head :- Body)) :-
    nonvar(Head), \+ (Head = _:_),
    strip_suffix_term(Head, BaseHead, 'A'), !,
    transform_body(Body, TB),
    (ctx(Ag) -> assert(agent_action(Ag, BaseHead, TB)) ; true).

%% actionA(Args) :- Body.  (with prefix)
process_term((Name:Head :- Body)) :-
    strip_suffix_term(Head, BaseHead, 'A'), !,
    transform_body(Body, TB),
    assert(agent_action(Name, BaseHead, TB)).

%% BLOCKED: Present events (N suffix) and External events (E suffix)
%% must NOT appear as head of :- rules. They are atomic observations.
process_term((Head :- _Body)) :-
    nonvar(Head), \+ (Head = _:_),
    strip_suffix_term(Head, _BaseHead, 'N'), !,
    format(user_error, "DALI2 loader WARNING: Present event '~w' cannot be defined with :- (it is atomic). Use it in body of :> or :< rules instead.~n", [Head]).
process_term((Head :- _Body)) :-
    nonvar(Head), \+ (Head = _:_),
    strip_suffix_term(Head, _BaseHead, 'E'), !,
    format(user_error, "DALI2 loader WARNING: External event '~w' cannot be defined with :- (it is atomic). Use :> operator instead: ~w :> body.~n", [Head, Head]).

%% ============================================================
%% CATCH-ALL: bare Prolog facts/rules as beliefs or ignored
%% ============================================================

%% Bare facts (no :-, no operator) → treat as belief for current agent
process_term(Fact) :-
    \+ (Fact = (_ :- _)), \+ (Fact = _:_),
    atom(Fact), !,
    (ctx(Ag) -> assert(agent_belief(Ag, Fact)) ; true).
process_term(Fact) :-
    \+ (Fact = (_ :- _)), \+ (Fact = _:_),
    compound(Fact),
    functor(Fact, F, _),
    \+ member(F, [told, tell, past_event, remember_event, remember_event_mod,
                  internal_event, obt_goal, test_goal, believes,
                  every, when, helper, on_proposal, learn_from,
                  ontology, ontology_file]), !,
    (ctx(Ag) -> assert(agent_belief(Ag, Fact)) ; true).

process_term(Term) :-
    format(user_error, "DALI2 loader: ignoring unrecognized term: ~w~n", [Term]).

%% ============================================================
%% POST-PROCESSING: Merge internal_event/5 configs
%% ============================================================

post_process_internals :-
    forall(
        agent_internal_config(Name, Event, Period, Repetition, StartCond, StopCond),
        merge_internal_config(Name, Event, Period, Repetition, StartCond, StopCond)
    ).

merge_internal_config(Name, Event, Period, Repetition, StartCond, StopCond) :-
    build_internal_options(Period, Repetition, StartCond, StopCond, Options),
    (retract(agent_internal(Name, Event, _OldOpts, Body)) ->
        assert(agent_internal(Name, Event, Options, Body))
    ;
        assert(agent_internal(Name, Event, Options, true))
    ).

build_internal_options(Period, Repetition, StartCond, StopCond, Options) :-
    (number(Period), Period > 0 -> IO = [interval(Period)] ; IO = []),
    (Repetition == forever -> RO = [forever]
    ; number(Repetition) -> RO = [times(Repetition)]
    ; Repetition = change(FL) -> RO = [change(FL)]
    ; RO = [forever]),
    (StartCond == true -> SO = [] ; SO = [trigger(StartCond)]),
    (StopCond = until_cond(C) -> StO = [until(C)]
    ; StopCond = in_date(D1, D2) -> StO = [between(D1, D2)]
    ; StO = []),
    append([IO, RO, SO, StO], Options).
