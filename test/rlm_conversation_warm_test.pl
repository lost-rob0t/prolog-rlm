:- begin_tests(rlm_conversation_warm).

:- use_module('../prolog/rlm_artifact').
:- use_module('../prolog/rlm_conversation').
:- use_module('../prolog/rlm_conversation_warm').

:- meta_predicate with_warm_runtime(2).

with_warm_runtime(Goal) :-
    setup_call_cleanup(
        ( conversation_store_open(memory, ok(ConversationStore)),
          artifact_store_open(memory, ok(ArtifactStore))
        ),
        ( conversation_create(ConversationStore,
                              [id(warm_test)],
                              ok(Conversation)),
          call(Goal, Conversation, ArtifactStore)
        ),
        ( artifact_store_close(ArtifactStore, _),
          conversation_store_close(ConversationStore, _)
        )).

test(published_warm_context_preserves_exact_source_transcript) :-
    with_warm_runtime(preserve_source_case).

preserve_source_case(Conversation, ArtifactStore) :-
    conversation_append(Conversation,
                        message(user, "first source turn"),
                        ok(First)),
    conversation_append(Conversation,
                        message(assistant, "second source turn"),
                        ok(Second)),
    conversation_append(Conversation,
                        message(user, "hot current turn"),
                        ok(_)),
    conversation_warm_publish(
        Conversation,
        ArtifactStore,
        range(1,2),
        [ generator(plunit_rlm_conversation_warm:fake_generator),
          token_options([token_counter(plunit_rlm_conversation_warm:char_counter)])
        ],
        ok(Published)),
    assertion(Published.artifact.key == range_1_2),
    assertion(Published.warm.source_refs == [First.ref,Second.ref]),
    findall(Kind,
            ( member(Variant, Published.warm.variants),
              Kind = Variant.kind ),
            Kinds),
    assertion(Kinds == [verbatim,
                        detailed_summary,
                        compact_summary,
                        facts_only]),
    conversation_messages(Conversation, all, [], ok(Messages)),
    length(Messages, 3),
    Messages = [RestoredFirst,RestoredSecond,_],
    assertion(RestoredFirst.content == "first source turn"),
    assertion(RestoredSecond.content == "second source turn"),
    conversation_warm_list(Conversation,
                           ArtifactStore,
                           [],
                           ok([Artifact])),
    assertion(Artifact.ref == Published.artifact.ref).

test(recompaction_creates_new_artifact_version_without_rewriting_source) :-
    with_warm_runtime(recompaction_case).

recompaction_case(Conversation, ArtifactStore) :-
    conversation_append(Conversation, message(user, "source"), ok(Source)),
    Options = [ generator(plunit_rlm_conversation_warm:fake_generator),
                token_options([token_counter(plunit_rlm_conversation_warm:char_counter)])
              ],
    conversation_warm_publish(Conversation,
                              ArtifactStore,
                              range(1,1),
                              Options,
                              ok(First)),
    conversation_warm_publish(Conversation,
                              ArtifactStore,
                              range(1,1),
                              Options,
                              ok(Second)),
    assertion(First.artifact.ref.version =:= 1),
    assertion(Second.artifact.ref.version =:= 2),
    conversation_warm_list(Conversation,
                           ArtifactStore,
                           [history(true)],
                           ok(History)),
    length(History, 2),
    conversation_message(Conversation, 1, ok(Restored)),
    assertion(Restored.ref == Source.ref),
    assertion(Restored.content == "source").

test(tight_budget_selects_compact_warm_representation_and_keeps_hot_turn) :-
    with_warm_runtime(compact_pack_case).

