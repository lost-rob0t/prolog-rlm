:- begin_tests(rlm_conversation_runtime).

:- use_module('../prolog/rlm', []).
:- use_module('../prolog/rlm_artifact', []).
:- use_module('../prolog/rlm_conversation', []).
:- use_module('../prolog/rlm_conversation_warm', []).

:- meta_predicate with_runtime(2).

with_runtime(Goal) :-
    setup_call_cleanup(
        ( rlm:conversation_store_open(memory, ok(ConversationStore)),
          rlm:artifact_store_open(memory, ok(ArtifactStore))
        ),
        ( rlm:conversation_create(ConversationStore,
                                  [id(runtime_warm_test)],
                                  ok(Conversation)),
          call(Goal, Conversation, ArtifactStore)
        ),
        ( rlm:artifact_store_close(ArtifactStore, _),
          rlm:conversation_store_close(ConversationStore, _)
        )).

test(public_context_pack_loads_existing_warm_without_manual_context_units) :-
    with_runtime(warm_pack_case).

warm_pack_case(Conversation, ArtifactStore) :-
    publish_old_warm_context(Conversation, ArtifactStore),
    rlm:conversation_append(Conversation, message(user, "current"), ok(_)),
    tight_policy(Policy),
    rlm:conversation_context_pack(
        Conversation,
        [ policy(Policy),
          token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
          warm_store(ArtifactStore),
          warm_options([policy(json{max_candidates:8})]),
          cold_history_boundary(false)
        ],
        ok(Pack)),
    assertion(Pack.warm.configured == true),
    assertion(Pack.warm.loaded_units =:= 1),
    findall(Id-Kind,
            ( member(Selection, Pack.selected),
              Id = Selection.id,
              Kind = Selection.kind ),
            Selected),
    assertion(memberchk(conversation_message_3-verbatim, Selected)),
    assertion(memberchk(range_1_2-compact_summary, Selected)),
    assertion(\+ memberchk(conversation_message_1-_, Selected)),
    assertion(\+ memberchk(conversation_message_2-_, Selected)),
    assertion(Pack.ledger.total_tokens =< Policy.max_context_tokens).

test(public_managed_turn_reuses_warm_but_never_auto_compacts) :-
    with_runtime(warm_turn_case).

warm_turn_case(Conversation, ArtifactStore) :-
    publish_old_warm_context(Conversation, ArtifactStore),
    rlm:conversation_warm_list(Conversation,
                               ArtifactStore,
                               [history(true)],
                               ok(BeforeArtifacts)),
    length(BeforeArtifacts, BeforeCount),
    tight_policy(Policy),
    rlm:conversation_turn(
        Conversation,
        message(user, "continue using the old architecture"),
        [ context_options([
              policy(Policy),
              token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
              warm_store(ArtifactStore),
              warm_options([policy(json{max_candidates:8})]),
              cold_history_boundary(false)
          ]),
          completion_options([
              planner_handler(plunit_rlm_conversation_runtime:warm_loaded_planner),
              planner_attempts(1)
          ])
        ],
        ok(Turn)),
    assertion(Turn.assistant.content == "WARM_OK"),
    assertion(Turn.context.warm.configured == true),
    assertion(Turn.context.warm.loaded_units =:= 1),
    rlm:conversation_warm_list(Conversation,
                               ArtifactStore,
                               [history(true)],
                               ok(AfterArtifacts)),
    length(AfterArtifacts, AfterCount),
    assertion(AfterCount =:= BeforeCount).

test(no_warm_store_means_no_warm_generation_or_loading) :-
    with_runtime(no_warm_store_case).

no_warm_store_case(Conversation, ArtifactStore) :-
    publish_old_warm_context(Conversation, ArtifactStore),
    rlm:conversation_append(Conversation, message(user, "current"), ok(_)),
    tight_policy(Policy),
    rlm:conversation_context_pack(
        Conversation,
        [ policy(Policy),
          token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
          cold_history_boundary(false)
        ],
        ok(Pack)),
    get_dict(warm, Pack, Warm),
    get_dict(configured, Warm, false),
    get_dict(loaded_units, Warm, LoadedUnits),
    assertion(LoadedUnits =:= 0),
    get_dict(selected, Pack, Selected),
    assertion(\+ ( member(Selection, Selected),
                    get_dict(section, Selection, warm) )).

test(context_pack_adds_token_accounted_cold_history_boundary) :-
    with_runtime(cold_boundary_pack_case).

cold_boundary_pack_case(Conversation, _ArtifactStore) :-
    rlm:conversation_append(Conversation, message(user, "old one"), ok(_)),
    rlm:conversation_append(Conversation, message(assistant, "old two"), ok(_)),
    rlm:conversation_append(Conversation, message(user, "current"), ok(_)),
    boundary_policy(Policy),
    rlm:conversation_context_pack(
        Conversation,
        [ policy(Policy),
          token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)])
        ],
        ok(Pack)),
    Boundary = Pack.cold_history_boundary,
    assertion(Boundary.configured == true),
    assertion(Boundary.active == true),
    assertion(Boundary.cold_range == range(1,2)),
    assertion(Boundary.guaranteed_hot_start =:= 3),
    member(Selection, Pack.selected),
    Selection.id == managed_cold_history_boundary,
    assertion(Selection.section == cold_history_boundary),
    assertion(Selection.kind == instruction),
    assertion(sub_string(Selection.value.text,
                         _, _, _,
                         "context(input(context), search")),
    member(Stage, Pack.ledger.stages),
    Stage.name == managed_cold_history_boundary,
    assertion(Stage.kind == context_unit),
    assertion(Stage.charged_tokens > 0),
    assertion(Pack.ledger.total_tokens =< Policy.max_context_tokens).

