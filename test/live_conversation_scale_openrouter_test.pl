:- begin_tests(live_conversation_scale_openrouter).

:- use_module('../prolog/rlm', []).
:- use_module('../prolog/rlm_chain',
              [ default_openrouter_model/1,
                model_complete_execute/3,
                openrouter_provider/2
              ]).
:- use_module(library(uuid)).
:- use_module(library(random)).

:- dynamic live_uuid_evidence/2.
:- dynamic live_needle_sequence/1.
:- dynamic live_provider_evidence/4.
:- dynamic live_usage_evidence/5.
:- at_halt(print_live_uuid_evidence).

test(real_openrouter_managed_turn_retrieves_needle_from_40000_messages) :-
    require_live_conversation_credential,
    default_openrouter_model(RequestedModel),
    require_pinned_paid_model(RequestedModel),
    setup_call_cleanup(
        ( rlm:conversation_store_open(memory, ok(ConversationStore)),
          rlm:artifact_store_open(memory, ok(ArtifactStore))
        ),
        once(run_live_scale_case(ConversationStore,
                                 ArtifactStore,
                                 RequestedModel)),
        ( rlm:artifact_store_close(ArtifactStore, _),
          rlm:conversation_store_close(ConversationStore, _)
        )).

run_live_scale_case(ConversationStore, ArtifactStore, RequestedModel) :-
    uuid(PayloadAtom, [version(4)]),
    atom_string(PayloadAtom, ExpectedPayload),
    random_between(1000, 30000, NeedleSequence),
    retractall(live_uuid_evidence(_, _)),
    retractall(live_needle_sequence(_)),
    retractall(live_provider_evidence(_, _, _, _)),
    retractall(live_usage_evidence(_, _, _, _, _)),
    assertz(live_uuid_evidence(test, ExpectedPayload)),
    assertz(live_needle_sequence(NeedleSequence)),
    rlm:conversation_create(ConversationStore,
                              [id(live_scale_40000)],
                              ok(Conversation)),
    append_scale_messages(Conversation, NeedleSequence, ExpectedPayload),
    rlm:conversation_warm_publish(
        Conversation,
        ArtifactStore,
        range(1,4),
        [ generator(plunit_live_conversation_scale_openrouter:warm_generator),
          token_options([token_counter(
                             plunit_live_conversation_scale_openrouter:char_counter)])
        ],
        ok(Published)),
    assertion(Published.warm.source_range == range(1,4)),
    rlm:conversation_warm_context_units(
        Conversation,
        ArtifactStore,
        [],
        [policy(json{max_candidates:8})],
        ok(WarmUnits)),
    assertion(length(WarmUnits, 1)),
    statistics(walltime, [Started,_]),
    rlm:conversation_turn(
        Conversation,
        message(user, "Find the historical marker LIVE_40K_NEEDLE and return the exact payload stored in that old message. The payload is not in the active context. You must retrieve it through the opaque context input named context; do not guess or return the marker label alone."),
        [ context_options([
              token_options([token_counter(
                                 plunit_live_conversation_scale_openrouter:char_counter)]),
              max_cold_candidates(32),
              warm_store(ArtifactStore),
              warm_options([policy(json{max_candidates:8})])
          ]),
          completion_options([
              planner_handler(
                  plunit_live_conversation_scale_openrouter:live_provider_planner(
                      ExpectedPayload)),
              planner_attempts(3),
              planner_max_tokens(4096),
              planner_reasoning_effort(minimal),
              context_options([max_results(8),
                               max_bytes(32768),
                               time_limit(5.0)]),
              budget(_{max_iterations:8,
                       max_recursion_depth:0,
                       max_concurrent_subcalls:1,
                       max_model_calls:3,
                       max_tool_calls:0,
                       max_context_ops:2,
                       max_total_tokens:30000,
                       max_cost_usd:0.50,
                       max_output_bytes:32768,
                       time_limit:150.0})
          ])
        ],
        ok(Turn)),
    statistics(walltime, [Finished,_]),
    Elapsed is Finished-Started,
    assertion(Elapsed < 150000),
    Completion = Turn.completion,
    assertion(Completion.trajectory.root_event.provider == openrouter),
    assertion(Completion.trajectory.root_event.http_status =:= 200),
    assertion(selected_model_matches(
                  RequestedModel,
                  Completion.trajectory.root_event.selected_model)),
    assertion(Turn.context.warm.loaded_units =:= 1),
    assertion(Turn.context.cold_history_boundary.active == true),
    validate_model_retrieval(Completion,
                             RequestedModel,
                             NeedleSequence,
                             ExpectedPayload,
                             ChildResponse),
    % The exact payload reaches the user-visible answer. The model may
    % echo it through an interpretation model step or return the retrieved
    % hit as the final value; either way the payload must be present.
    get_dict(assistant, Turn, Assistant),
    get_dict(content, Assistant, AssistantContent),
    assertion(sub_string(AssistantContent, _, _, _, ExpectedPayload)),
    record_usage_evidence(Completion.usage),
    (   ChildResponse \== none
    ->  record_provider_evidence(child_model, ChildResponse),
        get_dict(text, ChildResponse, ModelPayload),
        assertz(live_uuid_evidence(model, ModelPayload))
    ;   true
    ),
    log_live_scale_evidence(RequestedModel, Completion, Turn, Elapsed).

