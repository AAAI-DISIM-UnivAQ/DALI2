%% ai_oracle.pl - AI Oracle integration for DALI2 via OpenRouter
%% Sends context to an LLM and receives a Prolog fact back.
%% The API key is read from the OPENROUTER_API_KEY environment variable.

:- module(ai_oracle, [
    ask_ai/2,           % ask_ai(+Context, -PrologFact)
    ask_ai/3,           % ask_ai(+Context, +SystemPrompt, -PrologFact)
    ai_available/0,     % Check if AI oracle is configured
    set_ai_key/1,       % set_ai_key(+Key) - set API key at runtime
    set_ai_model/1,     % set_ai_model(+Model) - set model at runtime
    get_ai_key/1,       % get_ai_key(-Key) - get current key (Redis first, then local)
    get_ai_model/1      % get_ai_model(-Model) - get current model (Redis first, then local)
]).

:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_ssl_plugin)).   % Required for HTTPS
:- use_module(library(json)).
:- use_module(library(readutil)).
:- use_module(redis_comm).

:- dynamic ai_api_key/1.
:- dynamic ai_model/1.

%% Default model (OpenRouter format — free tier)
ai_model('google/gemma-4-31b-it:free').

%% ============================================================
%% CONFIGURATION
%% ============================================================

%% Initialize API key from environment variable
:- (getenv('OPENROUTER_API_KEY', Key), Key \= '' ->
        assert(ai_api_key(Key))
    ; true).

%% set_ai_key(+Key) - Set or update the API key at runtime
%%   Also writes to Redis so all agent processes see the change.
set_ai_key(Key) :-
    retractall(ai_api_key(_)),
    assert(ai_api_key(Key)),
    catch(redis_comm:redis_set_config('DALI2:ai_key', Key), _, true).

%% set_ai_model(+Model) - Set or update the model
%%   Also writes to Redis so all agent processes see the change.
set_ai_model(Model) :-
    retractall(ai_model(_)),
    assert(ai_model(Model)),
    catch(redis_comm:redis_set_config('DALI2:ai_model', Model), _, true).

%% get_ai_key(-Key) - Get current API key: Redis (shared) first, then local
get_ai_key(Key) :-
    (catch(redis_comm:redis_get_config('DALI2:ai_key', K), _, fail) ->
        Key = K
    ; ai_api_key(Key)
    ).

%% get_ai_model(-Model) - Get current model: Redis (shared) first, then local
get_ai_model(Model) :-
    (catch(redis_comm:redis_get_config('DALI2:ai_model', M), _, fail) ->
        Model = M
    ; ai_model(Model)
    ).

%% ai_available/0 - True if an API key is configured
ai_available :-
    get_ai_key(Key),
    Key \= ''.

%% ============================================================
%% MAIN PREDICATES
%% ============================================================

%% ask_ai(+Context, -PrologFact)
%% Sends context to the LLM with a default system prompt that asks
%% for a Prolog fact response. Returns the parsed Prolog term.
ask_ai(Context, PrologFact) :-
    DefaultPrompt = "You are a logic module for a DALI multi-agent system. \c
You receive context from an agent and must respond with EXACTLY ONE valid \c
Prolog fact (a term ending with a period). Do NOT include any explanation, \c
comments, or markdown. Only output a single Prolog term like: \c
suggestion(do_something). or result(value1, value2).",
    ask_ai(Context, DefaultPrompt, PrologFact).

%% ask_ai(+Context, +SystemPrompt, -PrologFact)
%% Full version with custom system prompt.
ask_ai(Context, SystemPrompt, PrologFact) :-
    (ai_available ->
        catch(
            ask_ai_impl(Context, SystemPrompt, PrologFact),
            Error,
            (format(user_error, "[AI Oracle] Error: ~w~n", [Error]),
             throw(ai_error(Error)))
        )
    ;
        format(user_error, "[AI Oracle] No API key configured~n", []),
        throw(ai_error(no_api_key))
    ).

