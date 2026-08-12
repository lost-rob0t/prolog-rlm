:- module(rlm_chain,
          [ rlm_chain_ready/0,
            model_complete/3,
            model_stream/4,
            chain_invoke/4,
            chain_stream/5,
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

`rlm_chain` owns the canonical public model abstraction.  The low-level
`model_complete/3` predicate remains backward compatible, while `chain_invoke/4`
and `chain_stream/5` add provider routing, middleware, bounded retry policy,
structured output validation, canonical usage and ordered tracing.

Production providers use explicit configuration terms and return structured
`ok/1` or `error/1` outcomes.  Deterministic fake providers remain test-only
and are never fallback targets.
*/

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
                openai_compatible_stream/5,
                normalize_openai_chat_response/5
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
                               timeout(30)
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

%!  model_complete(+Provider, +Request, -Outcome) is det.
%
%   Execute one provider request. Outcome is `ok(ModelResponse)` or
%   `error(ProviderError)`. Unknown providers and malformed provider terms fail
%   structurally rather than raising raw provider/network exceptions.
%
%   This predicate is the compatibility surface used by pre-#13 callers.

model_complete(provider(Provider, Config), Request, Outcome) :-
    !,
    dispatch_provider(Provider, Config, Request, Outcome).
model_complete(Provider, _,
               error(provider_error{provider:Provider,
                                    kind:configuration_error,
                                    message:"provider must be provider(Name, Config)"})).

dispatch_provider(openrouter, Config, Request, Outcome) :-
    !,
    rlm_openai_compatible:openai_compatible_complete(openrouter,
                                                     Config,
                                                     Request,
                                                     Outcome).
dispatch_provider(openai_compatible, Config, Request, Outcome) :-
    !,
    rlm_openai_compatible:openai_compatible_complete(openai_compatible,
                                                     Config,
                                                     Request,
                                                     Outcome).
dispatch_provider(Provider, _, _,
                  error(provider_error{provider:Provider,
                                       kind:capability_denied,
                                       capability:chat_completions,
                                       message:"provider does not implement chat completions"})).

%!  model_stream(+Provider, +Request, +EventHandler, -Outcome) is det.
%
%   Execute one true provider stream. `EventHandler` is called incrementally for
%   each normalized stream event before the final response is available.

model_stream(provider(Provider, Config), Request, EventHandler, Outcome) :-
    !,
    dispatch_stream_provider(Provider, Config, Request, EventHandler, Outcome).
model_stream(Provider, _, _,
             error(provider_error{provider:Provider,
                                  kind:configuration_error,
                                  message:"provider must be provider(Name, Config)"})).

dispatch_stream_provider(openrouter, Config, Request, EventHandler, Outcome) :-
    !,
    rlm_openai_compatible:openai_compatible_stream(openrouter,
                                                   Config,
                                                   Request,
                                                   EventHandler,
                                                   Outcome).
dispatch_stream_provider(openai_compatible, Config, Request, EventHandler,
                         Outcome) :-
    !,
    rlm_openai_compatible:openai_compatible_stream(openai_compatible,
                                                   Config,
                                                   Request,
                                                   EventHandler,
                                                   Outcome).
dispatch_stream_provider(Provider, _, _, _,
                         error(provider_error{provider:Provider,
                                              kind:capability_denied,
                                              capability:streaming,
                                              message:"provider does not implement streaming"})).

%!  chain_invoke(+ProviderSpec, +Request, +Options, -Outcome) is det.
%
%   Invoke a direct provider or `route(Candidates)` through the canonical chain
%   runtime.  Options include `retry_policy/1`, `middleware/1`, `router/1`,
%   `structured_schema/1`, `trace_handler/1`, and `sleep_handler/1`.

chain_invoke(ProviderSpec, Request, Options, Outcome) :-
    rlm_chain_runtime:chain_invoke_with_transport(ProviderSpec,
                                                  Request,
                                                  Options,
                                                  rlm_chain:model_complete,
                                                  Outcome).

%!  chain_stream(+ProviderSpec, +Request, +Options, +EventHandler, -Outcome) is det.
%
%   Stream a direct or routed provider request through the canonical middleware,
%   structured-output and trace lifecycle.  Streaming is not simulated from a
%   completed response; the provider transport calls `EventHandler` as SSE data
%   arrives.

chain_stream(ProviderSpec, Request, Options, EventHandler, Outcome) :-
    rlm_chain_runtime:chain_stream_with_transport(ProviderSpec,
                                                  Request,
                                                  Options,
                                                  rlm_chain:model_stream,
                                                  EventHandler,
                                                  Outcome).

normalize_openai_chat_response(Provider, RequestedModel, HttpInfo, Raw,
                               Outcome) :-
    rlm_openai_compatible:normalize_openai_chat_response(Provider,
                                                         RequestedModel,
                                                         HttpInfo,
                                                         Raw,
                                                         Outcome).
