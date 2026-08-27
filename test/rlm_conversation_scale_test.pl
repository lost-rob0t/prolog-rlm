:- begin_tests(rlm_conversation_scale).

:- use_module('../prolog/rlm', []).

:- meta_predicate with_scale_runtime(2).

with_scale_runtime(Goal) :-
    setup_call_cleanup(
        ( rlm:conversation_store_open(memory, ok(ConversationStore)),
          rlm:artifact_store_open(memory, ok(ArtifactStore))
        ),
        ( rlm:conversation_create(ConversationStore,
                                  [id(scale_40000)],
                                  ok(Conversation)),
          once(call(Goal, Conversation, ArtifactStore))
        ),
        ( rlm:artifact_store_close(ArtifactStore, _),
          rlm:conversation_store_close(ConversationStore, _)
        )).

test(large_conversation_reuses_warm_context_and_retrieves_cold_needle) :-
    with_scale_runtime(large_conversation_case).

large_conversation_case(Conversation, ArtifactStore) :-
    append_scale_messages(Conversation),
    rlm:conversation_warm_publish(
        Conversation,
        ArtifactStore,
        range(1,4),
        [ generator(plunit_rlm_conversation_scale:warm_generator),
          token_options([token_counter(plunit_rlm_conversation_scale:char_counter)])
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
        message(user, "retrieve the old scale marker"),
        [ context_options([
              token_options([token_counter(plunit_rlm_conversation_scale:char_counter)]),
              warm_store(ArtifactStore),
              warm_options([policy(json{max_candidates:8})])
          ]),
          completion_options([
              planner_handler(plunit_rlm_conversation_scale:scale_planner),
              planner_attempts(1)
          ])
        ],
        ok(Turn)),
    statistics(walltime, [Finished,_]),
    Elapsed is Finished-Started,
    assertion(Elapsed < 30000),
    assertion(Turn.context.warm.loaded_units =:= 1),
    assertion(Turn.context.cold_history_boundary.active == true),
    assertion(Turn.context.ledger.total_tokens =<
              Turn.context.policy.effective_context_tokens),
    assertion(once(sub_string(Turn.assistant.content,
                              _, _, _,
                              "needle-40000"))),
    assertion(once(sub_string(Turn.assistant.content,
                              _, _, _,
                              "12345"))).

append_scale_messages(Conversation) :-
    forall(between(1, 40000, Sequence),
           ( scale_message(Sequence, Content),
             rlm:conversation_append(Conversation,
                                     message(user, Content),
                                     ok(_))
           )).

scale_message(12345, "historical needle-40000 value") :- !.
scale_message(Sequence, Content) :-
    format(string(Content), "historical chat ~d", [Sequence]).

scale_planner(Request, ok(Output)) :-
    get_dict(messages, Request, Messages),
    assertion(forall(member(Visible, Messages),
                     ( get_dict(content, Visible, Content),
                       \+ sub_string(Content, _, _, _, "needle-40000")
                     ))),
    Plan = plan([
        context(input(context), search("needle-40000"), found),
        final(var(found))
    ]),
    Output = planner_output{
                 plan:Plan,
                 usage:json{prompt_tokens:1,
                            completion_tokens:1,
                            total_tokens:2,
                            cost:0.0}
             }.

warm_generator(_Source,
               _Options,
               json{summary:"warm context compiled for 40000 chats",
                   decisions:["keep the durable transcript authoritative"],
                   facts:["cold retrieval remains available"],
                   unresolved:[],
                   entities:["scale-test"],
                   topics:["conversation context"],
                   files:[],
                   symbols:[]}).

char_counter(Text, Tokens) :-
    string_length(Text, Tokens).

:- end_tests(rlm_conversation_scale).
