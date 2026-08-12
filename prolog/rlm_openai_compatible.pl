:- module(rlm_openai_compatible,
          [ openai_compatible_complete/4,
            normalize_openai_chat_response/5,
            redact_secret/3,
            classify_provider_exception/2
          ]).

/** <module> OpenAI-compatible HTTP transport

Production HTTPS transport and response normalization for OpenAI-compatible
chat-completions providers. Credentials are resolved only while executing a
request and are never returned in provider terms, results, errors, or traces.
*/

:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/http_ssl_plugin)).
:- use_module(library(lists)).

%!  openai_compatible_complete(+Provider, +Config, +Request, -Outcome) is det.
%
%   Execute one real OpenAI-compatible chat-completions request. Outcome is
%   either ok(ModelResponse) or error(ProviderError). There is deliberately no
%   fallback provider path here.

openai_compatible_complete(Provider, Config, Request, Outcome) :-
    config_value(model, Config, none, RequestedModel),
    (   RequestedModel == none
    ->  Outcome = error(provider_error{provider:Provider,
                                       kind:configuration_error,
                                       field:model,
                                       message:"provider model is not configured"})
    ;   config_value(endpoint, Config, none, Endpoint),
        (   Endpoint == none
        ->  Outcome = error(provider_error{provider:Provider,
                                           kind:configuration_error,
                                           field:endpoint,
                                           message:"provider endpoint is not configured"})
        ;   config_value(credential, Config, none, Credential),
            resolve_credential(Provider, Credential, CredentialOutcome),
            execute_with_credential(CredentialOutcome,
                                    Provider,
                                    Config,
                                    Endpoint,
                                    RequestedModel,
                                    Request,
                                    Outcome)
        )
    ).

execute_with_credential(error(Error), _, _, _, _, _, error(Error)) :-
    !.
execute_with_credential(ok(Key), Provider, Config, Endpoint, RequestedModel,
                        Request, Outcome) :-
    request_payload(Request, RequestedModel, PayloadOutcome),
    execute_payload(PayloadOutcome,
                    Key,
                    Provider,
                    Config,
                    Endpoint,
                    RequestedModel,
                    Outcome).

execute_payload(error(Error), _, _, _, _, _, error(Error)) :-
    !.
execute_payload(ok(Payload), Key, Provider, Config, Endpoint, RequestedModel,
                Outcome) :-
    config_value(timeout, Config, 30, Timeout),
    http_options(Key, Timeout, HttpOptions),
    catch(http_post(Endpoint, json(Payload), Reply, HttpOptions),
          Exception,
          true),
    (   var(Exception)
    ->  normalize_openai_chat_response(Provider,
                                       RequestedModel,
                                       HttpOptions,
                                       Reply,
                                       Outcome)
    ;   classify_provider_exception(Exception, Kind),
        redact_secret(Exception, Key, SafeException),
        Outcome = error(provider_error{provider:Provider,
                                       kind:Kind,
                                       exception:SafeException,
                                       response_received:false})
    ).

http_options(none, Timeout,
             [ timeout(Timeout),
               status_code(_),
               json_object(dict),
               request_header('Accept'='application/json'),
               user_agent('prolog-rlm/0.1')
             ]).
http_options(Key, Timeout,
             [ authorization(bearer(Key)),
               timeout(Timeout),
               status_code(_),
               json_object(dict),
               request_header('Accept'='application/json'),
               user_agent('prolog-rlm/0.1')
             ]) :-
    Key \== none.

%!  normalize_openai_chat_response(+Provider, +RequestedModel, +HttpInfo,
%!                                  +Raw, -Outcome) is det.
%
%   Normalize an OpenAI-compatible response. HttpInfo may be an integer status
%   code (for deterministic conformance tests) or the actual HTTP option list
%   carrying status_code(Status).

normalize_openai_chat_response(Provider, RequestedModel, HttpInfo, Raw,
                               Outcome) :-
    http_status(HttpInfo, Status),
    (   integer(Status), Status >= 200, Status < 300
    ->  normalize_success_response(Provider,
                                   RequestedModel,
                                   Status,
                                   Raw,
                                   Outcome)
    ;   normalize_http_error(Provider, Status, Raw, Outcome)
    ).

