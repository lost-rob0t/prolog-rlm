:- module(rlm_chain,
          [ rlm_chain_ready/0,
            model_complete/3,
            model_complete_async/3,
            model_stream/4,
            model_stream_async/4,
            chain_invoke/4,
            chain_invoke_async/4,
            chain_stream/5,
            chain_stream_async/5,
            model_complete_execute/3,
            model_stream_execute/4,
            chain_invoke_execute/4,
            chain_stream_execute/5,
            message_normalize/2,
            messages_normalize/2,
            prompt_compile/2,
            prompt_bind/3,
            structured_schema_compile/2,
            structured_validate/3,
            structured_decode_validate/3,
            default_retry_policy/1,
            openrouter_provider/2,
            openai_compatible_provider/4,
            default_openrouter_model/1,
            provider_capability/2,
            normalize_openai_chat_response/5
          ]).

/** <module> Provider-neutral model-chain runtime

Provider and chain execution follows one direction:

  canonical execute predicate -> asynchronous Future
                              -> synchronous await wrapper

The `*_execute` predicates are the internal execution ABI used by canonical
operations that already own an async worker. Public synchronous predicates never
contain provider/chain business logic; they start the same async operation and
wait for its Future. Public asynchronous predicates never call a synchronous
public wrapper.
*/

:- use_module(rlm_async).
:- use_module(rlm_chain_schema,
              [ message_normalize/2,
                messages_normalize/2,
                prompt_compile/2,
                prompt_bind/3,
                structured_schema_compile/2,
                structured_validate/3,
                structured_decode_validate/3
              ]).
:- use_module(rlm_chain_runtime,
              [ default_retry_policy/1,
                chain_invoke_with_transport/5,
                chain_stream_with_transport/6
              ]).
:- use_module(rlm_openai_compatible,
              [ openai_compatible_complete/4,
                openai_compatible_stream/5
              ]).

rlm_chain_ready.

%!  provider_capability(?Provider, ?Capability) is nondet.

provider_capability(openrouter, chat_completions).
provider_capability(openrouter, usage_metadata).
provider_capability(openrouter, tool_calls).
provider_capability(openrouter, streaming).
provider_capability(openrouter, multimodal_input).
provider_capability(openrouter, structured_output).
provider_capability(openai_compatible, chat_completions).
provider_capability(openai_compatible, tool_calls).
provider_capability(openai_compatible, streaming).
provider_capability(openai_compatible, multimodal_input).
provider_capability(openai_compatible, structured_output).

%!  default_openrouter_model(-Model) is det.
%
%   Resolve the live-test model at execution time. The repository variable may
%   override it; an unset or empty value defaults to `openrouter/free`.

default_openrouter_model(Model) :-
    (   getenv('OPENROUTER_TEST_MODEL', Candidate),
        Candidate \== '', Candidate \== ""
    ->  Model = Candidate
    ;   Model = 'openrouter/free'
    ).

%!  openrouter_provider(+ModelOrVar, -Provider) is det.
%
%   Construct an OpenRouter provider term without resolving the credential.

openrouter_provider(Model0,
                    provider(openrouter,
                             [ endpoint('https://openrouter.ai/api/v1/chat/completions'),
                               credential(env('OPENROUTER_API_KEY')),
                               model(Model),
                               timeout(30),
                               address_family(inet)
                             ])) :-
    (   var(Model0)
    ->  default_openrouter_model(Model)
    ;   Model = Model0
    ).

%!  openai_compatible_provider(+Endpoint, +Credential, +Model, -Provider) is det.
%
%   Configure another OpenAI-compatible chat-completions endpoint. Credential
%   must be `env(Name)` or `none`; resolved secrets are rejected by transport.

openai_compatible_provider(Endpoint, Credential, Model,
                           provider(openai_compatible,
                                    [ endpoint(Endpoint),
                                      credential(Credential),
                                      model(Model),
                                      timeout(30)
                                    ])).

/* Async/sync bridge ------------------------------------------------------ */

model_complete_async(Provider, Request, Future) :-
    rlm_async_submit(rlm_chain:model_complete_execute(Provider, Request),
                     async_metadata{operation:model_complete},
                     Future).

model_complete(Provider, Request, Outcome) :-
    model_complete_async(Provider, Request, Future),
    await_owned_future(Future, Outcome).

model_stream_async(Provider, Request, EventHandler, Future) :-
    rlm_async_submit(rlm_chain:model_stream_execute(Provider,
                                                    Request,
                                                    EventHandler),
                     async_metadata{operation:model_stream},
                     Future).

