:- module(rlm_image,
          [ image_generate/3,
            image_generate_async/3,
            image_generate_execute/3,
            openai_image_provider/4,
            default_image_provider/1
          ]).

/** <module> Provider-neutral image generation runtime

Image generation is a first-class Prolog-RLM model operation rather than a
browser or prompt hack.  The canonical execution direction mirrors the text
runtime:

  image_generate_execute/3 -> async Future -> synchronous await wrapper

The initial transport is an OpenAI-compatible images endpoint.  Endpoints,
models, and credential references are data.  Secret values are resolved only
while executing a request and are not returned in outcomes.

The existing chain runtime already supports multimodal image *input*.  This
module adds image *output* generation.
*/

:- use_module(library(http/http_client)).
:- use_module(library(http/http_json)).
:- use_module(library(http/json)).
:- use_module(rlm_async).
:- use_module(rlm_openai_compatible,
              [ redact_secret/3,
                classify_provider_exception/2
              ]).

openai_image_provider(Endpoint, Credential, Model,
                      provider(openai_image,
                               [ endpoint(Endpoint),
                                 credential(Credential),
                                 model(Model),
                                 timeout(60)
                               ])).

default_image_provider(Provider) :-
    getenv('PROLOG_RLM_IMAGE_ENDPOINT', Endpoint),
    Endpoint \== '',
    getenv('PROLOG_RLM_IMAGE_MODEL', Model),
    Model \== '',
    !,
    openai_image_provider(Endpoint,
                          env('PROLOG_RLM_IMAGE_API_KEY'),
                          Model,
                          Provider).
default_image_provider(_) :-
    throw(image_fault(configuration,
                      "PROLOG_RLM_IMAGE_ENDPOINT and PROLOG_RLM_IMAGE_MODEL are required")).

image_generate_async(Provider, Request, Future) :-
    rlm_async_submit(rlm_image:image_generate_execute(Provider, Request),
                     async_metadata{operation:image_generate},
                     Future).

image_generate(Provider, Request, Outcome) :-
    image_generate_async(Provider, Request, Future),
    setup_call_cleanup(
        true,
        rlm_future_await(Future, Outcome),
        rlm_future_destroy(Future)).

image_generate_execute(Provider0, Request, Outcome) :-
    catch(image_generate_execute_(Provider0, Request, Outcome),
          Exception,
          image_exception(Exception, Outcome)).

image_generate_execute_(default, Request, Outcome) :-
    !,
    default_image_provider(Provider),
    image_generate_execute_(Provider, Request, Outcome).
image_generate_execute_(provider(openai_image, Config), Request, Outcome) :-
    !,
    image_provider_config(Config, ConfigOutcome),
    image_from_config(ConfigOutcome, Request, Outcome).
image_generate_execute_(Provider, _, error(Error)) :-
    Error = image_error{
                kind:configuration_error,
                provider:Provider,
                message:"image provider must be default or provider(openai_image, Config)"
            }.

image_provider_config(Config, Outcome) :-
    (   is_list(Config),
        memberchk(endpoint(Endpoint), Config),
        memberchk(credential(Credential), Config),
        memberchk(model(Model), Config),
        config_timeout(Config, Timeout),
        valid_endpoint(Endpoint),
        valid_credential(Credential),
        text_value(Model),
        number(Timeout),
        Timeout > 0
    ->  Outcome = ok(Endpoint, Credential, Model, Timeout)
    ;   Outcome = error(image_error{
                           kind:configuration_error,
                           message:"invalid OpenAI-compatible image provider configuration"
                       })
    ).

config_timeout(Config, Timeout) :-
    (   memberchk(timeout(Value), Config)
    ->  Timeout = Value
    ;   Timeout = 60
    ).

valid_endpoint(Endpoint) :-
    atom(Endpoint),
    (   sub_atom(Endpoint, 0, _, _, 'http://')
    ;   sub_atom(Endpoint, 0, _, _, 'https://')
    ).

valid_credential(none).
valid_credential(env(Name)) :-
    atom(Name),
    Name \== ''.

text_value(Value) :- atom(Value), !.
text_value(Value) :- string(Value).

image_from_config(error(Error), _, error(Error)) :-
    !.
image_from_config(ok(Endpoint, Credential, Model, Timeout), Request, Outcome) :-
    image_request_payload(Request, Model, PayloadOutcome),
    image_payload(PayloadOutcome,
                  Endpoint,
                  Credential,
                  Model,
                  Timeout,
                  Outcome).

image_request_payload(Request, Model, Outcome) :-
    (   is_dict(Request),
        get_dict(prompt, Request, Prompt0),
        normalize_text(Prompt0, Prompt),
        Prompt \== "",
        string_length(Prompt, PromptLength),
        PromptLength =< 16000,
        request_count(Request, Count),
        Count >= 1,
        Count =< 4
    ->  Base = _{model:Model, prompt:Prompt, n:Count},
        copy_image_options([size,
                            quality,
                            style,
                            background,
                            output_format,
                            response_format,
                            moderation],
                           Request,
                           Base,
                           Payload),
        Outcome = ok(Payload)
    ;   Outcome = error(image_error{
                           kind:validation_error,
                           message:"image request requires prompt text (<=16000 chars) and n between 1 and 4"
                       })
    ).

