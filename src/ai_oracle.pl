%% ai_oracle.pl - AI Oracle integration for DALI2 via OpenRouter
%% Sends context to an LLM and receives a Prolog fact back.
%% The API key is read from the OPENROUTER_API_KEY environment variable.

:- module(ai_oracle, [
    ask_ai/2,           % ask_ai(+Context, -PrologFact)
    ask_ai/3,           % ask_ai(+Context, +SystemPrompt, -PrologFact)
    ask_ai_vision/3,    % ask_ai_vision(+ImagePath, +Prompt, -Result)
    ask_ai_vision/4,    % ask_ai_vision(+ImagePath, +Prompt, +SystemPrompt, -Result)
    ai_available/0,     % Check if AI oracle is configured
    vision_available/0,  % Check if vision LLM endpoint is configured
    set_ai_key/1,       % set_ai_key(+Key) - set API key at runtime
    set_ai_model/1,     % set_ai_model(+Model) - set model at runtime
    set_ai_endpoint/1,  % set_ai_endpoint(+URL) - set API endpoint
    set_vision_endpoint/1, % set_vision_endpoint(+URL) - set vision LLM endpoint
    set_vision_model/1, % set_vision_model(+Model) - set vision model
    get_ai_key/1,       % get_ai_key(-Key) - get current key (Redis first, then local)
    get_ai_model/1      % get_ai_model(-Model) - get current model (Redis first, then local)
]).

:- use_module(library(http/http_open)).
:- use_module(library(http/http_client)).
:- use_module(library(http/http_ssl_plugin)).   % Required for HTTPS
:- use_module(library(json)).
:- use_module(library(readutil)).
:- use_module(library(base64)).
:- use_module(redis_comm).

:- dynamic ai_api_key/1.
:- dynamic ai_model/1.
:- dynamic ai_endpoint/1.
:- dynamic vision_endpoint/1.
:- dynamic vision_model/1.

%% Default model (OpenRouter format — free tier)
ai_model('google/gemma-4-31b-it:free').

%% Default endpoint: OpenRouter (overridable for local LLMs like GPT4All)
ai_endpoint('https://openrouter.ai/api/v1/chat/completions').

%% Default vision endpoint: JAN local server (or any OpenAI-compatible API)
vision_endpoint('http://127.0.0.1:1337/v1/chat/completions').

%% Default vision model
vision_model('Qwen3.5-9B-GGUF').

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

%% set_ai_endpoint(+URL) - Set the text LLM API endpoint
set_ai_endpoint(URL) :-
    retractall(ai_endpoint(_)),
    assert(ai_endpoint(URL)),
    catch(redis_comm:redis_set_config('DALI2:ai_endpoint', URL), _, true).

%% set_vision_endpoint(+URL) - Set the vision LLM API endpoint
set_vision_endpoint(URL) :-
    retractall(vision_endpoint(_)),
    assert(vision_endpoint(URL)),
    catch(redis_comm:redis_set_config('DALI2:vision_endpoint', URL), _, true).

%% set_vision_model(+Model) - Set the vision LLM model
set_vision_model(Model) :-
    retractall(vision_model(_)),
    assert(vision_model(Model)),
    catch(redis_comm:redis_set_config('DALI2:vision_model', Model), _, true).

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

%% vision_available/0 - True if a vision LLM endpoint is configured
vision_available :-
    get_vision_endpoint(E),
    E \= ''.

get_vision_endpoint(E) :-
    (catch(redis_comm:redis_get_config('DALI2:vision_endpoint', V), _, fail) ->
        E = V
    ; vision_endpoint(E)
    ).

get_vision_model(M) :-
    (catch(redis_comm:redis_get_config('DALI2:vision_model', V), _, fail) ->
        M = V
    ; vision_model(M)
    ).