model_stream(Provider, Request, EventHandler, Outcome) :-
    model_stream_async(Provider, Request, EventHandler, Future),
    await_owned_future(Future, Outcome).

chain_invoke_async(ProviderSpec, Request, Options, Future) :-
    chain_task_metadata(chain_invoke, Options, Metadata),
    rlm_async_submit(rlm_chain:chain_invoke_execute(ProviderSpec,
                                                   Request,
                                                   Options),
                     Metadata,
                     Future).

chain_invoke(ProviderSpec, Request, Options, Outcome) :-
    chain_invoke_async(ProviderSpec, Request, Options, Future),
    await_owned_future(Future, Outcome).

chain_stream_async(ProviderSpec, Request, EventHandler, Options, Future) :-
    chain_task_metadata(chain_stream, Options, Metadata),
    rlm_async_submit(rlm_chain:chain_stream_execute(ProviderSpec,
                                                   Request,
                                                   Options,
                                                   EventHandler),
                     Metadata,
                     Future).

chain_stream(ProviderSpec, Request, Options, EventHandler, Outcome) :-
    chain_stream_async(ProviderSpec, Request, EventHandler, Options, Future),
    await_owned_future(Future, Outcome).

await_owned_future(Future, Outcome) :-
    setup_call_cleanup(
        true,
        rlm_future_await(Future, Outcome),
        rlm_future_destroy(Future)).

chain_task_metadata(Operation, Options, Metadata) :-
    metadata_fields(Options, TraceId, SessionId),
    Metadata = async_metadata{operation:Operation,
                              trace_id:TraceId,
                              session_id:SessionId}.

metadata_fields(Options, TraceId, SessionId) :-
    (   is_list(Options)
    ->  metadata_option(trace_id, Options, none, TraceId),
        metadata_option(session_id, Options, none, SessionId)
    ;   TraceId = none,
        SessionId = none
    ).

metadata_option(Name, Options, Default, Value) :-
    (   member(Option, Options),
        Option =.. [Name, Found],
        ground(Found)
    ->  Value = Found
    ;   Value = Default
    ).

/* Canonical execution ABI ------------------------------------------------ */

%!  model_complete_execute(+Provider, +Request, -Outcome) is det.
%
%   Execute one provider request. This is the canonical implementation used by
%   the async task and by larger canonical operations already running in an
%   async worker. It is not a synchronous facade.
%
%   `provider_context(Messages, Provider)` is a trusted host/runtime wrapper.
%   It projects already-compiled provider-visible system context onto a request
%   before delegating to the underlying provider. Model-produced request data
%   never chooses this wrapper.

model_complete_execute(provider_context(Messages, Provider), Request0, Outcome) :-
    !,
    (   provider_context_request(Messages, Request0, Request)
    ->  model_complete_execute(Provider, Request, Outcome)
    ;   Outcome = error(provider_error{
                            provider:provider_context,
                            kind:configuration_error,
                            message:"provider context must be ground system messages and a request message list"
                        })
    ).
model_complete_execute(provider(Provider, Config), Request, Outcome) :-
    !,
    dispatch_provider(Provider, Config, Request, Outcome).
model_complete_execute(Provider, _,
                       error(provider_error{provider:Provider,
                                            kind:configuration_error,
                                            message:"provider must be provider(Name, Config)"})).

provider_context_request([], Request, Request) :-
    is_dict(Request),
    get_dict(messages, Request, Messages),
    is_list(Messages),
    !.
provider_context_request(Prefix, Request0, Request) :-
    ground(Prefix),
    is_list(Prefix),
    Prefix \== [],
    maplist(provider_context_system_message, Prefix),
    is_dict(Request0),
    get_dict(messages, Request0, Messages0),
    is_list(Messages0),
    append(Prefix, Messages0, Messages),
    put_dict(messages, Request0, Messages, Request).

provider_context_system_message(Message) :-
    is_dict(Message),
    get_dict(role, Message, system),
    get_dict(content, Message, Content),
    (string(Content) ; atom(Content)).

dispatch_provider(openrouter, Config, Request, Outcome) :-
    !,
    dispatch_openai_compatible_complete(openrouter, Config, Request, Outcome).
dispatch_provider(openai_compatible, Config, Request, Outcome) :-
    !,
    dispatch_openai_compatible_complete(openai_compatible,
                                        Config,
                                        Request,
                                        Outcome).
dispatch_provider(Provider, _, _,
                  error(provider_error{provider:Provider,
                                       kind:capability_denied,
                                       capability:chat_completions,
                                       message:"provider does not implement chat completions"})).