% The managed turn must retrieve the needle from the cold history through
% the opaque context input, whatever valid plan shape the model chooses to
% express it: exactly one successful cold search whose binding contains the
% exact needle match, a successful final step last, every step ok, and any
% model step bound to a real provider response for the pinned model. The
% plan shape itself is model free-choice (the closed vocabulary admits
% search->final and search->model->final alike), so the assertions pin the
% runtime's retrieval contract, not one model-authored shape.
validate_model_retrieval(Completion,
                         RequestedModel,
                         NeedleSequence,
                         ExpectedPayload,
                         ChildResponse) :-
    Transitions = Completion.transitions,
    include(is_ok_search_transition, Transitions, Searches),
    length(Searches, 1),
    Searches = [Search],
    get_dict(bind, Search, SearchBind),
    get_dict(SearchBind, Completion.vars, SearchMatches),
    needle_content(ExpectedPayload, ExpectedContent),
    once(member(conversation_match{sequence:NeedleSequence,
                                   content:ExpectedContent,
                                   index:_,
                                   ref:_,
                                   role:user},
                SearchMatches)),
    last(Transitions, Final),
    get_dict(operation, Final, final),
    assertion(all_steps_ok(Transitions)),
    findall(ModelResponse,
            (   member(T, Transitions),
                get_dict(operation, T, model(openrouter)),
                get_dict(bind, T, ModelBind),
                get_dict(ModelBind, Completion.vars, ModelResponse)
            ),
            ModelResponses),
    forall(member(ModelResponse, ModelResponses),
           validate_child_response(ModelResponse, RequestedModel)),
    (   ModelResponses = [ChildResponse|_]
    ->  true
    ;   ChildResponse = none
    ),
    get_dict(usage, Completion, Usage),
    get_dict(model_calls, Usage, ModelCalls),
    assertion(ModelCalls >= 1).

all_steps_ok(Transitions) :-
    forall(member(T, Transitions),
           (   get_dict(status, T, Status),
               Status == ok
           )).

validate_child_response(ModelResponse, RequestedModel) :-
    assertion(get_dict(provider, ModelResponse, openrouter)),
    get_dict(metadata, ModelResponse, ModelMetadata),
    assertion(get_dict(http_status, ModelMetadata, 200)),
    get_dict(selected_model, ModelResponse, SelectedModel),
    assertion(selected_model_matches(RequestedModel, SelectedModel)).

all_steps_ok(Transitions) :-
    forall(member(T, Transitions),
           (   get_dict(status, T, Status),
               Status == ok
           )).

print_live_uuid_evidence :-
    forall(live_uuid_evidence(test, TestUUID),
           format(user_error,
                  'conversation_scale_test_uuid: ~s~n',
                  [TestUUID])),
    forall(live_needle_sequence(NeedleSequence),
           format(user_error,
                  'conversation_scale_needle_sequence: ~d~n',
                  [NeedleSequence])),
    forall(live_provider_evidence(Role, GenerationId, Model, Status),
           ( format(user_error,
                    'conversation_scale_~w_generation_id: ~w~n',
                    [Role, GenerationId]),
             format(user_error,
                    'conversation_scale_~w_generation_model: ~w~n',
                    [Role, Model]),
             format(user_error,
                    'conversation_scale_~w_generation_http_status: ~d~n',
                    [Role, Status])
           )),
    forall(live_uuid_evidence(model, ModelUUID),
           format(user_error,
                  'conversation_scale_model_uuid: ~s~n',
                  [ModelUUID])),
    forall(live_usage_evidence(ModelCalls,
                               PromptTokens,
                               CompletionTokens,
                               TotalTokens,
                               CostUSD),
           ( format(user_error,
                    'conversation_scale_model_calls: ~d~n',
                    [ModelCalls]),
             format(user_error,
                    'conversation_scale_prompt_tokens: ~d~n',
                    [PromptTokens]),
             format(user_error,
                    'conversation_scale_completion_tokens: ~d~n',
                    [CompletionTokens]),
             format(user_error,
                    'conversation_scale_total_tokens: ~d~n',
                    [TotalTokens]),
             format(user_error,
                    'conversation_scale_cost_usd: ~9f~n',
                    [CostUSD])
           )),
    flush_output(user_error).

record_provider_evidence(Role, Response) :-
    get_dict(response_id, Response, GenerationId),
    get_dict(selected_model, Response, SelectedModel),
    get_dict(metadata, Response, Metadata),
    get_dict(http_status, Metadata, Status),
    assertz(live_provider_evidence(Role,
                                   GenerationId,
                                   SelectedModel,
                                   Status)).