get_ai_endpoint(E) :-
    (catch(redis_comm:redis_get_config('DALI2:ai_endpoint', V), _, fail) ->
        E = V
    ; ai_endpoint(E)
    ).

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
    get_ai_endpoint(Endpoint),
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
    %% Make HTTP request
    atom_concat('Bearer ', ApiKey, AuthValue),
    setup_call_cleanup(
        http_open(
            Endpoint,
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

%% ============================================================
%% VISION LLM (image analysis via local or remote API)
%% ============================================================

%% ask_ai_vision(+ImagePath, +Prompt, -Result)
%% Reads an image file, base64-encodes it, sends to the vision LLM
%% endpoint (GPT4All or any OpenAI-compatible API) and returns
%% the model's response as a Prolog term.
ask_ai_vision(ImagePath, Prompt, Result) :-
    DefaultSys = "You are a vision module for a rescue robot. \
Analyse the image and respond with a single Prolog fact. \
If you see a victim (coloured cube: green=light, red=heavy), respond: \
victim_detected(Type). where Type is light or heavy. \
If the path is blocked by obstacles, respond: obstacle_ahead. \
If you see nothing notable, respond: clear_path. \
Do NOT include explanation, only the Prolog term.",
    ask_ai_vision(ImagePath, Prompt, DefaultSys, Result).

%% ask_ai_vision(+ImagePath, +Prompt, +SystemPrompt, -Result)
%% Full version with custom system prompt.
ask_ai_vision(ImagePath, Prompt, SystemPrompt, Result) :-
    (vision_available ->
        catch(
            ask_ai_vision_impl(ImagePath, Prompt, SystemPrompt, Result),
            Error,
            (format(user_error, "[AI Vision] Error: ~w~n", [Error]),
             throw(ai_error(Error)))
        )
    ;
        format(user_error, "[AI Vision] No vision endpoint configured~n", []),
        throw(ai_error(no_vision_endpoint))
    ).

ask_ai_vision_impl(ImagePath, Prompt, SystemPrompt, Result) :-
    get_vision_endpoint(Endpoint),
    get_vision_model(VModel),
    to_string(Prompt, PromptStr),
    to_string(SystemPrompt, SysStr),
    to_string(VModel, ModelStr),
    to_string(ImagePath, PathStr),
    %% Read image file and base64-encode it
    read_file_to_codes(PathStr, Bytes, [type(binary)]),
    phrase(base64(Bytes), Base64Codes),
    atom_codes(Base64Atom, Base64Codes),
    atom_concat('data:image/jpeg;base64,', Base64Atom, DataURI),
    %% Build the multimodal message
    TextPart = _{type: "text", text: PromptStr},
    ImagePart = _{type: "image_url", image_url: _{url: DataURI}},
    (SysStr \= "" ->
        Messages = [
            _{role: "system", content: SysStr},
            _{role: "user", content: [TextPart, ImagePart]}
        ]
    ;
        Messages = [
            _{role: "user", content: [TextPart, ImagePart]}
        ]
    ),
    Body = _{
        model: ModelStr,
        messages: Messages,
        max_tokens: 150,
        temperature: 0.3
    },
    with_output_to(atom(JsonAtom), json_write_dict(current_output, Body, [])),
    atom_length(JsonAtom, JsonLen),
    format(user_error, "[AI Vision] Request to ~w (image: ~w, ~w chars)~n",
           [Endpoint, PathStr, JsonLen]),
    %% HTTP request — vision endpoints typically don't need auth keys
    setup_call_cleanup(
        http_open(
            Endpoint,
            ResponseStream,
            [
                request_header('Content-Type' = 'application/json'),
                post(atom('application/json', JsonAtom)),
                status_code(StatusCode),
                timeout(60)
            ]
        ),
        (   StatusCode =:= 200 ->
            json_read_dict(ResponseStream, ResponseDict),
            format(user_error, "[AI Vision] Response received (status 200)~n", []),
            (extract_content(ResponseDict, ContentText) ->
                (parse_prolog_fact(ContentText, Result) -> true
                ; Result = raw_response(ContentText))
            ;
                throw(ai_error(empty_response))
            )
        ;
            read_string(ResponseStream, _, ErrorBody),
            format(user_error, "[AI Vision] API status ~w: ~w~n",
                   [StatusCode, ErrorBody]),
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