%% ============================================================
%% IMPLEMENTATION
%% ============================================================

to_string(Term, Str) :-
    (string(Term) -> Str = Term ;
     atom(Term) -> atom_string(Term, Str) ;
     term_to_atom(Term, A), atom_string(A, Str)).

ask_ai_impl(Context, SystemPrompt, PrologFact) :-
    get_ai_key(ApiKey),
    get_ai_model(Model),
    to_string(Context, ContextStr),
    to_string(SystemPrompt, SysStr),
    to_string(Model, ModelStr),
    %% Build JSON body as SWI dict
    Body = _{
        model: ModelStr,
        messages: [
            _{role: "system", content: SysStr},
            _{role: "user", content: ContextStr}
        ],
        max_tokens: 100,
        temperature: 0.3
    },
    %% Serialize to JSON atom (atom/2 is the most portable post form)
    with_output_to(atom(JsonAtom), json_write_dict(current_output, Body, [])),
    atom_length(JsonAtom, JsonLen),
    format(user_error, "[AI Oracle] Request to ~w (~w chars)~n", [Model, JsonLen]),
    %% Make HTTP request to OpenRouter
    atom_concat('Bearer ', ApiKey, AuthValue),
    setup_call_cleanup(
        http_open(
            'https://openrouter.ai/api/v1/chat/completions',
            ResponseStream,
            [
                request_header('Authorization' = AuthValue),
                request_header('Content-Type' = 'application/json'),
                post(atom('application/json', JsonAtom)),
                status_code(StatusCode),
                timeout(30)
            ]
        ),
        (   StatusCode =:= 200 ->
            json_read_dict(ResponseStream, ResponseDict),
            format(user_error, "[AI Oracle] Response received (status 200)~n", []),
            (extract_content(ResponseDict, ContentText) ->
                (parse_prolog_fact(ContentText, PrologFact) -> true
                ; PrologFact = raw_response(ContentText))
            ;
                throw(ai_error(empty_response))
            )
        ;
            read_string(ResponseStream, _, ErrorBody),
            format(user_error, "[AI Oracle] API status ~w: ~w~n", [StatusCode, ErrorBody]),
            throw(ai_error(api_status(StatusCode, ErrorBody)))
        ),
        close(ResponseStream)
    ).

%% Extract content string from API JSON response dict
extract_content(Dict, Content) :-
    get_dict(choices, Dict, Choices),
    Choices = [First|_],
    get_dict(message, First, Msg),
    get_dict(content, Msg, Content).

%% Parse the AI response string into a Prolog fact
parse_prolog_fact(ContentStr, PrologFact) :-
    %% Clean up the response - remove markdown, whitespace
    (atom(ContentStr) -> atom_string(ContentStr, Str) ; Str = ContentStr),
    %% Remove potential markdown code fences
    split_string(Str, "\n", " \t\r", Lines),
    exclude(is_fence_line, Lines, CleanLines),
    atomics_to_text(CleanLines, ' ', CleanStr),
    %% Try to parse as Prolog term
    catch(
        (term_string(PrologFact, CleanStr),
         PrologFact \= end_of_file),
        _ParseError,
        (   %% If parsing fails, try adding a period
            string_concat(CleanStr, ".", WithDot),
            catch(
                term_string(PrologFact, WithDot),
                _,
                (atom_string(FallbackAtom, CleanStr),
                 PrologFact = raw_response(FallbackAtom))
            )
        )
    ).

is_fence_line(Line) :-
    sub_string(Line, 0, _, _, "```").

atomics_to_text([], _, "").
atomics_to_text([H], _, H).
atomics_to_text([H|T], Sep, Result) :-
    atomics_to_text(T, Sep, Rest),
    string_concat(H, Sep, HSep),
    string_concat(HSep, Rest, Result).