http_status(Status, Status) :-
    integer(Status),
    !.
http_status(Options, Status) :-
    memberchk(status_code(Status), Options),
    !.
http_status(_, unknown).

normalize_success_response(Provider, RequestedModel, Status, Raw, Outcome) :-
    (   \+ is_dict(Raw)
    ->  Outcome = error(provider_error{provider:Provider,
                                       kind:invalid_response,
                                       http_status:Status,
                                       message:"provider response is not a JSON object",
                                       response_received:true})
    ;   get_dict(error, Raw, TopError),
        TopError \== null
    ->  provider_error_from_wire(Provider, Status, TopError, Outcome)
    ;   get_dict(choices, Raw, Choices),
        Choices = [Choice|_],
        is_dict(Choice),
        get_dict(message, Choice, Message),
        is_dict(Message)
    ->  normalize_choice(Provider,
                         RequestedModel,
                         Status,
                         Raw,
                         Choice,
                         Message,
                         Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:invalid_response,
                                       http_status:Status,
                                       message:"provider response has no assistant choice",
                                       response_received:true})
    ).

normalize_choice(Provider, RequestedModel, Status, Raw, Choice, Message,
                 Outcome) :-
    (   get_dict(error, Choice, ChoiceError),
        ChoiceError \== null
    ->  provider_error_from_wire(Provider, Status, ChoiceError, Outcome)
    ;   dict_default(content, Message, null, Content0),
        normalize_content(Content0, Text),
        dict_default(tool_calls, Message, [], ToolCalls0),
        normalize_tool_calls(ToolCalls0, ToolCalls),
        (   Text == "", ToolCalls == []
        ->  Outcome = error(provider_error{provider:Provider,
                                           kind:invalid_response,
                                           http_status:Status,
                                           message:"assistant choice contains no content or tool calls",
                                           response_received:true})
        ;   dict_default(role, Message, assistant, Role),
            dict_default(finish_reason, Choice, null, FinishReason),
            dict_default(model, Raw, RequestedModel, SelectedModel),
            normalize_usage(Raw, Usage),
            dict_default(id, Raw, null, ResponseId),
            Assistant = message{role:Role,
                                content:Text,
                                tool_calls:ToolCalls},
            Metadata = provider_metadata{provider:Provider,
                                         http_status:Status,
                                         response_received:true},
            Response = model_response{provider:Provider,
                                      requested_model:RequestedModel,
                                      selected_model:SelectedModel,
                                      response_id:ResponseId,
                                      assistant:Assistant,
                                      text:Text,
                                      tool_calls:ToolCalls,
                                      finish_reason:FinishReason,
                                      usage:Usage,
                                      metadata:Metadata},
            Outcome = ok(Response)
        )
    ).

normalize_http_error(Provider, Status, Raw, Outcome) :-
    (   is_dict(Raw),
        get_dict(error, Raw, WireError)
    ->  provider_error_from_wire(Provider, Status, WireError, Outcome)
    ;   Outcome = error(provider_error{provider:Provider,
                                       kind:http_error,
                                       http_status:Status,
                                       message:"provider returned a non-success HTTP response",
                                       response_received:true})
    ).

provider_error_from_wire(Provider, Status, WireError, error(Error)) :-
    wire_error_fields(WireError, Code, Message, ErrorType),
    Error = provider_error{provider:Provider,
                           kind:provider_error,
                           http_status:Status,
                           code:Code,
                           error_type:ErrorType,
                           message:Message,
                           response_received:true}.

wire_error_fields(WireError, Code, Message, ErrorType) :-
    (   is_dict(WireError)
    ->  dict_default(code, WireError, null, Code),
        dict_default(message, WireError, "provider returned an error", Message0),
        normalize_content(Message0, Message),
        wire_error_type(WireError, ErrorType)
    ;   Code = null,
        normalize_content(WireError, Message),
        ErrorType = null
    ).

