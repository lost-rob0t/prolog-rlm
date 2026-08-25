:- begin_tests(rlm_conversation_cold).

:- meta_predicate with_cold_conversation(1).

:- use_module('../prolog/rlm_context').
:- use_module('../prolog/rlm_conversation').

with_cold_conversation(Goal) :-
    setup_call_cleanup(
        conversation_store_open(memory, ok(Store)),
        ( conversation_create(Store,
                              [id(cold_test)],
                              ok(Conversation)),
          call(Goal, Conversation)
        ),
        conversation_store_close(Store, _)).

test(old_evicted_turn_remains_searchable_through_opaque_context) :-
    with_cold_conversation(cold_search_case).

cold_search_case(Conversation) :-
    long_text_with_needle(Old),
    conversation_append(Conversation, message(user, Old), ok(OldRecord)),
    conversation_append(Conversation, message(assistant, "middle"), ok(_)),
    conversation_append(Conversation, message(user, "current"), ok(_)),
    Policy = context_policy{max_context_tokens:80,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny},
    conversation_context_pack(
        Conversation,
        [ policy(Policy),
          token_options([token_counter(plunit_rlm_conversation_cold:char_counter)])
        ],
        ok(Pack)),
    get_dict(selected, Pack, Selected),
    get_dict(sequence, OldRecord, OldSequence),
    assertion(\+ selected_sequence(Selected, OldSequence)),
    conversation_cold_context(Conversation, [], ok(ColdRef)),
    get_dict(handle, ColdRef, ColdHandle),
    context_metadata(ColdHandle, ok(MetadataRef)),
    get_dict(metadata, MetadataRef, Metadata),
    get_dict(backend, Metadata, Backend),
    assertion(Backend == adapter(conversation)),
    get_dict(source, Metadata, Source),
    get_dict(conversation_id, Source, cold_test),
    context_search(ColdHandle,
                   "ancient-needle",
                   [max_results(4), max_bytes(4096)],
                   ok(Search)),
    get_dict(value, Search, [Match]),
    get_dict(sequence, Match, MatchSequence),
    assertion(MatchSequence =:= OldSequence),
    get_dict(content, Match, MatchContent),
    assertion(sub_string(MatchContent, _, _, _, "ancient-needle")),
    context_delete(ColdHandle, ok(_)),
    conversation_message(Conversation,
                         OldSequence,
                         ok(Restored)),
    get_dict(content, Restored, RestoredContent),
    assertion(RestoredContent == Old).

test(managed_turn_keeps_old_history_out_of_planner_prompt_but_can_search_it) :-
    with_cold_conversation(managed_cold_turn_case).

managed_cold_turn_case(Conversation) :-
    long_text_with_needle(Old),
    conversation_append(Conversation, message(user, Old), ok(_)),
    conversation_append(Conversation, message(assistant, "middle"), ok(_)),
    Policy = context_policy{max_context_tokens:120,
                            provider_context_tokens:1000000,
                            reserve_output_tokens:10,
                            safety_margin_tokens:5,
                            min_recent_turns:1,
                            overflow:deny},
    conversation_turn(
        Conversation,
        message(user, "find the old marker"),
        [ context_options([
              policy(Policy),
              token_options([token_counter(plunit_rlm_conversation_cold:char_counter)])
          ]),
          completion_options([
              planner_handler(plunit_rlm_conversation_cold:cold_search_planner),
              planner_attempts(1),
              context_options([max_results(4), max_bytes(4096)])
          ])
        ],
        ok(Turn)),
    assertion(sub_string(Turn.assistant.content,
                         _, _, _,
                         "ancient-needle")),
    conversation_messages(Conversation, all, [], ok(Messages)),
    length(Messages, 4).

test(persistent_conversation_can_reopen_new_cold_handle_without_transcript_copy) :-
    tmp_file(cold_context_persist, File),
    setup_call_cleanup(
        true,
        persistent_cold_reopen_case(File),
        cleanup_file(File)).

persistent_cold_reopen_case(File) :-
    conversation_store_open(persist(File), ok(Store1)),
    conversation_create(Store1,
                        [id(cold_persist)],
                        ok(Conversation1)),
    conversation_append(Conversation1,
                        message(user, "durable ancient-needle"),
                        ok(_)),
    conversation_cold_context(Conversation1, [], ok(FirstRef)),
    get_dict(handle, FirstRef, FirstHandle),
    context_delete(FirstHandle, ok(_)),
    conversation_store_close(Store1, ok(closed)),
    conversation_store_open(persist(File), ok(Store2)),
    conversation_open(Store2, cold_persist, ok(Conversation2)),
    conversation_cold_context(Conversation2, [], ok(SecondRef)),
    get_dict(handle, SecondRef, SecondHandle),
    context_search(SecondHandle,
                   "ancient-needle",
                   [],
                   ok(Search)),
    get_dict(value, Search, [Match]),
    get_dict(sequence, Match, Sequence),
    assertion(Sequence =:= 1),
    context_delete(SecondHandle, ok(_)),
    conversation_store_close(Store2, ok(closed)).

cold_search_planner(Request, ok(Output)) :-
    Request.messages = [System, Message],
    assertion(System.role == system),
    assertion(Message.role == user),
    assertion(\+ sub_string(Message.content,
                            _, _, _,
                            "ancient-needle")),
    assertion(sub_string(Message.content,
                         _, _, _,
                         "adapter(conversation)")),
    Plan = plan([
        context(input(context), search("ancient-needle"), found),
        final(var(found))
    ]),
    Output = planner_output{
                 plan:Plan,
                 usage:json{prompt_tokens:1,
                         completion_tokens:1,
                         total_tokens:2,
                         cost:0.0}
             }.

selected_sequence(Selections, Sequence) :-
    member(Selection, Selections),
    get_dict(section, Selection, conversation),
    get_dict(value, Selection, Value),
    get_dict(sequence, Value, FoundSequence),
    FoundSequence =:= Sequence.

char_counter(Text, Tokens) :-
    string_length(Text, Tokens).

long_text_with_needle(Text) :-
    length(Chars, 220),
    maplist(=(x), Chars),
    atom_chars(Prefix, Chars),
    format(string(Text), "~w ancient-needle", [Prefix]).

cleanup_file(File) :-
    catch(delete_file(File), _, true).

:- end_tests(rlm_conversation_cold).
