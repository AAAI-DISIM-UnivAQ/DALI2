%% ai_oracle.pl - OpenAI/ChatGPT integration for DALI2
%% Sends context to ChatGPT and receives a Prolog fact back.
%% The API key is read from the OPENAI_API_KEY environment variable.

:- module(ai_oracle, [
    ask_ai/2,           % ask_ai(+Context, -PrologFact)
    ask_ai/3,           % ask_ai(+Context, +SystemPrompt, -PrologFact)
    ai_available/0,     % Check if AI oracle is configured
    set_ai_key/1,       % set_ai_key(+Key) - set API key at runtime
    set_ai_model/1      % set_ai_model(+Model) - set model at runtime
]).

:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/json)).
:- use_module(library(readutil)).

:- dynamic ai_api_key/1.
:- dynamic ai_model/1.

%% Default model
ai_model('gpt-4o-mini').

%% ============================================================
%% CONFIGURATION
%% ============================================================

%% Initialize API key from environment variable
:- (getenv('OPENAI_API_KEY', Key), Key \= '' ->
        assert(ai_api_key(Key))
    ; true).

%% set_ai_key(+Key) - Set or update the API key at runtime
set_ai_key(Key) :-
    retractall(ai_api_key(_)),
    assert(ai_api_key(Key)).

%% set_ai_model(+Model) - Set or update the model
set_ai_model(Model) :-
    retractall(ai_model(_)),
    assert(ai_model(Model)).

%% ai_available/0 - True if an API key is configured
ai_available :-
    ai_api_key(Key),
    Key \= ''.

%% ============================================================
%% MAIN PREDICATES
%% ============================================================

%% ask_ai(+Context, -PrologFact)
%% Sends context to ChatGPT with a default system prompt that asks
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
             PrologFact = error(api_failure))
        )
    ;
        format(user_error, "[AI Oracle] No API key configured, returning default~n", []),
        PrologFact = suggestion(no_ai_available)
    ).

%% ============================================================
%% IMPLEMENTATION
%% ============================================================

to_string(Term, Str) :-
    (string(Term) -> Str = Term ;
     atom(Term) -> atom_string(Term, Str) ;
     term_to_atom(Term, A), atom_string(A, Str)).

ask_ai_impl(Context, SystemPrompt, PrologFact) :-
    ai_api_key(ApiKey),
    ai_model(Model),
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
    %% Serialize to JSON string
    with_output_to(string(JsonStr), json_write_dict(current_output, Body, [])),
    %% Make HTTP request to OpenAI
    atom_concat('Bearer ', ApiKey, AuthValue),
    setup_call_cleanup(
        http_open(
            'https://api.openai.com/v1/chat/completions',
            ResponseStream,
            [
                method(post),
                request_header('Authorization' = AuthValue),
                post(string('application/json', JsonStr)),
                status_code(StatusCode)
            ]
        ),
        (   StatusCode =:= 200 ->
            json_read_dict(ResponseStream, ResponseDict),
            extract_content(ResponseDict, ContentText),
            parse_prolog_fact(ContentText, PrologFact)
        ;
            read_string(ResponseStream, _, ErrorBody),
            format(user_error, "[AI Oracle] API returned status ~w: ~w~n", [StatusCode, ErrorBody]),
            PrologFact = error(api_status(StatusCode))
        ),
        close(ResponseStream)
    ).

%% Extract content string from OpenAI JSON response dict
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