test(managed_turn_exposes_boundary_without_mutating_old_messages) :-
    with_runtime(cold_boundary_turn_case).

cold_boundary_turn_case(Conversation, _ArtifactStore) :-
    rlm:conversation_append(Conversation,
                            message(user, "immutable old user turn"),
                            ok(First)),
    rlm:conversation_append(Conversation,
                            message(assistant, "immutable old assistant turn"),
                            ok(Second)),
    boundary_policy(Policy),
    rlm:conversation_turn(
        Conversation,
        message(user, "refer to something old if needed"),
        [ context_options([
              policy(Policy),
              token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)])
          ]),
          completion_options([
              planner_handler(plunit_rlm_conversation_runtime:cold_boundary_planner),
              planner_attempts(1)
          ])
        ],
        ok(Turn)),
    assertion(Turn.assistant.content == "BOUNDARY_OK"),
    assertion(Turn.context.cold_history_boundary.active == true),
    rlm:conversation_message(Conversation, 1, ok(RestoredFirst)),
    rlm:conversation_message(Conversation, 2, ok(RestoredSecond)),
    assertion(RestoredFirst.ref == First.ref),
    assertion(RestoredFirst.content == "immutable old user turn"),
    assertion(RestoredSecond.ref == Second.ref),
    assertion(RestoredSecond.content == "immutable old assistant turn").

test(boundary_can_be_disabled_explicitly) :-
    with_runtime(boundary_disabled_case).

boundary_disabled_case(Conversation, _ArtifactStore) :-
    rlm:conversation_append(Conversation, message(user, "one"), ok(_)),
    rlm:conversation_append(Conversation, message(assistant, "two"), ok(_)),
    boundary_policy(Policy),
    rlm:conversation_context_pack(
        Conversation,
        [ policy(Policy),
          cold_history_boundary(false)
        ],
        ok(Pack)),
    get_dict(cold_history_boundary, Pack, Boundary),
    get_dict(configured, Boundary, false),
    get_dict(active, Boundary, false),
    get_dict(selected, Pack, Selected),
    assertion(\+ ( member(Selection, Selected),
                    get_dict(id, Selection, managed_cold_history_boundary) )).

publish_old_warm_context(Conversation, ArtifactStore) :-
    long_text(a, 150, OldA),
    long_text(b, 150, OldB),
    rlm:conversation_append(Conversation, message(user, OldA), ok(_)),
    rlm:conversation_append(Conversation, message(assistant, OldB), ok(_)),
    rlm:conversation_warm_publish(
        Conversation,
        ArtifactStore,
        range(1,2),
        [ generator(plunit_rlm_conversation_runtime:warm_generator),
          token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)])
        ],
        ok(_)).

warm_loaded_planner(Request, ok(Output)) :-
    Request.messages = [_, System, Message],
    assertion(System.role == system),
    assertion(Message.role == user),
    assertion(sub_string(Message.content,
                         _, _, _,
                         "Summary: compact useful summary")),
    Plan = plan([final(literal("WARM_OK"))]),
    Output = planner_output{
                 plan:Plan,
                 usage:json{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

cold_boundary_planner(Request, ok(Output)) :-
    Request.messages = [_, System, Message],
    assertion(System.role == system),
    assertion(Message.role == user),
    assertion(sub_string(Message.content,
                         _, _, _,
                         "Cold history boundary:")),
    assertion(sub_string(Message.content,
                         _, _, _,
                         "Sequences 1..2 may be absent")),
    assertion(sub_string(Message.content,
                         _, _, _,
                         "context(input(context), search")),
    Plan = plan([final(literal("BOUNDARY_OK"))]),
    Output = planner_output{
                 plan:Plan,
                 usage:json{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

warm_generator(_Source, _Options,
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
                 files:["one/very/long/file/path.pl",
                        "two/very/long/file/path.pl"],
                 symbols:["symbol_alpha", "symbol_beta"]}).

tight_policy(context_policy{max_context_tokens:180,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny}).

boundary_policy(context_policy{max_context_tokens:2000,
                               provider_context_tokens:1000000,
                               reserve_output_tokens:10,
                               safety_margin_tokens:5,
                               min_recent_turns:1,
                               overflow:deny}).

char_counter(Text, Tokens) :-
    string_length(Text, Tokens).

long_text(Char, Count, Text) :-
    length(Chars, Count),
    maplist(=(Char), Chars),
    atom_chars(Atom, Chars),
    atom_string(Atom, Text).

:- end_tests(rlm_conversation_runtime).
