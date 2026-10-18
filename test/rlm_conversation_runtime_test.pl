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

test(concurrent_auto_warm_rechecks_coverage) :-
    with_runtime(concurrent_warm_case).
concurrent_warm_case(C, Store) :-
    forall(between(1,8,_), rlm:conversation_append(C, message(user,"old"), ok(_))),
    setup_call_cleanup(message_queue_create(Q),
        concurrent_warm_workers(C, Store, Q), message_queue_destroy(Q)).
concurrent_warm_workers(C, Store, Q) :-
    Options = [warm_store(Store),auto_warm([trigger(message_count),
       min_batch_messages(1),max_batch_messages(1),keep_recent_messages(0),
       generator(plunit_rlm_conversation_runtime:warm_generator)])],
    findall(T, (between(1,8,_), thread_create(
       (thread_send_message(Q,ready), thread_get_message(start),
        rlm_conversation_runtime:maybe_publish_auto_warm(C, Options, Status),
        thread_send_message(Q,result(Status))), T, [])), Threads),
    forall(between(1,8,_), thread_get_message(Q,ready)),
    maplist(start_warm_worker, Threads),
    findall(R, (between(1,8,_), thread_get_message(Q,result(S)), R=S.source_range), Ranges),
    maplist(join_warm_worker, Threads),
    sort(Ranges, Unique), assertion(length(Unique,8)),
    rlm:conversation_warm_list(C, Store, [history(true)], ok(Artifacts)),
    assertion(length(Artifacts,8)),
    rlm:conversation_stats(C, ok(Stats)), assertion(Stats.messages =:= 8).
start_warm_worker(T) :- thread_send_message(T,start).
join_warm_worker(T) :- thread_join(T,true).

test(auto_warm_accounts_pending_message) :-
    with_runtime(pending_pressure_case).
pending_pressure_case(C, Store) :-
    long_text(a, 180, Old),
    forall(between(1,4,_), rlm:conversation_append(C, message(user,Old), ok(_))),
    long_text(b, 400, Pending),
    rlm:conversation_turn(C, message(user,Pending),
        [context_options([warm_store(Store), cold_history_boundary(false),
          policy([max_context_tokens(1000),reserve_output_tokens(0),
                  safety_margin_tokens(0),min_recent_turns(1)]),
          token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
          auto_warm([min_batch_messages(1),max_batch_messages(3),keep_recent_messages(1),
                     generator(plunit_rlm_conversation_runtime:warm_generator)])]),
         completion_options([planner_handler(plunit_rlm_conversation_runtime:plain_planner)])], ok(Turn)),
    assertion(Turn.context.auto_warm.published == true),
    assertion(Turn.context.omitted_units =:= 0),
    rlm:conversation_stats(C, ok(Stats)), assertion(Stats.messages =:= 6).
plain_planner(_, ok(planner_output{plan:plan([final(literal("ok"))]),
                                  usage:json{total_tokens:2}})).

test(failed_compaction_preserves_incoming_message_and_known_usage) :-
    with_runtime(failed_generation_case).
failed_generation_case(C, Store) :-
    rlm:conversation_append(C, message(user,"old"), ok(_)),
    rlm:conversation_turn(C, message(user,"preserve incoming"),
       [context_options([warm_store(Store),auto_warm([trigger(message_count),
          min_batch_messages(1),max_batch_messages(1),keep_recent_messages(0),
          completion_options([planner_handler(plunit_rlm_conversation_runtime:over_budget_planner),
                              planner_attempts(1),budget(_{max_total_tokens:8192})])])])],
       error(Error)),
    rlm:conversation_messages(C, all, [], ok(Messages)),
    assertion(length(Messages,2)),
    last(Messages, Last), assertion(Last.content == "preserve incoming"),
    assertion(Error.auto_warm.reason == failed),
    assertion(Error.auto_warm.generation.usage.total_tokens =:= 9000),
    assertion(Error.user_ref == Last.ref).
over_budget_planner(_, ok(planner_output{plan:plan([final(literal("invalid summary"))]),
                                        usage:_{total_tokens:9000}})).

test(invalid_generated_summary_retains_paid_usage) :-
    with_runtime(invalid_summary_case).
