# DALI vs DALI2 — Analisi Differenze e Piano di Allineamento

## 1. Differenze Trovate (funzionalità condivise, escluse le nuove feature DALI2)

### 1.1 Tell/Told — Body delle regole ignorato ❌

**DALI originale**: Le regole `tell` e `told` supportano **condizioni reali nel body**, non solo `true`.

Esempio dalla `communication.con` degli esempi DALI:
```prolog
told(_,refuse(_,Xp)) :- functor(Xp,Fp,_), Fp=agree.
```

Esempio dalle slide:
```prolog
tell(To,From,Comm_primitive(…)):-
   condition1,...,conditionm,
   constraint1,...,constraintn.

tell(To,_,send_message(…)):-
   told(To, k), not(enemy(To)).
```

**DALI2 attuale**: Il loader accetta SOLO `told(_, Pat, Pri) :- true.` e `tell(_, _, Pat) :- true.`.
Il body viene completamente ignorato — se non è `true`, la regola viene parsata ma il body viene scartato.

```prolog
%% loader.pl:429-436 — solo "true" è accettato come body
process_term((told(_, Pat, Pri) :- true)) :- !,
    (ctx(Ag) -> assert(agent_told(Ag, Pat, Pri)) ; true).
process_term((tell(_, _, Pat) :- true)) :- !,
    (ctx(Ag) -> assert(agent_tell(Ag, Pat)) ; true).
```

Il runtime (`agent_process.pl:176-188`) fa solo pattern matching con `subsumes_term`, senza valutare condizioni:
```prolog
should_allow_receive_local(Receiver, Content, Priority) :-
    (   \+ loader:agent_told(Receiver, _, _)
    ->  Priority = 0
    ;   loader:agent_told(Receiver, Pattern, Priority),
        subsumes_term(Pattern, Content)
    ).
```

**Impatto**: Non è possibile filtrare messaggi con condizioni complesse (es. `not(enemy(To))`, controlli su funtori, etc.).

---

### 1.2 Eventi Presenti (suffisso N) — Semantica invertita ❌

**DALI originale**: Gli eventi presenti sono **osservazioni atomiche dell'ambiente**. NON hanno una "definizione" con `:-`. Internamente vengono gestiti tramite predicati `en/1` e `en/2`:
```prolog
%% active_dali_wi.pl:867-868
assert((en(Me):-en(Me,_))),
assert((en(Me,_):-false)),
```

L'ambiente imposta `en(Event, Time)` quando l'osservazione è vera. Il sistema controlla `en(Event)` ad ogni ciclo e fa scattare le regole reattive associate.

**DALI2 attuale**: Il suffisso N è usato come HEAD di una regola `:-`:
```prolog
obstacle_aheadN :- do(turn_around).
```

Questo viene parsato dal loader come `agent_present(Ag, obstacle_ahead, do(turn_around))` e il motore ogni ciclo:
1. Chiama `call_condition(Name, obstacle_ahead)` — verifica se il "condition" è vero
2. Se vero, esegue il body

**Problema**: Questo è semanticamente diverso da DALI. In DALI, `obstacle_ahead` è un'osservazione ambientale atomica (un flag settato dall'ambiente), NON una condizione da verificare. La sintassi `obstacle_aheadN :- body` mette l'evento presente nella testa, il che secondo la semantica DALI è sbagliato: gli eventi presenti dovrebbero comparire solo nel body delle regole, mai nella testa.

---

### 1.3 Eventi Esterni (suffisso E) in testa con `:-` — Non bloccato ❌

**DALI originale**: Gli eventi esterni usano SOLO l'operatore `:>` per definire reazioni:
```prolog
eventE(X) :> body.    %% corretto — reazione a evento esterno
```
Non esiste `eventE(X) :- body.` in DALI. La term_expansion trasforma `:>` in `:-` internamente, ma l'utente scrive sempre `:>`.

**DALI2 attuale**: Il loader accetta correttamente `eventE(X) :> body.` ma accetta anche `eventE(X) :- body.` come definizione di azione (suffisso A) o non lo blocca.

**Nota**: Questo va verificato — il loader potrebbe già gestirlo correttamente perché il suffisso E viene processato solo con `:>`. Ma è un punto di attenzione da confermare.

---

### 1.4 Multi-Events — Manca il DeltaT (intervallo di simultaneità) ❌