compact_pack_case(Conversation, ArtifactStore) :-
    long_text(a, 150, OldA),
    long_text(b, 150, OldB),
    conversation_append(Conversation, message(user, OldA), ok(_)),
    conversation_append(Conversation, message(assistant, OldB), ok(_)),
    conversation_append(Conversation, message(user, "current"), ok(_)),
    WarmOptions = [ generator(plunit_rlm_conversation_warm:verbose_generator),
                    token_options([token_counter(plunit_rlm_conversation_warm:char_counter)])
                  ],
    conversation_warm_publish(Conversation,
                              ArtifactStore,
                              range(1,2),
                              WarmOptions,
                              ok(_)),
    conversation_warm_context_units(Conversation,
                                    ArtifactStore,
                                    [],
                                    [policy(json{max_candidates:8})],
                                    ok(WarmUnits)),
    Policy = context_policy{max_context_tokens:150,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny},
    conversation_context_pack(
        Conversation,
        [ policy(Policy),
          token_options([token_counter(plunit_rlm_conversation_warm:char_counter)]),
          context_units(WarmUnits)
        ],
        ok(Pack)),
    findall(Id-Kind,
            ( member(Selection, Pack.selected),
              Id = Selection.id,
              Kind = Selection.kind ),
            Selected),
    assertion(memberchk(conversation_message_3-verbatim, Selected)),
    assertion(memberchk(range_1_2-compact_summary, Selected)),
    assertion(\+ memberchk(conversation_message_1-_, Selected)),
    assertion(\+ memberchk(conversation_message_2-_, Selected)),
    assertion(Pack.ledger.total_tokens =< 150).

test(direct_reference_signal_beats_irrelevant_recency_during_candidate_narrowing) :-
    with_warm_runtime(reference_ranking_case).

reference_ranking_case(Conversation, ArtifactStore) :-
    conversation_append(Conversation, message(user, "old database decision"), ok(_)),
    conversation_append(Conversation, message(user, "new unrelated turn"), ok(_)),
    Options = [ generator(plunit_rlm_conversation_warm:fake_generator),
                token_options([token_counter(plunit_rlm_conversation_warm:char_counter)])
              ],
    conversation_warm_publish(Conversation,
                              ArtifactStore,
                              range(1,1),
                              Options,
                              ok(_)),
    conversation_warm_publish(Conversation,
                              ArtifactStore,
                              range(2,2),
                              Options,
                              ok(_)),
    Signals = [warm_signal(range_1_1, direct_reference, 10)],
    conversation_warm_context_units(
        Conversation,
        ArtifactStore,
        Signals,
        [policy(json{max_candidates:1})],
        ok([Unit])),
    assertion(Unit.id == range_1_1).

test(malformed_generator_output_fails_closed) :-
    with_warm_runtime(malformed_generator_case).

malformed_generator_case(Conversation, _ArtifactStore) :-
    conversation_append(Conversation, message(user, "source"), ok(_)),
    conversation_warm_derive(
        Conversation,
        range(1,1),
        [generator(plunit_rlm_conversation_warm:bad_generator)],
        error(Error)),
    assertion(Error.phase == derive).

fake_generator(_Source, _Options,
               json{summary:"architecture summary",
                 decisions:["keep transcript immutable"],
                 facts:["warm context is derived"],
                 unresolved:["wire cold retrieval"],
                 entities:["prolog-rlm"],
                 topics:["context"],
                 files:[],
                 symbols:[]}).

verbose_generator(_Source, _Options,
                  json{summary:"compact useful summary",
                    decisions:["decision alpha alpha alpha alpha",
                               "decision beta beta beta beta",
                               "decision gamma gamma gamma gamma"],
                    facts:["fact alpha alpha alpha alpha",
                           "fact beta beta beta beta",
                           "fact gamma gamma gamma gamma"],
                    unresolved:["next task"],
                    entities:["entity alpha", "entity beta"],
                    topics:["topic alpha", "topic beta"],
                    files:["one/very/long/file/path.pl", "two/very/long/file/path.pl"],
                    symbols:["symbol_alpha", "symbol_beta"]}).

bad_generator(_Source, _Options, json{summary:"missing required fields"}).

char_counter(Text, Tokens) :-
    string_length(Text, Tokens).

long_text(Char, Count, Text) :-
    length(Chars, Count),
    maplist(=(Char), Chars),
    atom_chars(Atom, Chars),
    atom_string(Atom, Text).

:- end_tests(rlm_conversation_warm).
