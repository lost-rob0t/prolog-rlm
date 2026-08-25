:- begin_tests(rlm_conversation).

:- meta_predicate with_memory_conversation(1).

:- use_module('../prolog/rlm_conversation').

with_memory_conversation(Goal) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        ( conversation_create(Store,
                              [id(test_conversation)],
                              ok(Conversation)),
          call(Goal, Conversation)
        ),
        conversation_store_close(Store, _)).

test(full_transcript_is_append_only_and_ordered) :-
    with_memory_conversation(full_transcript_case).

full_transcript_case(Conversation) :-
    conversation_append(Conversation,
                        message(user, "first"),
                        ok(M1)),
    conversation_append(Conversation,
                        message(assistant, "second"),
                        ok(M2)),
    conversation_append(Conversation,
                        message(user, "third"),
                        ok(M3)),
    assertion(M1.sequence =:= 1),
    assertion(M2.sequence =:= 2),
    assertion(M3.sequence =:= 3),
    conversation_messages(Conversation, all, [], ok(Messages)),
    findall(Sequence,
            ( member(Message, Messages), Sequence = Message.sequence ),
            Sequences),
    assertion(Sequences == [1,2,3]),
    conversation_message(Conversation, 2, ok(Exact)),
    assertion(Exact.content == "second").

test(store_lists_reopenable_conversations) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        conversation_list_case(Store),
        conversation_store_close(Store, _)).

conversation_list_case(Store) :-
    ExpectedAlpha = rlm_anonymous_dict{
                        nested:rlm_anonymous_dict{enabled:true},
                        project:"one"
                    },
    conversation_create(Store,
                        [ id(alpha),
                          metadata(_{project:"one", nested:_{enabled:true}})
                        ],
                        ok(Alpha)),
    assertion(Alpha.metadata == ExpectedAlpha),
    conversation_create(Store,
                        [id(beta), metadata(_{project:"two"})],
                        ok(_)),
    conversation_list(Store, [order(asc)], ok(Ascending)),
    findall(Id,
            ( member(Conversation, Ascending), Id = Conversation.id ),
            AscendingIds),
    msort(AscendingIds, SortedIds),
    assertion(SortedIds == [alpha,beta]),
    conversation_list(Store, [order(desc), limit(1)], ok([Latest])),
    assertion(memberchk(Latest.id, [alpha,beta])),
    conversation_open(Store, Latest.id, ok(Reopened)),
    assertion(Reopened.id == Latest.id),
    assertion(Reopened.metadata == Latest.metadata),
    conversation_open(Store, alpha, ok(ReopenedAlpha)),
    assertion(ReopenedAlpha.metadata == ExpectedAlpha).

test(named_metadata_tag_is_preserved) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        ( conversation_create(Store,
                              [id(named_metadata), metadata(project{one:1})],
                              ok(Conversation)),
          assertion(Conversation.metadata == project{one:1})
        ),
        conversation_store_close(Store, _)).

test(variable_metadata_fails_before_backend_create) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        variable_metadata_case(Store),
        conversation_store_close(Store, _)).

variable_metadata_case(Store) :-
    conversation_create(Store,
                        [id(reusable_after_rejection), metadata(meta{value:_})],
                        error(Error)),
    assertion(Error.kind == conversation_error),
    assertion(Error.detail == invalid_metadata(non_ground_value)),
    conversation_create(Store,
                        [id(reusable_after_rejection), metadata(meta{value:ok})],
                        ok(_)).

test(cyclic_metadata_fails_before_backend_create) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        cyclic_metadata_case(Store),
        conversation_store_close(Store, _)).

cyclic_metadata_case(Store) :-
    Cycle = cycle(Cycle),
    conversation_create(Store,
                        [id(reusable_after_cycle), metadata(meta{value:Cycle})],
                        error(Error)),
    assertion(Error.kind == conversation_error),
    assertion(Error.detail == invalid_metadata(cyclic_value)),
    conversation_create(Store,
                        [id(reusable_after_cycle), metadata(meta{value:ok})],
                        ok(_)).

test(history_selectors_and_search_address_old_turns) :-
    with_memory_conversation(history_search_case).