**DALI originale**: I multi-eventi hanno un meccanismo di **simultaneità temporale** basato su `deltat/1`:
```prolog
%% active_dali_wi.pl:46
:-dynamic deltat/1, deltatime/1, simultaneity_interval/1, ...

%% active_dali_wi.pl:2170
simultaneity_interval(E):- once(deltat(X)), assert(deltatime(X)),
    clause(agente(_,_,S,_),_), leggiriga(S,1),
    clause(eventE(Es),_), assert(wishlist(Es)),
    controllo_eventi(E).

%% active_dali_wi.pl:2177
check_while:- now(Time), deltatime(T), tstart(T0), Time-T0=<T.
```

Questo verifica che tutti gli eventi della wishlist arrivino **entro un intervallo di tempo `deltat`**. Se il tempo scade prima che tutti gli eventi siano arrivati, gli eventi vengono gestiti singolarmente.

**DALI2 attuale**: I multi-eventi verificano solo se tutti gli eventi sono nel passato, **senza vincolo temporale**:
```prolog
%% engine.pl:621-633
all_events_occurred(_, []).
all_events_occurred(Name, [Event|Rest]) :-
    event_in_past(Name, Event),
    all_events_occurred(Name, Rest).
```

Un evento arrivato 1 secondo fa e uno arrivato 1 ora fa vengono trattati come "simultanei".

---

### 1.5 Told — Arità diversa (told/6 vs told/3) ⚠️

**DALI originale**: `told/6` è dichiarato dynamic:
```prolog
:-dynamic told/6.
```
E nella `communication_fipa.pl`, told è usato con 2 o 3 argomenti:
```prolog
told(var_Ag, send_message(var_X))         %% 2 args: From, Pattern
told(var_Ag, inform(var_X, var_M), var_T) %% 3 args: From, Pattern, Priority
```

**DALI2 attuale**: `agent_told/3` ha sempre 3 argomenti (Agent, Pattern, Priority). Le regole told senza priorità (2 argomenti) non sono supportate — il loader richiede 3 argomenti:
```prolog
process_term((told(_, Pat, Pri) :- true)) :- !,
```

**Impatto**: Regole `told(_, pattern) :- body.` (senza priorità) del DALI originale non vengono parsate correttamente.

---

### 1.6 Operatori — Precedenze diverse ⚠️

**DALI originale**:
```prolog
:-op(500,xfy,:>).
:-op(500,xfy,:<).
:-op(10,xfy,~/).
:-op(1200,xfy,</).
:-op(200,xfy,?/).
```

**DALI2**:
```prolog
:- op(1200, xfx, :>).
:- op(1200, xfx, :<).
:- op(1200, xfx, ~/).
:- op(1200, xfx, </).
:- op(1200, xfx, ?/).
:- op(1200, xfx, :~).
```

DALI2 usa `xfx` (non associativo) e precedenza uniforme 1200 per tutti. DALI originale usa `xfy` (associativo a destra) con precedenze variabili. La differenza di associatività potrebbe causare problemi di parsing per espressioni complesse, anche se per l'uso tipico (head op body) probabilmente non c'è impatto funzionale.

**Nota**: Questa differenza è probabilmente intenzionale per compatibilità SWI-Prolog vs SICStus. Non è detto che vada cambiata.

---

### 1.7 Operatore :~ (constraints) — Assente in DALI originale ⚠️

**DALI originale**: NON ha l'operatore `:~` dichiarato. I vincoli (constraints) vengono gestiti diversamente, tramite `examine_past_constraints.pl` e il meccanismo `evp_con`.

**DALI2**: Usa `:~ Condition :- Handler.` come sintassi per i vincoli.

**Impatto**: La semantica è equivalente (verifica una condizione invariante ogni ciclo), ma la sintassi è diversa. Da verificare se DALI aveva una sintassi utente per i vincoli o se erano solo interni.

---

### 1.8 Communication.con — File separato vs inline ⚠️

**DALI originale**: Le regole tell/told sono in un file separato `communication.con` che viene caricato all'avvio come libreria.

**DALI2**: Le regole tell/told sono inline nel file dell'agente, assieme a tutte le altre regole.

**Impatto**: Differenza architetturale, non funzionale. DALI2 semplifica giustamente questo aspetto.

---

## 2. Feedback del Capo — Analisi e Piano

### 2a. Eventi Presenti e Esterni devono essere atomici ✅ (il capo ha ragione)

Il capo dice:
> - `obstacle_aheadN :- body.` è la sintassi attuale per gli eventi presenti
> - Nella fase di definizione (`:-`), gli eventi presenti devono essere SOLO nel body, MAI nella testa
> - L'evento presente è atomico, non può avere una "definizione"
> - Lo stesso vale per gli eventi esterni

