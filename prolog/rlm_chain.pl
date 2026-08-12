:- module(rlm_chain,
          [ rlm_chain_ready/0,
            model_complete/3,
            openrouter_provider/2,
            openai_compatible_provider/4,
            default_openrouter_model/1,
            provider_capability/2,
            normalize_openai_chat_response/5
          ]).

/** <module> Provider-neutral model-chain runtime

`rlm_chain` owns canonical provider dispatch. Production providers use explicit
configuration terms and return structured `ok/1` or `error/1` outcomes.
Deterministic fake providers remain test-only and are never fallback targets.
*/

:- use_module(rlm_openai_compatible,
              [ openai_compatible_complete/4
              ]).

rlm_chain_ready.

%!  provider_capability(?Provider, ?Capability) is nondet.

provider_capability(openrouter, chat_completions).
provider_capability(openrouter, usage_metadata).
provider_capability(openrouter, tool_calls).
provider_capability(openai_compatible, chat_completions).
provider_capability(openai_compatible, tool_calls).

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

normalize_openai_chat_response(Provider, RequestedModel, HttpInfo, Raw,
                               Outcome) :-
    rlm_openai_compatible:normalize_openai_chat_response(Provider,
                                                         RequestedModel,
                                                         HttpInfo,
                                                         Raw,
                                                         Outcome).