wire_error_type(WireError, ErrorType) :-
    (   get_dict(metadata, WireError, Metadata),
        is_dict(Metadata),
        get_dict(error_type, Metadata, ErrorType0)
    ->  ErrorType = ErrorType0
    ;   ErrorType = null
    ).

normalize_usage(Raw, Usage) :-
    (   get_dict(usage, Raw, RawUsage),
        is_dict(RawUsage)
    ->  dict_default(prompt_tokens, RawUsage, null, PromptTokens),
        dict_default(completion_tokens, RawUsage, null, CompletionTokens),
        dict_default(total_tokens, RawUsage, null, TotalTokens),
        dict_default(cost, RawUsage, null, Cost),
        Usage = usage{present:true,
                      prompt_tokens:PromptTokens,
                      completion_tokens:CompletionTokens,
                      total_tokens:TotalTokens,
                      cost:Cost}
    ;   Usage = usage{present:false,
                      prompt_tokens:null,
                      completion_tokens:null,
                      total_tokens:null,
                      cost:null}
    ).

normalize_tool_calls(ToolCalls, ToolCalls) :-
    is_list(ToolCalls),
    !.
normalize_tool_calls(_, []).

normalize_content(null, "") :-
    !.
normalize_content(Content, Content) :-
    string(Content),
    !.
normalize_content(Content, String) :-
    atom(Content),
    !,
    atom_string(Content, String).
normalize_content(Content, String) :-
    term_string(Content, String, [quoted(true), numbervars(true)]).

request_payload(Request, RequestedModel, Outcome) :-
    validate_request(Request, Validation),
    (   Validation = error(Error)
    ->  Outcome = error(Error)
    ;   Request = model_request{messages:Messages0},
        maplist(message_payload, Messages0, Messages),
        request_options(Request, RequestOptions),
        allowed_generation_options(RequestOptions, GenerationOptions),
        put_dict(_{model:RequestedModel,
                   messages:Messages},
                 GenerationOptions,
                 Payload),
        Outcome = ok(Payload)
    ).

validate_request(Request, error(provider_error{provider:client,
                                                kind:validation_error,
                                                field:request,
                                                message:"model request must be a model_request dict"})) :-
    (   \+ is_dict(Request)
    ;   dict_tag(Request, Tag), Tag \== model_request
    ),
    !.
validate_request(Request, error(provider_error{provider:client,
                                                kind:validation_error,
                                                field:messages,
                                                message:"model request requires a non-empty messages list"})) :-
    (   \+ get_dict(messages, Request, Messages)
    ;   \+ is_list(Messages)
    ;   Messages == []
    ),
    !.
validate_request(Request, error(provider_error{provider:client,
                                                kind:validation_error,
                                                field:messages,
                                                message:"every message requires a supported role and content"})) :-
    get_dict(messages, Request, Messages),
    \+ maplist(valid_message, Messages),
    !.
validate_request(_, ok).

valid_message(Message) :-
    is_dict(Message),
    get_dict(role, Message, Role),
    memberchk(Role, [system, user, assistant, tool]),
    get_dict(content, Message, Content),
    valid_message_content(Content).

valid_message_content(Content) :-
    string(Content),
    !.
valid_message_content(Content) :-
    atom(Content),
    !.
valid_message_content(Content) :-
    is_list(Content).

message_payload(Message, Payload) :-
    get_dict(role, Message, Role),
    get_dict(content, Message, Content),
    Base = _{role:Role, content:Content},
    copy_optional_message_fields([name, tool_call_id, tool_calls],
                                 Message,
                                 Base,
                                 Payload).

copy_optional_message_fields([], _, Payload, Payload).
copy_optional_message_fields([Key|Keys], Message, Payload0, Payload) :-
    (   get_dict(Key, Message, Value)
    ->  put_dict(Key, Payload0, Value, Payload1)
    ;   Payload1 = Payload0
    ),
    copy_optional_message_fields(Keys, Message, Payload1, Payload).

request_options(Request, Options) :-
    (   get_dict(options, Request, Candidate), is_dict(Candidate)
    ->  Options = Candidate
    ;   Options = _{}
    ).