dispatch_openai_compatible_complete(Provider, Config, Request0, Outcome) :-
    normalize_provider_request(Provider, Config, Request0, Normalization),
    complete_normalized_request(Normalization, Provider, Config, Outcome).

complete_normalized_request(error(Error), _, _, error(Error)) :-
    !.
complete_normalized_request(ok(Request), Provider, Config, Outcome) :-
    rlm_openai_compatible:openai_compatible_complete(Provider,
                                                     Config,
                                                     Request,
                                                     Outcome).

%!  model_stream_execute(+Provider, +Request, +EventHandler, -Outcome) is det.
%
%   Execute a true provider stream. The handler is called incrementally as SSE
%   data arrives; the asynchronous surface therefore remains responsive and does
%   not buffer an entire synchronous stream before returning events.

model_stream_execute(provider(Provider, Config), Request, EventHandler, Outcome) :-
    !,
    dispatch_stream_provider(Provider, Config, Request, EventHandler, Outcome).
model_stream_execute(Provider, _, _,
                     error(provider_error{provider:Provider,
                                          kind:configuration_error,
                                          message:"provider must be provider(Name, Config)"})).

dispatch_stream_provider(openrouter, Config, Request, EventHandler, Outcome) :-
    !,
    dispatch_openai_compatible_stream(openrouter,
                                      Config,
                                      Request,
                                      EventHandler,
                                      Outcome).
dispatch_stream_provider(openai_compatible, Config, Request, EventHandler,
                         Outcome) :-
    !,
    dispatch_openai_compatible_stream(openai_compatible,
                                      Config,
                                      Request,
                                      EventHandler,
                                      Outcome).
dispatch_stream_provider(Provider, _, _, _,
                         error(provider_error{provider:Provider,
                                              kind:capability_denied,
                                              capability:streaming,
                                              message:"provider does not implement streaming"})).

dispatch_openai_compatible_stream(Provider,
                                  Config,
                                  Request0,
                                  EventHandler,
                                  Outcome) :-
    normalize_provider_request(Provider, Config, Request0, Normalization),
    stream_normalized_request(Normalization,
                              Provider,
                              Config,
                              EventHandler,
                              Outcome).

stream_normalized_request(error(Error), _, _, _, error(Error)) :-
    !.
stream_normalized_request(ok(Request), Provider, Config, EventHandler,
                          Outcome) :-
    rlm_openai_compatible:openai_compatible_stream(Provider,
                                                   Config,
                                                   Request,
                                                   EventHandler,
                                                   Outcome).

/* Provider/model request compatibility ---------------------------------- */

%!  normalize_provider_request(+Provider,+Config,+Request,-Outcome) is det.
%
%   Apply trusted provider/model request restrictions before network dispatch.
%   `tool_choice_modes/1` belongs to host-owned provider configuration; request
%   data cannot select or widen it. Absence preserves historical behavior.
%
%   A provider restricted to `auto` may repair a simple `required` request to
%   `auto`. Other unsupported modes, including a specific-function selector,
%   fail explicitly rather than silently weakening the caller's intent.

normalize_provider_request(Provider, Config, Request0, Outcome) :-
    provider_tool_choice_modes(Provider, Config, ModesOutcome),
    normalize_provider_request_modes(ModesOutcome,
                                     Provider,
                                     Request0,
                                     Outcome).

provider_tool_choice_modes(_, Config, ok(all)) :-
    \+ is_list(Config),
    !.
provider_tool_choice_modes(Provider, Config, Outcome) :-
    findall(Entry,
            ( member(Entry, Config),
              nonvar(Entry),
              functor(Entry, tool_choice_modes, _)
            ),
            Entries),
    tool_choice_modes_entries(Entries, Provider, Outcome).

tool_choice_modes_entries([], _, ok(all)) :-
    !.
tool_choice_modes_entries([tool_choice_modes(Modes)], Provider, Outcome) :-
    !,
    validate_tool_choice_modes(Modes, Provider, Outcome).
tool_choice_modes_entries(_, Provider, error(Error)) :-
    tool_choice_modes_config_error(Provider,
                                   "tool_choice_modes must appear once with one argument",
                                   Error).

validate_tool_choice_modes(Modes, _, ok(Normalized)) :-
    is_list(Modes),
    Modes \== [],
    ground(Modes),
    maplist(valid_tool_choice_mode, Modes),
    sort(Modes, Normalized),
    length(Modes, Count),
    length(Normalized, Count),
    !.
validate_tool_choice_modes(_, Provider, error(Error)) :-
    tool_choice_modes_config_error(Provider,
                                   "tool_choice_modes must be a non-empty unique list of none, auto, and required",
                                   Error).

