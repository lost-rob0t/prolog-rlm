:- begin_tests(live_direct_native_openrouter).

:- use_module(library(random)).
:- use_module(library(uuid)).
:- use_module('../prolog/rlm_chain').
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_tool').

:- dynamic live_direct_request_count/1.
:- dynamic live_direct_expected_uuid/1.
:- dynamic live_direct_role/1.
:- dynamic live_direct_generation/4.
:- dynamic live_direct_case/6.
:- at_halt(print_live_direct_evidence).

test(real_direct_native_context_search_retrieves_random_40k_uuid) :-
    require_live_direct_environment(RequestedModel),
    uuid(UUIDAtom, [version(4)]),
    atom_string(UUIDAtom, UUID),
    random_between(1000, 30000, NeedleSequence),
    build_live_direct_context(NeedleSequence, UUID, Context),
    openrouter_provider(RequestedModel, Provider),
    reset_live_direct(context, UUID),
    Handler = plunit_live_direct_native_openrouter:live_model(UUID, Provider),
    Options = [provider(Provider),provider_name(openrouter),
               model_handler(Handler),
               capabilities([context(search)]),
               budget(_{max_model_calls:4,max_context_ops:2,
                        max_total_tokens:16000,max_cost_usd:0.25,
                        max_output_bytes:8192,time_limit:150.0}),
               planner_max_tokens(1024),temperature(0)],
    rlm_direct("Use context_search to find DIRECT_NATIVE_40K_NEEDLE. Return only its payload UUID, with no explanation.",
               text(Context), Options, Outcome),
    require_live_direct_success(Outcome, Result),
    assertion(Result.value == UUID),
    assertion(Result.context_calls >= 1),
    assertion(Result.tool_calls =:= 0),
    once((member(Event, Result.trajectory),
          Event.type == native_context,
          Event.name == context_search)),
    assertz(live_direct_case(context,UUID,NeedleSequence,Result.turns,
                             Result.usage.total_tokens,
                             Result.usage.cost_usd)),
    format('direct_native_context_uuid: ~s~n', [UUID]),
    format('direct_native_context_sequence: ~d~n', [NeedleSequence]),
    format('direct_native_context_model_calls: ~d~n', [Result.turns]),
    format('direct_native_context_total_tokens: ~d~n',
           [Result.usage.total_tokens]),
    format('direct_native_context_cost_usd: ~9f~n',
           [Result.usage.cost_usd]).

test(real_direct_registered_tool_uses_native_call_and_result_context) :-
    require_live_direct_environment(RequestedModel),
    uuid(TokenAtom, [version(4)]),
    atom_string(TokenAtom, Token),
    openrouter_provider(RequestedModel, Provider),
    tool_registry_create(Registry),
    setup_call_cleanup(
        register_live_token_tool(Registry, Token),
        ( reset_live_direct(tool, Token),
          Handler = plunit_live_direct_native_openrouter:live_model(Token,
                                                                    Provider),
          Options = [provider(Provider),provider_name(openrouter),
                     model_handler(Handler),tool_registry(Registry),
                     prompt_compile_mode(all_tools),
                     capabilities([tool(runtime_token),context(peek)]),
                     budget(_{max_model_calls:5,max_tool_calls:2,
                              max_context_ops:2,max_total_tokens:16000,
                              max_cost_usd:0.25,max_output_bytes:8192,
                              time_limit:150.0}),
                     planner_max_tokens(1024),temperature(0)],
          rlm_direct("Call runtime_token exactly once. Its result is an opaque result context, so inspect item 0 with context_peek. Return only the token, with no explanation.",
                     text("opaque registered-tool acceptance"),
                     Options, Outcome),
          require_live_direct_success(Outcome, Result),
          assertion(Result.value == Token),
          assertion(Result.tool_calls =:= 1),
          assertion(Result.context_calls >= 1),
          once((member(Event, Result.trajectory),
                Event.type == native_tool,
                Event.name == runtime_token,
                Event.trace.authorization == allowed)),
          assertz(live_direct_case(tool,Token,0,Result.turns,
                                   Result.usage.total_tokens,
                                   Result.usage.cost_usd)),
          format('direct_native_tool_token: ~s~n', [Token]),
          format('direct_native_tool_model_calls: ~d~n', [Result.turns]),
          format('direct_native_tool_total_tokens: ~d~n',
                 [Result.usage.total_tokens]),
          format('direct_native_tool_cost_usd: ~9f~n',
                 [Result.usage.cost_usd])
        ),
        tool_registry_destroy(Registry)).