record_usage_evidence(Usage) :-
    assertz(live_usage_evidence(Usage.model_calls,
                                Usage.prompt_tokens,
                                Usage.completion_tokens,
                                Usage.total_tokens,
                                Usage.cost_usd)).

live_provider_planner(ExpectedPayload, Request, Outcome) :-
    get_dict(messages, Request, Messages),
    assertion(forall(member(Message, Messages),
                     ( get_dict(content, Message, Content),
                       \+ sub_string(Content, _, _, _, ExpectedPayload)
                     ))),
    default_openrouter_model(Model),
    openrouter_provider(Model, Provider),
    model_complete_execute(Provider, Request, Outcome),
    log_live_provider_outcome(Outcome).

log_live_provider_outcome(ok(Response)) :-
    !,
    get_dict(response_id, Response, GenerationId),
    get_dict(selected_model, Response, SelectedModel),
    get_dict(metadata, Response, Metadata),
    get_dict(http_status, Metadata, Status),
    assertz(live_provider_evidence(root_planner,
                                   GenerationId,
                                   SelectedModel,
                                   Status)),
    format(user_error,
           'conversation_scale_generation_id: ~w~n',
           [GenerationId]),
    format(user_error,
           'conversation_scale_generation_model: ~w~n',
           [SelectedModel]),
    format(user_error,
           'conversation_scale_generation_http_status: ~d~n',
           [Status]),
    flush_output(user_error).
log_live_provider_outcome(error(Error)) :-
    format(user_error,
           'conversation_scale_generation_error: ~q~n',
           [Error]),
    flush_output(user_error).

append_scale_messages(Conversation, NeedleSequence, Payload) :-
    forall(between(1, 40000, Sequence),
           ( scale_message(Sequence,
                           NeedleSequence,
                           Payload,
                           Content),
              rlm:conversation_append(Conversation,
                                      message(user, Content),
                                      ok(_))
            )).

scale_message(Sequence, NeedleSequence, Payload, Content) :-
    Sequence =:= NeedleSequence,
    !,
    needle_content(Payload, Content).
scale_message(Sequence, _, _, Content) :-
    format(string(Content), "historical live chat ~d", [Sequence]).

needle_content(Payload, Content) :-
    format(string(Content), "LIVE_40K_NEEDLE payload=~s", [Payload]).

warm_generator(_Source,
               _Options,
               json{summary:"warm context compiled for 40000 chats",
                   decisions:["keep the durable transcript authoritative"],
                   facts:["cold retrieval remains available"],
                   unresolved:[],
                   entities:["live-scale-test"],
                   topics:["conversation context"],
                   files:[],
                   symbols:[]}).

char_counter(Text, Tokens) :-
    string_length(Text, Tokens).

require_live_conversation_credential :-
    (   getenv('OPENROUTER_API_KEY', Key),
        Key \== '',
        Key \== ""
    ->  true
    ;   throw(error(missing_live_credential('OPENROUTER_API_KEY'),
                    context(live_conversation_scale_openrouter,
                            'OPENROUTER_API_KEY is not configured')))
    ).

require_pinned_paid_model(Model) :-
    (   getenv('OPENROUTER_TEST_MODEL', Configured),
        Configured \== '',
        Configured \== "",
        Model == Configured,
        Model \== 'openrouter/free',
        \+ sub_atom(Model, _, 5, 0, ':free')
    ->  true
    ;   throw(error(invalid_live_model(Model),
                    context(live_conversation_scale_openrouter,
                            'OPENROUTER_TEST_MODEL must name a pinned paid model')))
    ).

selected_model_matches(Model, Model) :- !.

is_ok_search_transition(T) :-
    get_dict(operation, T, context(search)),
    get_dict(status, T, ok).
selected_model_matches(Requested, Selected) :-
    atom(Requested),
    string(Selected),
    atom_string(Requested, Selected).

log_live_scale_evidence(RequestedModel, Completion, Turn, Elapsed) :-
    format('conversation_scale_provider: openrouter~n', []),
    format('conversation_scale_requested_model: ~w~n', [RequestedModel]),
    format('conversation_scale_selected_model: ~w~n',
           [Completion.trajectory.root_event.selected_model]),
    format('conversation_scale_http_status: ~d~n',
           [Completion.trajectory.root_event.http_status]),
    format('conversation_scale_messages: 40000~n', []),
    format('conversation_scale_warm_units: ~d~n',
           [Turn.context.warm.loaded_units]),
    format('conversation_scale_context_search: true~n', []),
    format('conversation_scale_needle_retrieved: true~n', []),
    format('conversation_scale_model_calls: ~d~n',
           [Completion.usage.model_calls]),
    format('conversation_scale_elapsed_ms: ~d~n', [Elapsed]).

:- end_tests(live_conversation_scale_openrouter).
