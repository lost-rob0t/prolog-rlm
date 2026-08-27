:- module(rlm_conversation_persist,
          [ conversation_persist_open/1,
            conversation_persist_close/0,
            conversation_persist_create/3,
            conversation_persist_exists/1,
            conversation_persist_append/3,
            conversation_persist_get/3,
            conversation_persist_list/2,
            conversation_persist_header/3,
            conversation_persist_headers/1
          ]).

/** <module> SWI persistency backend for durable conversation transcripts */

:- use_module(library(persistency)).

:- persistent
       conversation_header_record(id:atom,
                                   created_at:float,
                                   metadata:any),
       conversation_sequence_record(id:atom,
                                    next_sequence:integer),
       conversation_message_record(conversation_id:atom,
                                   sequence:integer,
                                   message:any).

conversation_persist_open(File) :-
    with_mutex(rlm_conversation_persist,
               conversation_persist_open_locked(File)).

conversation_persist_open_locked(File) :-
    (   db_attached(Current)
    ->  (   same_file_or_atom(Current, File)
        ->  true
        ;   db_detach,
            db_attach(File, [sync(close)])
        )
    ;   db_attach(File, [sync(close)])
    ).

conversation_persist_close :-
    with_mutex(rlm_conversation_persist,
               (   db_attached(_)
               ->  db_detach
               ;   true
               )).

conversation_persist_create(Id, CreatedAt, Metadata) :-
    require_attached,
    ground(Metadata),
    !,
    with_mutex(rlm_conversation_persist,
               (   conversation_header_record(Id, _, _)
               ->  throw(error(permission_error(create,
                                                 conversation,
                                                 Id),
                               context(rlm_conversation_persist,
                                       conversation_exists(Id))))
                ;   assert_conversation_header_record(Id,
                                                       CreatedAt,
                                                       Metadata),
                    assert_conversation_sequence_record(Id, 1)
                )).
conversation_persist_create(_, _, Metadata) :-
    throw(error(instantiation_error,
                context(rlm_conversation_persist,
                        non_ground_metadata(Metadata)))).

conversation_persist_exists(Id) :-
    require_attached,
    with_mutex(rlm_conversation_persist,
               conversation_header_record(Id, _, _)).

conversation_persist_header(Id, CreatedAt, Metadata) :-
    require_attached,
    with_mutex(rlm_conversation_persist,
               conversation_header_record(Id, CreatedAt, Metadata)).

conversation_persist_headers(Headers) :-
    require_attached,
    with_mutex(rlm_conversation_persist,
               findall(CreatedAt-Id-Metadata,
                       conversation_header_record(Id, CreatedAt, Metadata),
                       Rows0)),
    keysort(Rows0, Rows),
    findall(conversation_header{id:Id,
                                created_at:CreatedAt,
                                metadata:Metadata},
            member(CreatedAt-Id-Metadata, Rows),
            Headers).

conversation_persist_append(Id, BaseMessage, Message) :-
    require_attached,
    ground(BaseMessage),
    !,
    with_mutex(rlm_conversation_persist,
                (   conversation_header_record(Id, _, _)
                ->  next_persist_sequence(Id, Sequence),
                    Ref = conversation_message_ref{conversation_id:Id,
                                                   sequence:Sequence},
                   put_dict(_{ref:Ref, sequence:Sequence},
                            BaseMessage,
                            Message),
                   assert_conversation_message_record(Id,
                                                      Sequence,
                                                      Message)
                ;   throw(error(existence_error(conversation, Id),
                               context(rlm_conversation_persist,
                                       unknown_conversation(Id))))
                )).

conversation_persist_append(_, BaseMessage, _) :-
    throw(error(instantiation_error,
                context(rlm_conversation_persist,
                        non_ground_message(BaseMessage)))).

next_persist_sequence(Id, Sequence) :-
    (   retract_conversation_sequence_record(Id, Next)
    ->  Sequence = Next
    ;   findall(Existing,
                conversation_message_record(Id, Existing, _),
                ExistingSequences),
        next_sequence(ExistingSequences, Sequence)
    ),
    Following is Sequence+1,
    assert_conversation_sequence_record(Id, Following).

conversation_persist_get(Id, Sequence, Message) :-
    require_attached,
    with_mutex(rlm_conversation_persist,
               conversation_message_record(Id, Sequence, Message)).

conversation_persist_list(Id, Messages) :-
    require_attached,
    with_mutex(rlm_conversation_persist,
               findall(Sequence-Message,
                       conversation_message_record(Id, Sequence, Message),
                       Pairs0)),
    keysort(Pairs0, Pairs),
    findall(Message, member(_-Message, Pairs), Messages).

next_sequence([], 1).
next_sequence(Sequences, Sequence) :-
    Sequences \== [],
    max_list(Sequences, Latest),
    Sequence is Latest+1.

require_attached :-
    (   db_attached(_)
    ->  true
    ;   throw(error(existence_error(conversation_persistent_backend,
                                    attached),
                    context(rlm_conversation_persist,
                            'no conversation persistency file is attached')))
    ).

same_file_or_atom(A, B) :-
    A == B,
    !.
same_file_or_atom(A, B) :-
    catch(same_file(A, B), _, fail).