reset_live_direct(Role, Expected) :-
    retractall(live_direct_request_count(_)),
    retractall(live_direct_expected_uuid(_)),
    retractall(live_direct_role(_)),
    assertz(live_direct_request_count(0)),
    assertz(live_direct_expected_uuid(Expected)),
    assertz(live_direct_role(Role)).

live_model(Expected, Provider, Request, Outcome) :-
    retract(live_direct_request_count(N0)),
    N is N0+1,
    assertz(live_direct_request_count(N)),
    ( N =:= 1
    -> term_string(Request, RequestText),
       assertion(\+ sub_string(RequestText, _, _, _, Expected)),
       assertion(get_dict(tools, Request.options, Tools)),
       assertion(Tools \== [])
    ; true
    ),
    model_complete_execute(Provider, Request, Outcome),
    record_live_generation(N, Outcome).

record_live_generation(N, ok(Response)) :-
    !,
    live_direct_role(Role),
    assertz(live_direct_generation(Role,N,Response.response_id,
                                   Response.metadata.http_status)).
record_live_generation(_, error(_)).

register_live_token_tool(Registry, Token) :-
    Schema = tool_schema{
                 name:runtime_token,
                 description:"Return the unpredictable token generated by the trusted runtime for this call",
                 capability:tool(runtime_token),effect:read,
                 arguments:_{type:object,properties:_{},required:[],
                             additional_properties:false},
                 result:_{type:object,
                          properties:_{token:_{type:string}},
                          required:[token],additional_properties:false},
                 limits:_{time_limit:1.0,max_output_bytes:1024}},
    Handler = plunit_live_direct_native_openrouter:live_token_handler(Token),
    tool_register(Registry, Schema, Handler, ok(_)).

live_token_handler(Token, _, json{token:Token}).

build_live_direct_context(NeedleSequence, UUID, Context) :-
    findall(Line,
            ( between(1, 40000, Sequence),
              live_direct_line(Sequence, NeedleSequence, UUID, Line)
            ),
            Lines),
    atomics_to_string(Lines, "\n", Context).

live_direct_line(Sequence, Sequence, UUID, Line) :-
    !,
    format(string(Line), "record ~d DIRECT_NATIVE_40K_NEEDLE payload=~s",
           [Sequence,UUID]).
live_direct_line(Sequence, _, _, Line) :-
    format(string(Line), "historical opaque record ~d", [Sequence]).

require_live_direct_environment(Model) :-
    ( getenv('OPENROUTER_API_KEY', Key), Key \== '', Key \== ""
    -> true
    ; throw(error(missing_live_credential('OPENROUTER_API_KEY'),_))
    ),
    default_openrouter_model(Model),
    ( Model \== 'openrouter/free',
      \+ sub_atom(Model, _, 5, 0, ':free')
    -> true
    ; throw(error(pinned_paid_model_required(Model),_))
    ).

require_live_direct_success(ok(Result), Result) :- !.
require_live_direct_success(error(Error), _) :-
    throw(error(live_direct_native_failure(Error),_)).

print_live_direct_evidence :-
    forall(live_direct_generation(Role, N, Id, Status),
           ( format(user_error,
                    'direct_native_~w_generation_~d_id: ~w~n', [Role,N,Id]),
             format(user_error,
                    'direct_native_~w_generation_~d_http_status: ~d~n',
                    [Role,N,Status])
           )),
    forall(live_direct_case(Role, Value, Sequence, Calls, Tokens, Cost),
           ( format(user_error, 'direct_native_~w_value: ~s~n', [Role,Value]),
             format(user_error, 'direct_native_~w_sequence: ~d~n',
                    [Role,Sequence]),
             format(user_error, 'direct_native_~w_model_calls: ~d~n',
                    [Role,Calls]),
             format(user_error, 'direct_native_~w_total_tokens: ~d~n',
                    [Role,Tokens]),
             format(user_error, 'direct_native_~w_cost_usd: ~9f~n',
                    [Role,Cost])
           )).

:- end_tests(live_direct_native_openrouter).