history_search_case(Conversation) :-
    conversation_append(Conversation,
                        message(user, "design the CouchDB lease path"),
                        ok(_)),
    conversation_append(Conversation,
                        message(assistant, "use fencing tokens"),
                        ok(_)),
    conversation_append(Conversation,
                        message(user, "now work on Tree-sitter"),
                        ok(_)),
    conversation_messages(Conversation,
                          range(1,2),
                          [],
                          ok(Range)),
    length(Range, 2),
    conversation_messages(Conversation,
                          recent(1),
                          [],
                          ok([Recent])),
    assertion(Recent.sequence =:= 3),
    conversation_search(Conversation,
                        "couchdb",
                        [],
                        ok([Match])),
    assertion(Match.sequence =:= 1).

test(inverted_history_range_fails_structurally) :-
    with_memory_conversation(inverted_range_case).

inverted_range_case(Conversation) :-
    conversation_append(Conversation, message(user, "one"), ok(_)),
    conversation_messages(Conversation,
                          range(3,1),
                          [],
                          error(Error)),
    assertion(Error.phase == messages),
    assertion(Error.kind == conversation_error).

test(context_eviction_never_deletes_original_transcript) :-
    with_memory_conversation(context_eviction_case).

context_eviction_case(Conversation) :-
    long_text(a, A),
    long_text(b, B),
    long_text(c, C),
    conversation_append(Conversation, message(user, A), ok(_)),
    conversation_append(Conversation, message(assistant, B), ok(_)),
    conversation_append(Conversation, message(user, C), ok(_)),
    Policy = context_policy{max_context_tokens:120,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny},
    conversation_context_pack(Conversation,
                              [policy(Policy)],
                              ok(Pack)),
    length(Pack.selected, SelectedCount),
    assertion(SelectedCount < 3),
    last(Pack.selected, LatestSelection),
    assertion(LatestSelection.value.sequence =:= 3),
    assertion(Pack.ledger.limit =:= 120),
    assertion(Pack.ledger.total_tokens =< 120),
    conversation_messages(Conversation, all, [], ok(FullTranscript)),
    length(FullTranscript, 3).

test(full_export_keeps_original_message_payloads) :-
    with_memory_conversation(export_case).

export_case(Conversation) :-
    conversation_append(Conversation,
                        message(system, "project rule"),
                        ok(_)),
    conversation_append(Conversation,
                        message(user, "hello"),
                        ok(_)),
    conversation_export(Conversation, term, ok(Export)),
    Export.messages = [System, User],
    assertion(System.role == system),
    assertion(System.content == "project rule"),
    assertion(User.role == user),
    assertion(User.content == "hello").

test(persistent_conversation_survives_close_and_reopen) :-
    tmp_file(conversation_persist_test, File),
    setup_call_cleanup(
        true,
        persistent_reopen_case(File),
        cleanup_file(File)).

persistent_reopen_case(File) :-
    ExpectedMetadata = rlm_anonymous_dict{
                           nested:rlm_anonymous_dict{enabled:true},
                           project:"durable"
                       },
    conversation_store_open(persist(File), ok(Store1)),
    conversation_create(Store1,
                        [ id(durable_conversation),
                          metadata(_{
                              project:"durable",
                              nested:_{enabled:true}
                          })
                        ],
                        ok(Conversation1)),
    assertion(Conversation1.metadata == ExpectedMetadata),
    conversation_append(Conversation1,
                        message(user, "survives restart"),
                        ok(Original)),
    conversation_store_close(Store1, ok(closed)),
    conversation_store_open(persist(File), ok(Store2)),
    conversation_open(Store2,
                      durable_conversation,
                      ok(Conversation2)),
    assertion(Conversation2.metadata == ExpectedMetadata),
    conversation_message(Conversation2, 1, ok(Restored)),
    assertion(Restored.ref == Original.ref),
    assertion(Restored.content == "survives restart"),
    conversation_list(Store2, [], ok([Listed])),
    assertion(Listed.id == durable_conversation),
    conversation_store_close(Store2, ok(closed)).

long_text(Char, Text) :-
    length(Chars, 220),
    maplist(=(Char), Chars),
    atom_chars(Atom, Chars),
    atom_string(Atom, Text).

cleanup_file(File) :-
    catch(delete_file(File), _, true).

:- end_tests(rlm_conversation).