invalid_summary_case(C, Store) :-
    rlm:conversation_append(C,message(user,"old"),ok(_)),
    rlm:conversation_warm_publish(C,Store,range(1,1),
        [completion_options([planner_handler(plunit_rlm_conversation_runtime:plain_planner)])],
        error(Error)),
    assertion(Error.generation.usage.total_tokens =:= 2).

test(failed_turn_retains_compaction_provenance) :-
    with_runtime(failed_compaction_case).
failed_compaction_case(C, Store) :-
    rlm:conversation_append(C, message(user,"old"), ok(_)),
    rlm:conversation_turn(C, message(user,"new"),
       [context_options([warm_store(Store),auto_warm([trigger(message_count),
          min_batch_messages(1),max_batch_messages(1),keep_recent_messages(0),
          generator(plunit_rlm_conversation_runtime:warm_generator)])]),
        completion_options([planner_handler(plunit_rlm_conversation_runtime:failed_planner),
                            planner_attempts(1)])], error(Error)),
    assertion(Error.auto_warm.published == true),
    assertion(Error.auto_warm.source_range == range(1,1)).
failed_planner(_, error(fixture_failure)).

test(managed_native_strategy_calls_native_model_and_retains_history) :-
    with_runtime(native_turn_case).

native_turn_case(Conversation, _) :-
    rlm:conversation_append(Conversation, message(user, "remember original"), ok(Original)),
    rlm:conversation_turn(Conversation, message(user, "continue"),
        [strategy(native), completion_options([
            model_handler(plunit_rlm_conversation_runtime:native_model),
            capabilities([model(openrouter)]), skill_mode(off)])], ok(Turn)),
    assertion(Turn.assistant.content == "native reply"),
    assertion(Turn.completion.turns =:= 1),
    rlm:conversation_message(Conversation, 1, ok(Restored)),
    assertion(Restored == Original).

native_model(Request, ok(Response)) :-
    last(Request.messages, Message),
    assertion(sub_string(Message.content, _, _, _, "remember original")),
    Response = model_response{text:"native reply", tool_calls:[],
        usage:json{prompt_tokens:10, completion_tokens:2, total_tokens:12}}.

test(auto_warm_fills_gap_before_existing_partial_summary) :-
    with_runtime(warm_gap_case).

warm_gap_case(Conversation, Store) :-
    forall(between(1, 6, N),
           (format(string(Text), "message ~d", [N]),
            rlm:conversation_append(Conversation, message(user, Text), ok(_)))),
    Generator = generator(plunit_rlm_conversation_runtime:warm_generator),
    rlm:conversation_warm_publish(Conversation, Store, range(3,4), [Generator], ok(_)),
    rlm_conversation_runtime:maybe_publish_auto_warm(Conversation,
        [warm_store(Store), auto_warm([trigger(message_count), min_batch_messages(1), max_batch_messages(6),
                                     keep_recent_messages(0), Generator])], Status),
    assertion(Status.source_range == range(1,2)),
    rlm_conversation_runtime:maybe_publish_auto_warm(Conversation,
        [warm_store(Store), auto_warm([trigger(message_count), min_batch_messages(1), max_batch_messages(6),
                                     keep_recent_messages(0), Generator])], Next),
    assertion(Next.source_range == range(5,6)),
    rlm:conversation_stats(Conversation, ok(Stats)),
    assertion(Stats.messages =:= 6).

test(auto_warm_does_not_spend_when_history_fits) :-
    with_runtime(warm_no_pressure_case).
warm_no_pressure_case(Conversation, Store) :-
    forall(between(1, 300, _),
           rlm:conversation_append(Conversation, message(user, "short"), ok(_))),
    rlm_conversation_runtime:maybe_publish_auto_warm(Conversation,
        [warm_store(Store), auto_warm([])], Status),
    assertion(Status.reason == context_fits),
    rlm:conversation_stats(Conversation, ok(Stats)),
    assertion(Stats.messages =:= 300),
    rlm:conversation_context_pack(Conversation, [cold_history_boundary(false)], ok(Pack)),
    assertion(length(Pack.selected, 300)).