valid_tool_choice_mode(none).
valid_tool_choice_mode(auto).
valid_tool_choice_mode(required).

tool_choice_modes_config_error(Provider, Message,
                               provider_error{provider:Provider,
                                              kind:configuration_error,
                                              field:tool_choice_modes,
                                              message:Message,
                                              response_received:false}).

normalize_provider_request_modes(error(Error), _, _, error(Error)) :-
    !.
normalize_provider_request_modes(ok(all), _, Request, ok(Request)) :-
    !.
normalize_provider_request_modes(ok(Modes), Provider, Request0, Outcome) :-
    (   request_tool_choice(Request0, Requested)
    ->  normalize_tool_choice(Requested, Modes, Provider, Request0, Outcome)
    ;   Outcome = ok(Request0)
    ).

request_tool_choice(Request, ToolChoice) :-
    is_dict(Request),
    get_dict(options, Request, Options),
    is_dict(Options),
    get_dict(tool_choice, Options, ToolChoice).

normalize_tool_choice(Requested, Modes, _, Request, ok(Request)) :-
    simple_tool_choice_mode(Requested, Mode),
    memberchk(Mode, Modes),
    !.
normalize_tool_choice(Requested, Modes, _, Request0, ok(Request)) :-
    simple_tool_choice_mode(Requested, required),
    memberchk(auto, Modes),
    !,
    get_dict(options, Request0, Options0),
    put_dict(tool_choice, Options0, auto, Options),
    put_dict(options, Request0, Options, Request).
normalize_tool_choice(Requested, Modes, Provider, _, error(Error)) :-
    Error = provider_error{provider:Provider,
                           kind:capability_denied,
                           capability:tool_choice,
                           requested:Requested,
                           supported:Modes,
                           message:"requested tool_choice is not legal for the configured provider/model profile",
                           response_received:false}.

simple_tool_choice_mode(Value, Value) :-
    atom(Value),
    memberchk(Value, [none, auto, required]),
    !.
simple_tool_choice_mode(Value, Mode) :-
    string(Value),
    atom_string(Mode, Value),
    memberchk(Mode, [none, auto, required]).

%!  chain_invoke_execute(+ProviderSpec, +Request, +Options, -Outcome) is det.
%
%   Canonical chain execution. Retry/backoff, structured repair and middleware
%   run exactly once here. Provider effects use model_complete_execute/3 rather
%   than re-entering the public synchronous facade.

chain_invoke_execute(ProviderSpec, Request0, Options, Outcome) :-
    canonical_runtime_request(Request0, Request),
    rlm_chain_runtime:chain_invoke_with_transport(ProviderSpec,
                                                  Request,
                                                  Options,
                                                  rlm_chain:model_complete_execute,
                                                  Outcome).

%!  chain_stream_execute(+ProviderSpec,+Request,+Options,+EventHandler,-Outcome)
%
%   Canonical incremental chain streaming path.

chain_stream_execute(ProviderSpec, Request0, Options, EventHandler, Outcome) :-
    canonical_runtime_request(Request0, Request),
    rlm_chain_runtime:chain_stream_with_transport(ProviderSpec,
                                                  Request,
                                                  Options,
                                                  rlm_chain:model_stream_execute,
                                                  EventHandler,
                                                  Outcome).

/* Canonicalize anonymous dict tags in generation options.  SWI's `_{}' and
   `_{...}' syntax intentionally creates an anonymous tag variable.  The chain
   runtime requires request values to be ground for deterministic traces, so the
   public facade replaces only these representation-level tags while preserving
   all option keys and values.  Truly non-ground option values remain non-ground
   and are still rejected by the runtime. */

canonical_runtime_request(Request0, Request) :-
    (   is_dict(Request0),
        get_dict(options, Request0, Options0),
        is_dict(Options0)
    ->  canonical_option_value(Options0, Options),
        put_dict(options, Request0, Options, Request)
    ;   Request = Request0
    ).

canonical_option_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_option_pair, Pairs0, Pairs),
    dict_pairs(Value, chain_options, Pairs).
canonical_option_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_option_value, Values0, Values).
canonical_option_value(Value, Value).

canonical_option_pair(Key-Value0, Key-Value) :-
    canonical_option_value(Value0, Value).

normalize_openai_chat_response(Provider, RequestedModel, HttpInfo, Raw,
                               Outcome) :-
    rlm_openai_compatible:normalize_openai_chat_response(Provider,
                                                         RequestedModel,
                                                         HttpInfo,
                                                         Raw,
                                                         Outcome).