request_count(Request, Count) :-
    (   get_dict(n, Request, Candidate)
    ->  integer(Candidate),
        Count = Candidate
    ;   Count = 1
    ).

copy_image_options([], _, Payload, Payload).
copy_image_options([Key|Keys], Request, Payload0, Payload) :-
    (   get_dict(Key, Request, Value),
        ground(Value)
    ->  put_dict(Key, Payload0, Value, Payload1)
    ;   Payload1 = Payload0
    ),
    copy_image_options(Keys, Request, Payload1, Payload).

normalize_text(Value, Text) :-
    string(Value),
    !,
    Text = Value.
normalize_text(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
normalize_text(_, "").

image_payload(error(Error), _, _, _, _, error(Error)) :-
    !.
image_payload(ok(Payload), Endpoint, Credential, Model, Timeout, Outcome) :-
    resolve_image_credential(Credential, CredentialOutcome),
    image_http(CredentialOutcome,
               Endpoint,
               Model,
               Timeout,
               Payload,
               Outcome).

resolve_image_credential(none, ok(none)) :-
    !.
resolve_image_credential(env(Name), Outcome) :-
    (   getenv(Name, Value),
        Value \== ''
    ->  Outcome = ok(Value)
    ;   Outcome = error(image_error{
                           kind:credential_error,
                           credential:env(Name),
                           message:"image provider credential environment variable is unset"
                       })
    ).

image_http(error(Error), _, _, _, _, error(Error)) :-
    !.
image_http(ok(Key), Endpoint, Model, Timeout, Payload, Outcome) :-
    image_http_options(Key, Timeout, Status, Options),
    catch(http_post(Endpoint, json(Payload), Reply, Options),
          Exception,
          true),
    (   var(Exception)
    ->  normalize_image_response(Status, Model, Reply, Outcome)
    ;   classify_provider_exception(Exception, Kind),
        redact_secret(Exception, Key, SafeException),
        term_string(SafeException, SafeText,
                    [quoted(true), numbervars(true)]),
        Outcome = error(image_error{
                           kind:Kind,
                           exception:SafeText,
                           response_received:false,
                           message:"image provider request failed"
                       })
    ).

image_http_options(Key, Timeout, Status, Options) :-
    credential_options(Key, CredentialOptions),
    append(CredentialOptions,
           [ timeout(Timeout),
             status_code(Status),
             json_object(dict),
             request_header('Accept'='application/json'),
             user_agent('prolog-rlm-image/0.1')
           ],
           Options).

credential_options(none, []) :-
    !.
credential_options(Key, [authorization(bearer(Key))]).

normalize_image_response(Status, Model, Reply, Outcome) :-
    integer(Status),
    Status >= 200,
    Status < 300,
    is_dict(Reply),
    get_dict(data, Reply, Data),
    is_list(Data),
    !,
    maplist(normalize_image_item, Data, Images),
    response_usage(Reply, Usage),
    response_created(Reply, Created),
    Outcome = ok(image_result{
                     provider:openai_image,
                     model:Model,
                     created:Created,
                     images:Images,
                     usage:Usage
                 }).
normalize_image_response(Status, _, Reply, error(Error)) :-
    response_error_message(Reply, Message),
    Error = image_error{
                kind:provider_error,
                http_status:Status,
                response_received:true,
                message:Message
            }.

normalize_image_item(Item, Image) :-
    is_dict(Item),
    !,
    optional_image_field(url, Item, _{}, A),
    optional_image_field(b64_json, Item, A, B),
    optional_image_field(revised_prompt, Item, B, Image).
normalize_image_item(_, image{}).

optional_image_field(Key, Source, Target0, Target) :-
    (   get_dict(Key, Source, Value)
    ->  put_dict(Key, Target0, Value, Target)
    ;   Target = Target0
    ).

response_usage(Reply, Usage) :-
    (   get_dict(usage, Reply, Candidate),
        is_dict(Candidate)
    ->  Usage = Candidate
    ;   Usage = _{}
    ).

response_created(Reply, Created) :-
    (   get_dict(created, Reply, Candidate)
    ->  Created = Candidate
    ;   Created = null
    ).

response_error_message(Reply, Message) :-
    is_dict(Reply),
    get_dict(error, Reply, Error),
    is_dict(Error),
    get_dict(message, Error, Candidate),
    normalize_text(Candidate, Message),
    Message \== "",
    !.
response_error_message(_, "image provider returned an invalid or unsuccessful response").

image_exception(image_fault(Kind, Message), error(Error)) :-
    !,
    Error = image_error{kind:Kind, message:Message}.
image_exception(Exception, error(Error)) :-
    term_string(Exception, Text, [quoted(true), numbervars(true)]),
    Error = image_error{
                kind:runtime_error,
                exception:Text,
                message:"image generation failed"
            }.