test(auto_warm_publishes_only_under_context_pressure) :-
    with_runtime(warm_pressure_case).
warm_pressure_case(Conversation, Store) :-
    long_text(a, 800, Text),
    forall(between(1, 4, _),
           rlm:conversation_append(Conversation, message(user, Text), ok(_))),
    rlm_conversation_runtime:maybe_publish_auto_warm(Conversation,
        [warm_store(Store), cold_history_boundary(false),
         policy([max_context_tokens(1000), reserve_output_tokens(0),
                 safety_margin_tokens(0), min_recent_turns(1)]),
         token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
         auto_warm([min_batch_messages(1), max_batch_messages(2), keep_recent_messages(1),
                    generator(plunit_rlm_conversation_runtime:warm_generator)])], Status),
    assertion(Status.source_range == range(1,2)),
    rlm:conversation_message(Conversation, 1, ok(Original)),
    assertion(Original.content == Text).

test(opt_in_auto_warm_publishes_once_and_preserves_exact_history) :-
    with_runtime(auto_warm_publish_case).

auto_warm_publish_case(Conversation, ArtifactStore) :-
    rlm:conversation_append(Conversation, message(user, "old one"), ok(First)),
    rlm:conversation_append(Conversation, message(assistant, "old two"), ok(_)),
    rlm:conversation_append(Conversation, message(user, "old three"), ok(_)),
    rlm:conversation_append(Conversation, message(assistant, "old four"), ok(_)),
    boundary_policy(Policy),
    Auto = [trigger(message_count), min_batch_messages(3),
            max_batch_messages(3),
            keep_recent_messages(1),
            generator(plunit_rlm_conversation_runtime:warm_generator),
            token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)])],
    Options = [context_options([
                 policy(Policy),
                 warm_store(ArtifactStore),
                 auto_warm(Auto),
                 token_options([token_counter(plunit_rlm_conversation_runtime:char_counter)]),
                 cold_history_boundary(false)
              ]),
              completion_options([
                 planner_handler(plunit_rlm_conversation_runtime:auto_warm_planner),
                 planner_attempts(1)
              ])],
    rlm:conversation_turn(Conversation, message(user, "continue"), Options, ok(Turn1)),
    assertion(Turn1.assistant.content == "AUTO_WARM_OK"),
    assertion(Turn1.context.auto_warm.published == true),
    assertion(Turn1.context.auto_warm.source_range == range(1,3)),
    assertion(Turn1.context.warm.loaded_units =:= 1),
    rlm:conversation_warm_list(Conversation, ArtifactStore, [history(true)], ok(Artifacts1)),
    assertion(length(Artifacts1, 1)),
    rlm:conversation_turn(Conversation, message(user, "continue again"), Options, ok(Turn2)),
    assertion(Turn2.assistant.content == "AUTO_WARM_OK"),
    assertion(Turn2.context.auto_warm.published == false),
    rlm:conversation_warm_list(Conversation, ArtifactStore, [history(true)], ok(Artifacts2)),
    assertion(length(Artifacts2, 1)),
    rlm:conversation_message(Conversation, 1, ok(Restored)),
    assertion(Restored.ref == First.ref),
    assertion(Restored.content == "old one").

test(auto_warm_without_store_fails_before_turn_append) :-
    with_runtime(auto_warm_missing_store_case).

auto_warm_missing_store_case(Conversation, _ArtifactStore) :-
    rlm:conversation_turn(
        Conversation, message(user, "cannot compact"),
        [context_options([auto_warm([trigger(message_count), min_batch_messages(1)])])],
        error(Error)),
    assertion(Error.kind == conversation_runtime_fault),
    assertion(Error.detail == auto_warm_requires_store),
    rlm:conversation_stats(Conversation, ok(Stats)),
    assertion(Stats.messages =:= 0).

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

auto_warm_planner(Request, ok(Output)) :-
    Request.messages = [_, System, Message],
    assertion(System.role == system),
    assertion(Message.role == user),
    assertion(sub_string(Message.content, _, _, _, "continue")),
    Plan = plan([final(literal("AUTO_WARM_OK"))]),
    Output = planner_output{
                 plan:Plan,
                 usage:json{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

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