**Analisi**: Questo è **coerente con DALI originale**. In DALI:
- Gli eventi presenti (`en/1`) sono osservazioni ambientali atomiche gestite dal sistema
- Gli eventi esterni (`eventE`) usano `:>` (non `:-`) per le reazioni
- Né eventi presenti né eventi esterni vengono "definiti" con `:-`

**Cosa fare in DALI2**:
1. **Eventi presenti (N suffix)**: Cambiare la semantica. L'evento presente NON deve essere definibile con `condN :- body.`. Deve essere un'osservazione atomica dell'ambiente. Il loader deve rifiutare (o reinterpretare) regole con suffisso N nella testa di `:-`. L'evento presente deve poter apparire come condizione nel body di regole reattive (`:>`, `:<`, `when`, etc.).
2. **Eventi esterni (E suffix)**: Verificare che `eventE :- body` non sia accettato dal loader come definizione. Solo `eventE :> body` deve essere valido.

### 2b. Tell/Told devono supportare condizioni nel body ✅ (il capo ha ragione)

Il capo dice:
> Tell e Told devono avere il corpo con condizioni reali, non solo `true`

**Analisi**: **Confermato** dall'analisi del codice DALI e dagli esempi:
```prolog
%% Esempio reale da DALI examples/win/advanced/conf/communication.con
told(_,refuse(_,Xp)) :- functor(Xp,Fp,_), Fp=agree.
```

**Cosa fare in DALI2**:
1. **Loader**: Modificare `process_term` per accettare told/tell con body arbitrario (non solo `true`)
2. **Strutture dati**: Cambiare `agent_told/3` → `agent_told/4` (Agent, Pattern, Priority, Body) e `agent_tell/2` → `agent_tell/3` (Agent, Pattern, Body)
3. **Engine/agent_process**: Modificare `should_allow_receive_local` e `should_allow_send_local` per valutare il body come condizione aggiuntiva dopo il pattern matching
4. **Told senza priorità**: Supportare anche `told(_, Pattern) :- Body.` (2 argomenti, senza priorità)

### 2c. Multi-Events devono avere un delta-t ✅ (richiesta legittima, presente in DALI)

Il capo dice:
> Nei multi-eventi voglio aggiungere un delta-t, una differenza di tempo entro la quale gli eventi devono essere accaduti

**Analisi**: Questo è **esattamente il meccanismo `deltat/simultaneity_interval` di DALI originale** (righe 2170-2192 di `active_dali_wi.pl`).

**Cosa fare in DALI2**:
1. **Sintassi**: Aggiungere un parametro opzionale di delta-t ai multi-eventi. Possibili sintassi:
   ```prolog
   %% Opzione A: parametro dopo :>
   sensor_dataE(_), alertE(_, _) :> delta(5),
       log("Both received within 5 seconds!").
   
   %% Opzione B: dichiarazione separata (stile internal_event)
   multi_event_delta(sensor_data, alert, 5).
   
   %% Opzione C: nella lista degli eventi
   (sensor_dataE(_), alertE(_, _), within(5)) :> body.
   ```
2. **Loader**: Parsare il delta-t e memorizzarlo in `agent_multi_event/4` (aggiungendo il campo delta)
3. **Engine**: Nella `all_events_occurred/2`, verificare che i timestamp degli eventi nel passato siano tutti entro il delta-t specificato

---

## 3. Piano di Implementazione (ordinato per priorità)

### Fase 1: Tell/Told con body condizionali (CRITICO)

| # | Task | File | Complessità |
|---|------|------|-------------|
| 1.1 | Modificare `agent_told/3` → `agent_told/4` (+ Body) | `loader.pl` | Media |
| 1.2 | Modificare `agent_tell/2` → `agent_tell/3` (+ Body) | `loader.pl` | Media |
| 1.3 | Aggiungere supporto per `told/2` (senza priorità, default 0) | `loader.pl` | Bassa |
| 1.4 | Modificare `process_term` per parsare body arbitrario | `loader.pl` | Media |
| 1.5 | Modificare `should_allow_receive_local` per valutare body | `agent_process.pl` | Media |
| 1.6 | Modificare `should_allow_send_local` per valutare body | `agent_process.pl` | Media |
| 1.7 | Aggiornare equivalente in `engine.pl` | `engine.pl` | Media |
| 1.8 | Aggiornare RULES.md e EXAMPLES.md | docs | Bassa |

