:- begin_tests(live_conversation_scale_openrouter).

:- use_module('../prolog/rlm', []).
:- use_module('../prolog/rlm_chain',
              [ default_openrouter_model/1,
                model_complete_execute/3,
                openrouter_provider/2
              ]).
:- use_module(library(uuid)).

:- dynamic live_uuid_evidence/2.
:- dynamic live_provider_evidence/3.
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
    retractall(live_uuid_evidence(_, _)),
    retractall(live_provider_evidence(_, _, _)),
    assertz(live_uuid_evidence(test, ExpectedPayload)),
    rlm:conversation_create(ConversationStore,
                              [id(live_scale_40000)],
                              ok(Conversation)),
    append_scale_messages(Conversation, ExpectedPayload),
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
    assertion(Completion.usage.model_calls >= 1),
    assertion(Turn.context.warm.loaded_units =:= 1),
    assertion(Turn.context.cold_history_boundary.active == true),
    once(member(plan_transition{operation:context(search),
                                status:ok,
                                bind:_,
                                sequence:_},
                Completion.transitions)),
    assistant_payload(Turn.assistant.content,
                      ExpectedPayload,
                      ModelPayload),
    assertz(live_uuid_evidence(model, ModelPayload)),
    log_live_scale_evidence(RequestedModel, Completion, Turn, Elapsed).

print_live_uuid_evidence :-
    forall(live_uuid_evidence(test, TestUUID),
           format(user_error,
                  'conversation_scale_test_uuid: ~s~n',
                  [TestUUID])),
    forall(live_provider_evidence(GenerationId, Model, Status),
           ( format(user_error,
                    'conversation_scale_generation_id: ~w~n',
                    [GenerationId]),
             format(user_error,
                    'conversation_scale_generation_model: ~w~n',
                    [Model]),
             format(user_error,
                    'conversation_scale_generation_http_status: ~d~n',
                    [Status])
           )),
    forall(live_uuid_evidence(model, ModelUUID),
           format(user_error,
                  'conversation_scale_model_uuid: ~s~n',
                  [ModelUUID])),
    flush_output(user_error).

assistant_payload(AssistantContent, ExpectedPayload, ModelPayload) :-
    string_length(ExpectedPayload, Length),
    once(( sub_string(AssistantContent, Start, Length, _, ModelPayload),
           Start >= 0,
           ModelPayload == ExpectedPayload
         )).

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
    assertz(live_provider_evidence(GenerationId, SelectedModel, Status)),
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

append_scale_messages(Conversation, Payload) :-
    forall(between(1, 40000, Sequence),
           ( scale_message(Sequence, Payload, Content),
              rlm:conversation_append(Conversation,
                                      message(user, Content),
                                      ok(_))
            )).

scale_message(12345, Payload, Content) :-
    !,
    format(string(Content), "LIVE_40K_NEEDLE payload=~s", [Payload]).
scale_message(Sequence, _, Content) :-
    format(string(Content), "historical live chat ~d", [Sequence]).

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