allowed_generation_options(Options, Allowed) :-
    AllowedKeys = [max_tokens,
                   max_completion_tokens,
                   temperature,
                   top_p,
                   seed,
                   stop,
                   tools,
                   tool_choice,
                   response_format],
    include_present_keys(AllowedKeys, Options, _{}, Allowed).

include_present_keys([], _, Allowed, Allowed).
include_present_keys([Key|Keys], Source, Allowed0, Allowed) :-
    (   get_dict(Key, Source, Value)
    ->  put_dict(Key, Allowed0, Value, Allowed1)
    ;   Allowed1 = Allowed0
    ),
    include_present_keys(Keys, Source, Allowed1, Allowed).

resolve_credential(_, none, ok(none)) :-
    !.
resolve_credential(Provider, env(Name), Outcome) :-
    !,
    (   getenv(Name, Key), Key \== ''
    ->  Outcome = ok(Key)
    ;   format(string(Message), "credential environment variable ~w is not configured", [Name]),
        Outcome = error(provider_error{provider:Provider,
                                       kind:missing_credential,
                                       credential:env(Name),
                                       message:Message,
                                       response_received:false})
    ).
resolve_credential(Provider, _,
                   error(provider_error{provider:Provider,
                                        kind:configuration_error,
                                        field:credential,
                                        message:"credentials must use env(Name) or none",
                                        response_received:false})).

config_value(Key, Config, Default, Value) :-
    (   memberchk(Entry, Config),
        Entry =.. [Key, Found]
    ->  Value = Found
    ;   Value = Default
    ).

dict_default(Key, Dict, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

%!  classify_provider_exception(+Exception, -Kind) is det.

classify_provider_exception(Exception, timeout) :-
    term_string(Exception, Text),
    string_lower(Text, Lower),
    (   sub_string(Lower, _, _, _, "timeout")
    ;   sub_string(Lower, _, _, _, "timed out")
    ),
    !.
classify_provider_exception(_, transport_error).

%!  redact_secret(+Term, +Secret, -SafeTerm) is det.
%
%   Recursively redact occurrences of Secret from atomic exception material.

redact_secret(Term, Secret, Safe) :-
    (   var(Term)
    ->  Safe = Term
    ;   is_dict(Term)
    ->  dict_pairs(Term, Tag, Pairs0),
        maplist(redact_pair(Secret), Pairs0, Pairs),
        dict_pairs(Safe, Tag, Pairs)
    ;   string(Term)
    ->  redact_string(Term, Secret, Safe)
    ;   atom(Term)
    ->  atom_string(Term, Text),
        redact_string(Text, Secret, SafeText),
        atom_string(Safe, SafeText)
    ;   atomic(Term)
    ->  Safe = Term
    ;   Term =.. [Functor|Args0],
        maplist(redact_secret_arg(Secret), Args0, Args),
        Safe =.. [Functor|Args]
    ).

redact_pair(Secret, Key-Value0, Key-Value) :-
    redact_secret(Value0, Secret, Value).

redact_secret_arg(Secret, Value0, Value) :-
    redact_secret(Value0, Secret, Value).

redact_string(Text, none, Text) :-
    !.
redact_string(Text, Secret0, Safe) :-
    secret_string(Secret0, Secret),
    (   Secret == ""
    ->  Safe = Text
    ;   replace_all(Text, Secret, "<redacted>", Safe)
    ).

secret_string(Secret, Secret) :-
    string(Secret),
    !.
secret_string(Secret, Text) :-
    atom(Secret),
    !,
    atom_string(Secret, Text).
secret_string(Secret, Text) :-
    term_string(Secret, Text).

replace_all(Text, Needle, Replacement, Safe) :-
    (   sub_string(Text, Before, Length, After, Needle)
    ->  sub_string(Text, 0, Before, _, Prefix),
        Start is Before + Length,
        sub_string(Text, Start, After, 0, Suffix),
        string_concat(Prefix, Replacement, Left),
        replace_all(Suffix, Needle, Replacement, Right),
        string_concat(Left, Right, Safe)
    ;   Safe = Text
    ).