### Fase 2: Eventi Presenti atomici (CRITICO)

| # | Task | File | Complessità |
|---|------|------|-------------|
| 2.1 | Ridefinire la semantica di `condN` — non più testa di `:-` | `loader.pl` | Alta |
| 2.2 | Implementare meccanismo di osservazione ambiente (simile a `en/1` DALI) | `engine.pl` | Alta |
| 2.3 | Permettere `condN` nel body di regole `:>`, `:<`, `when` | `loader.pl`, `engine.pl` | Media |
| 2.4 | Aggiungere validazione: rifiutare `eventE :- body` e `condN :- body` | `loader.pl` | Bassa |
| 2.5 | Aggiornare docs | docs | Bassa |

### Fase 3: Multi-Events con delta-t (IMPORTANTE)

| # | Task | File | Complessità |
|---|------|------|-------------|
| 3.1 | Definire sintassi per delta-t (proposta: `within(Seconds)`) | design | Bassa |
| 3.2 | Modificare `agent_multi_event/3` → `agent_multi_event/4` (+ DeltaT) | `loader.pl` | Bassa |
| 3.3 | Parsare delta-t nel loader | `loader.pl` | Media |
| 3.4 | Modificare `all_events_occurred` per controllare timestamp | `engine.pl` | Media |
| 3.5 | Aggiornare `agent_process.pl` (processing locale) | `agent_process.pl` | Media |
| 3.6 | Aggiornare docs | docs | Bassa |

### Fase 4: Differenze minori

| # | Task | File | Complessità |
|---|------|------|-------------|
| 4.1 | Verificare/documentare differenze operatori (xfx vs xfy) | `loader.pl` | Bassa |
| 4.2 | Verificare che `:~` sia equivalente ai constraint DALI | `engine.pl` | Media |
| 4.3 | Supportare `told/2` senza priorità | `loader.pl` | Bassa |

---

## 4. Riepilogo Differenze

| Area | DALI | DALI2 | Identici? | Azione |
|------|------|-------|-----------|--------|
| Operatore `:>` | ✅ | ✅ | ≈ (associatività diversa) | Verificare |
| Operatore `:<` | ✅ | ✅ | ≈ | OK |
| Operatore `~/` | ✅ | ✅ | ≈ | OK |
| Operatore `</` | ✅ | ✅ | ≈ | OK |
| Operatore `?/` | ✅ | ✅ | ≈ | OK |
| Suffisso E (external) | ✅ | ✅ | ✅ | OK |
| Suffisso I (internal) | ✅ | ✅ | ✅ | OK |
| Suffisso A (action) | ✅ | ✅ | ✅ | OK |
| Suffisso P (past) | ✅ | ✅ | ✅ | OK |
| Suffisso N (present) | Atomico | ✅ Atomico (loader warning se head di `:-`) | ✅ | **Fase 2 — IMPLEMENTATA** |
| Tell con body | ✅ | ✅ Body condizionale valutato a runtime | ✅ | **Fase 1 — IMPLEMENTATA** |
| Told con body | ✅ | ✅ Body condizionale valutato a runtime | ✅ | **Fase 1 — IMPLEMENTATA** |
| Told senza priorità | ✅ (2 args) | ✅ `told/2` con priorità=0 | ✅ | **Fase 1 — IMPLEMENTATA** |
| Multi-event delta-t | ✅ (`deltat/1`) | ✅ `within(Seconds)` nella lista eventi | ✅ | **Fase 3 — IMPLEMENTATA** |
| internal_event/5 | ✅ | ✅ | ✅ | OK |
| past_event/2 | ✅ | ✅ | ✅ | OK |
| remember_event/2 | ✅ | ✅ | ✅ | OK |
| remember_event_mod/3 | ✅ | ✅ | ✅ | OK |
| obt_goal | ✅ | ✅ | ✅ | OK |
| test_goal | ✅ | ✅ | ✅ | OK |
| export past (`~/`,`</`,`?/`) | ✅ | ✅ | ✅ | OK |
| evp() / past check | ✅ | ✅ (+ has_past) | ✅ | OK |
| tenta_residuo | ✅ | ✅ (+ achieve) | ✅ | OK |
| Beliefs (isa) | ✅ | ✅ (+ believes) | ✅ | OK |
| FIPA primitives | ✅ | ✅ | ✅ | OK |
| Constraints `:~` | Diverso | ✅ | ⚠️ | Verificare |
| Ontology | OWL/meta/3 | ontology() inline | Diverso (OK) | Feature DALI2 |
