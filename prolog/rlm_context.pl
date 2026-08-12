:- module(rlm_context,
          [ context_register/3,
            context_metadata/2,
            context_peek/4,
            context_slice/5,
            context_search/4,
            context_partition/4,
            context_map/4,
            context_reduce/4,
            context_delete/2,
            context_trace/3,
            context_backend/2
          ]).

/** <module> Opaque external context runtime

Text and term payloads remain outside model prompts behind versioned opaque
handles. Every public projection is count/byte/time bounded and traceable.
The memory backend never dereferences files, URLs, streams, sockets, or
caller-supplied Prolog goals.
*/

:- use_module(library(uuid)).
:- use_module(library(time)).
:- use_module(library(lists)).

:- dynamic context_record/6.
:- dynamic context_tombstone/2.
:- dynamic context_event/3.

context_backend(memory,
                capabilities{source_kinds:[text, terms],
                             persistent:false,
                             filesystem:false,
                             network:false}).

context_register(Source, Options, Outcome) :-
    catch(context_register_(Source, Options, Outcome),
          Exception,
          structured_context_exception(register, Exception, Outcome)).

context_register_(Source, Options, Outcome) :-
    validate_limits(Options, LimitsOutcome),
    (   LimitsOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   normalize_source(Source, Kind, Payload, SourceOutcome),
        register_source(SourceOutcome, Kind, Payload, Outcome)
    ).

register_source(error(Error), _, _, error(Error)) :-
    !.
register_source(ok(source_stats{bytes:Bytes, items:Items}), Kind, Payload,
                ok(Ref)) :-
    uuid(Id, [version(4)]),
    Version = 1,
    get_time(CreatedAt),
    Metadata = context_metadata{backend:memory,
                                kind:Kind,
                                bytes:Bytes,
                                items:Items,
                                version:Version,
                                created_at:CreatedAt},
    with_mutex(rlm_context_store,
               ( retractall(context_tombstone(Id, _)),
                 assertz(context_record(Id, Version, Kind, Payload,
                                        Metadata, CreatedAt))
               )),
    Handle = context_handle(Id, Version),
    Ref = context_ref{handle:Handle, metadata:Metadata}.

normalize_source(text(Text0), text, Text, Outcome) :-
    !,
    (   text_to_string_safe(Text0, Text)
    ->  utf8_size(Text, Bytes),
        text_item_count(Text, Items),
        Outcome = ok(source_stats{bytes:Bytes, items:Items})
    ;   Outcome = error(context_error{operation:register,
                                      kind:invalid_source,
                                      expected:text,
                                      message:"text source must contain atom/string text"})
    ).
normalize_source(terms(Terms), terms, Terms, Outcome) :-
    !,
    (   is_list(Terms)
    ->  terms_utf8_size(Terms, Bytes),
        length(Terms, Items),
        Outcome = ok(source_stats{bytes:Bytes, items:Items})
    ;   Outcome = error(context_error{operation:register,
                                      kind:invalid_source,
                                      expected:list,
                                      message:"terms source must contain a proper list"})
    ).
normalize_source(Source, unknown, none,
                 error(context_error{operation:register,
                                     kind:unsupported_source,
                                     source_shape:Shape,
                                     message:"only text(Text) and terms(List) are accepted"})) :-
    source_shape(Source, Shape).

source_shape(Source, Functor/Arity) :-
    compound(Source),
    !,
    functor(Source, Functor, Arity).
source_shape(Source, Type) :-
    (   atom(Source) -> Type = atom
    ;   string(Source) -> Type = string
    ;   number(Source) -> Type = number
    ;   var(Source) -> Type = variable
    ;   Type = other
    ).

context_metadata(Handle, Outcome) :-
    resolve_handle(Handle, Resolved),
    (   Resolved = ok(record(_, _, _, _, Metadata, _))
    ->  Outcome = ok(context_ref{handle:Handle, metadata:Metadata})
    ;   Resolved = error(Error),
        Outcome = error(Error)
    ).

context_peek(Handle, Selector, Options, Outcome) :-
    run_operation(Handle, peek(Selector), Options, Outcome).

context_slice(Handle, Start, Length, Options, Outcome) :-
    run_operation(Handle, slice(Start, Length), Options, Outcome).

context_search(Handle, Pattern0, Options, Outcome) :-
    (   text_to_string_safe(Pattern0, Pattern),
        Pattern \== ""
    ->  run_operation(Handle, search(Pattern), Options, Outcome)
    ;   Outcome = error(context_error{operation:search,
                                      kind:invalid_pattern,
                                      message:"search pattern must be non-empty text"})
    ).

context_partition(Handle, Strategy, Options, Outcome) :-
    run_operation(Handle, partition(Strategy), Options, Outcome).

context_map(Handle, Transform, Options, Outcome) :-
    run_operation(Handle, map(Transform), Options, Outcome).

context_reduce(Handle, Reducer, Options, Outcome) :-
    run_operation(Handle, reduce(Reducer), Options, Outcome).

run_operation(Handle, Operation, Options, Outcome) :-
    resolve_handle(Handle, Resolved),
    (   Resolved = error(Error)
    ->  Outcome = error(Error)
    ;   validate_limits(Options, LimitsOutcome),
        run_resolved(LimitsOutcome, Resolved, Handle, Operation, Outcome)
    ).

run_resolved(error(Error), _, _, _, error(Error)) :-
    !.
run_resolved(ok(Limits),
             ok(record(Id, Version, Kind, Payload, Metadata, _)),
             Handle, Operation, Outcome) :-
    get_time(Start),
    catch(run_timed_operation(Limits, Operation, Kind, Payload, Metadata,
                              WorkOutcome),
          Exception,
          WorkOutcome = exception(Exception)),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    finalize_work(WorkOutcome, Id, Version, Handle, Operation, ElapsedMs,
                  Outcome).

run_timed_operation(Limits, Operation, Kind, Payload, Metadata, WorkOutcome) :-
    get_dict(time_limit, Limits, TimeLimit),
    (   call_with_time_limit(TimeLimit,
                             once(operation_work(Operation, Kind, Payload,
                                                 Metadata, Limits, Work)))
    ->  WorkOutcome = work(Work)
    ;   WorkOutcome = exception(context_fault(internal_failure(Operation)))
    ).

operation_work(peek(Selector), Kind, Payload, Metadata, Limits, Work) :-
    !,
    peek_work(Selector, Kind, Payload, Metadata, Limits, Work).
operation_work(slice(Start, Length), Kind, Payload, _, Limits, Work) :-
    !,
    slice_work(Start, Length, Kind, Payload, Limits, Work).
operation_work(search(Pattern), Kind, Payload, _, Limits, Work) :-
    !,
    search_work(Pattern, Kind, Payload, Limits, Work).
operation_work(partition(Strategy), Kind, Payload, _, Limits, Work) :-
    !,
    partition_work(Strategy, Kind, Payload, Limits, Work).
operation_work(map(Transform), Kind, Payload, _, Limits, Work) :-
    !,
    map_work(Transform, Kind, Payload, Limits, Work).
operation_work(reduce(Reducer), Kind, Payload, _, _, Work) :-
    !,
    reduce_work(Reducer, Kind, Payload, Work).
operation_work(Operation, _, _, _, _, _) :-
    throw(context_fault(unsupported_operation(Operation))).

peek_work(metadata, _, _, Metadata, _,
          work{value:Metadata,
               bytes_inspected:0,
               items_inspected:0,
               truncated:false}) :-
    !.
peek_work(head(Count), text, Text, _, Limits, Work) :-
    !,
    require_nonnegative_integer(Count),
    get_dict(max_bytes, Limits, MaxBytes),
    string_length(Text, Total),
    Requested is min(Count, Total),
    sub_string(Text, 0, Requested, _, Raw),
    truncate_text_bytes(Raw, MaxBytes, Value, ByteTruncated),
    utf8_size(Raw, Bytes),
    bool_or([Requested < Count, Requested < Total, ByteTruncated], Truncated),
    Work = work{value:Value,
                bytes_inspected:Bytes,
                items_inspected:1,
                truncated:Truncated}.
peek_work(tail(Count), text, Text, _, Limits, Work) :-
    !,
    require_nonnegative_integer(Count),
    get_dict(max_bytes, Limits, MaxBytes),
    string_length(Text, Total),
    Requested is min(Count, Total),
    Start is Total-Requested,
    sub_string(Text, Start, Requested, 0, Raw),
    truncate_text_bytes(Raw, MaxBytes, Value, ByteTruncated),
    utf8_size(Raw, Bytes),
    bool_or([Requested < Count, Start > 0, ByteTruncated], Truncated),
    Work = work{value:Value,
                bytes_inspected:Bytes,
                items_inspected:1,
                truncated:Truncated}.
peek_work(item(Index), terms, Terms, _, Limits, Work) :-
    !,
    require_nonnegative_integer(Index),
    (   nth0(Index, Terms, Term)
    ->  get_dict(max_bytes, Limits, MaxBytes),
        bounded_term(Term, MaxBytes, Value, Truncated),
        term_utf8_size(Term, Bytes),
        Work = work{value:Value,
                    bytes_inspected:Bytes,
                    items_inspected:1,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Index)))
    ).
peek_work(head(Count), terms, Terms, _, Limits, Work) :-
    !,
    require_nonnegative_integer(Count),
    bounded_term_projection(Terms, 0, Count, Limits, Work).
peek_work(tail(Count), terms, Terms, _, Limits, Work) :-
    !,
    require_nonnegative_integer(Count),
    length(Terms, Total),
    Start is max(0, Total-Count),
    bounded_term_projection(Terms, Start, Count, Limits, Work0),
    get_dict(truncated, Work0, Truncated0),
    bool_or([Start > 0, Truncated0], Truncated),
    put_dict(truncated, Work0, Truncated, Work).
peek_work(Selector, Kind, _, _, _, _) :-
    throw(context_fault(unsupported_selector(Kind, Selector))).

bounded_term_projection(Terms, Start, Count, Limits, Work) :-
    length(Terms, Total),
    (   Start =< Total
    ->  drop_n(Terms, Start, Rest),
        get_dict(max_results, Limits, MaxResults),
        Requested is min(Count, MaxResults),
        take_n(Rest, Requested, Raw),
        get_dict(max_bytes, Limits, MaxBytes),
        bounded_term_list(Raw, MaxBytes, Values, ByteTruncated),
        length(Values, Returned),
        terms_utf8_size(Raw, Bytes),
        length(Raw, Inspected),
        Target is min(Count, max(0, Total-Start)),
        bool_or([Count > MaxResults,
                 Returned < Target,
                 ByteTruncated],
                Truncated),
        Work = work{value:Values,
                    bytes_inspected:Bytes,
                    items_inspected:Inspected,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Start)))
    ).

slice_work(Start, Length, text, Text, Limits, Work) :-
    !,
    require_nonnegative_integer(Start),
    require_nonnegative_integer(Length),
    string_length(Text, Total),
    (   Start =< Total
    ->  Available is Total-Start,
        Requested is min(Length, Available),
        sub_string(Text, Start, Requested, _, Raw),
        get_dict(max_bytes, Limits, MaxBytes),
        truncate_text_bytes(Raw, MaxBytes, Value, ByteTruncated),
        utf8_size(Raw, Bytes),
        bool_or([Requested < Length, ByteTruncated], Truncated),
        Work = work{value:Value,
                    bytes_inspected:Bytes,
                    items_inspected:1,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Start)))
    ).
slice_work(Start, Length, terms, Terms, Limits, Work) :-
    !,
    require_nonnegative_integer(Start),
    require_nonnegative_integer(Length),
    bounded_term_projection(Terms, Start, Length, Limits, Work).
slice_work(_, _, Kind, _, _, _) :-
    throw(context_fault(unsupported_selector(Kind, slice))).

search_work(Pattern, text, Text, Limits, Work) :-
    !,
    split_string(Text, "\n", "", Lines),
    search_sequence(Lines, Pattern, Limits, 0, 0, 0, [],
                    RevMatches, Bytes, Items, Truncated),
    reverse(RevMatches, Matches),
    Work = work{value:Matches,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
search_work(Pattern, terms, Terms, Limits, Work) :-
    !,
    search_sequence(Terms, Pattern, Limits, 0, 0, 0, [],
                    RevMatches, Bytes, Items, Truncated),
    reverse(RevMatches, Matches),
    Work = work{value:Matches,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
search_work(_, Kind, _, _, _) :-
    throw(context_fault(unsupported_selector(Kind, search))).

search_sequence([], _, _, Index, Bytes, _, Matches, Matches,
                Bytes, Index, false) :-
    !.
search_sequence(Items, _, Limits, Index, Bytes, OutBytes, Matches, Matches,
                Bytes, Index, true) :-
    length(Matches, Count),
    get_dict(max_results, Limits, MaxResults),
    get_dict(max_bytes, Limits, MaxBytes),
    (Count >= MaxResults ; OutBytes >= MaxBytes),
    Items \== [],
    !.
search_sequence([Item|Rest], Pattern, Limits, Index0, Bytes0, OutBytes0,
                Matches0, Matches, Bytes, ItemsInspected, Truncated) :-
    item_text(Item, Text),
    utf8_size(Text, ItemBytes),
    Bytes1 is Bytes0+ItemBytes,
    Index1 is Index0+1,
    (   sub_string(Text, _, _, _, Pattern)
    ->  add_search_match(Index0, Text, Limits, OutBytes0,
                         MatchOutcome),
        continue_search_match(MatchOutcome, Rest, Pattern, Limits,
                              Index1, Bytes1, Matches0, Matches,
                              Bytes, ItemsInspected, Truncated)
    ;   search_sequence(Rest, Pattern, Limits, Index1, Bytes1, OutBytes0,
                        Matches0, Matches, Bytes, ItemsInspected, Truncated)
    ).

add_search_match(Index, Text, Limits, OutBytes0, Outcome) :-
    get_dict(max_bytes, Limits, MaxBytes),
    Remaining is MaxBytes-OutBytes0,
    (   Remaining =< 0
    ->  Outcome = stop
    ;   truncate_text_bytes(Text, Remaining, Preview, PreviewTruncated),
        utf8_size(Preview, AddedBytes),
        (   AddedBytes =:= 0
        ->  Outcome = stop
        ;   Match = match{index:Index, value:Preview},
            OutBytes is OutBytes0+AddedBytes,
            Outcome = add(Match, OutBytes, PreviewTruncated)
        )
    ).

continue_search_match(stop, _, _, _, Index, Bytes, Matches, Matches,
                      Bytes, Index, true) :-
    !.
continue_search_match(add(Match, OutBytes, PreviewTruncated), Rest, Pattern,
                      Limits, Index, Bytes0, Matches0, Matches,
                      Bytes, ItemsInspected, Truncated) :-
    Matches1 = [Match|Matches0],
    length(Matches1, Count),
    get_dict(max_results, Limits, MaxResults),
    get_dict(max_bytes, Limits, MaxBytes),
    (   PreviewTruncated == true
    ->  Matches = Matches1,
        Bytes = Bytes0,
        ItemsInspected = Index,
        Truncated = true
    ;   (Count >= MaxResults ; OutBytes >= MaxBytes), Rest \== []
    ->  Matches = Matches1,
        Bytes = Bytes0,
        ItemsInspected = Index,
        Truncated = true
    ;   search_sequence(Rest, Pattern, Limits, Index, Bytes0, OutBytes,
                        Matches1, Matches, Bytes, ItemsInspected, Truncated)
    ).

partition_work(fixed(Size), text, Text, Limits, Work) :-
    !,
    require_positive_integer(Size),
    string_length(Text, TotalChars),
    text_partitions(Text, TotalChars, Size, Limits, 0, 0, 0, [],
                    RevParts, Bytes, Items, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
partition_work(lines(Size), text, Text, Limits, Work) :-
    !,
    require_positive_integer(Size),
    split_string(Text, "\n", "", Lines),
    list_partitions(Lines, Size, Limits, 0, 0, 0, [],
                    RevParts, Bytes, Items, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
partition_work(fixed(Size), terms, Terms, Limits, Work) :-
    !,
    require_positive_integer(Size),
    list_partitions(Terms, Size, Limits, 0, 0, 0, [],
                    RevParts, Bytes, Items, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
partition_work(Strategy, Kind, _, _, _) :-
    throw(context_fault(unsupported_partition(Kind, Strategy))).

text_partitions(_, Total, _, _, Start, Bytes, _, Parts, Parts,
                Bytes, 0, false) :-
    Start >= Total,
    !.
text_partitions(_, _, _, Limits, Start, Bytes, OutBytes, Parts, Parts,
                Bytes, 0, true) :-
    length(Parts, Count),
    get_dict(max_results, Limits, MaxResults),
    get_dict(max_bytes, Limits, MaxBytes),
    (Count >= MaxResults ; OutBytes >= MaxBytes),
    Start >= 0,
    !.
text_partitions(Text, Total, Size, Limits, Start, Bytes0, OutBytes0, Parts0,
                Parts, Bytes, Items, Truncated) :-
    ChunkLength is min(Size, Total-Start),
    sub_string(Text, Start, ChunkLength, _, Raw),
    utf8_size(Raw, RawBytes),
    Bytes1 is Bytes0+RawBytes,
    get_dict(max_bytes, Limits, MaxBytes),
    Remaining is MaxBytes-OutBytes0,
    truncate_text_bytes(Raw, Remaining, Value, ByteTruncated),
    utf8_size(Value, AddedBytes),
    (   AddedBytes =:= 0
    ->  Parts = Parts0,
        Bytes = Bytes1,
        Items = 1,
        Truncated = true
    ;   length(Parts0, PartIndex),
        Part = partition{index:PartIndex,
                         start:Start,
                         length:ChunkLength,
                         value:Value},
        NextStart is Start+ChunkLength,
        OutBytes1 is OutBytes0+AddedBytes,
        (   ByteTruncated == true
        ->  Parts = [Part|Parts0],
            Bytes = Bytes1,
            Items = 1,
            Truncated = true
        ;   text_partitions(Text, Total, Size, Limits, NextStart, Bytes1,
                            OutBytes1, [Part|Parts0], Parts,
                            Bytes, RestItems, Truncated),
            Items is RestItems+1
        )
    ).

list_partitions([], _, _, _, Bytes, _, Parts, Parts, Bytes, 0, false) :-
    !.
list_partitions(Items0, _, Limits, _, Bytes, OutBytes, Parts, Parts,
                Bytes, 0, true) :-
    length(Parts, Count),
    get_dict(max_results, Limits, MaxResults),
    get_dict(max_bytes, Limits, MaxBytes),
    (Count >= MaxResults ; OutBytes >= MaxBytes),
    Items0 \== [],
    !.
list_partitions(Items0, Size, Limits, Offset, Bytes0, OutBytes0, Parts0,
                Parts, Bytes, Items, Truncated) :-
    take_n(Items0, Size, RawChunk),
    length(RawChunk, RawCount),
    terms_utf8_size(RawChunk, RawBytes),
    Bytes1 is Bytes0+RawBytes,
    get_dict(max_bytes, Limits, MaxBytes),
    Remaining is MaxBytes-OutBytes0,
    bounded_term_list(RawChunk, Remaining, Chunk, ByteTruncated),
    length(Chunk, ChunkCount),
    (   ChunkCount =:= 0
    ->  Parts = Parts0,
        Bytes = Bytes1,
        Items = RawCount,
        Truncated = true
    ;   terms_utf8_size(Chunk, AddedBytes),
        length(Parts0, PartIndex),
        Part = partition{index:PartIndex,
                         start:Offset,
                         length:ChunkCount,
                         value:Chunk},
        OutBytes1 is OutBytes0+AddedBytes,
        (   ByteTruncated == true
        ->  Parts = [Part|Parts0],
            Bytes = Bytes1,
            Items = RawCount,
            Truncated = true
        ;   drop_n(Items0, RawCount, Rest),
            NextOffset is Offset+RawCount,
            list_partitions(Rest, Size, Limits, NextOffset, Bytes1,
                            OutBytes1, [Part|Parts0], Parts,
                            Bytes, RestItems, Truncated),
            Items is RawCount+RestItems
        )
    ).

map_work(Transform, text, Text, Limits, Work) :-
    !,
    ensure_transform(Transform),
    split_string(Text, "\n", "", Items),
    map_sequence(Items, Transform, Limits, 0, 0, [], Rev,
                 Bytes, Count, Truncated),
    reverse(Rev, Values),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:Truncated}.
map_work(Transform, terms, Terms, Limits, Work) :-
    !,
    ensure_transform(Transform),
    map_sequence(Terms, Transform, Limits, 0, 0, [], Rev,
                 Bytes, Count, Truncated),
    reverse(Rev, Values),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:Truncated}.
map_work(_, Kind, _, _, _) :-
    throw(context_fault(unsupported_selector(Kind, map))).

map_sequence([], _, _, Bytes, _, Values, Values, Bytes, 0, false) :-
    !.
map_sequence(Items, _, Limits, Bytes, OutBytes, Values, Values,
             Bytes, 0, true) :-
    length(Values, Count),
    get_dict(max_results, Limits, MaxResults),
    get_dict(max_bytes, Limits, MaxBytes),
    (Count >= MaxResults ; OutBytes >= MaxBytes),
    Items \== [],
    !.
map_sequence([Item|Rest], Transform, Limits, Bytes0, OutBytes0, Values0,
             Values, Bytes, Count, Truncated) :-
    item_utf8_size(Item, ItemBytes),
    Bytes1 is Bytes0+ItemBytes,
    transform_item(Transform, Item, Value),
    value_payload_size(Value, ValueBytes),
    get_dict(max_bytes, Limits, MaxBytes),
    Remaining is MaxBytes-OutBytes0,
    (   ValueBytes > Remaining
    ->  Values = Values0,
        Bytes = Bytes1,
        Count = 1,
        Truncated = true
    ;   OutBytes1 is OutBytes0+ValueBytes,
        map_sequence(Rest, Transform, Limits, Bytes1, OutBytes1,
                     [Value|Values0], Values, Bytes, RestCount, Truncated),
        Count is RestCount+1
    ).

ensure_transform(identity) :- !.
ensure_transform(lowercase) :- !.
ensure_transform(uppercase) :- !.
ensure_transform(length) :- !.
ensure_transform(Transform) :-
    throw(context_fault(capability_denied(map, Transform))).

transform_item(identity, Item, Item).
transform_item(lowercase, Item, Lower) :-
    item_text(Item, Text),
    string_lower(Text, Lower).
transform_item(uppercase, Item, Upper) :-
    item_text(Item, Text),
    string_upper(Text, Upper).
transform_item(length, Item, Length) :-
    item_text(Item, Text),
    string_length(Text, Length).

reduce_work(count, text, Text, Work) :-
    !,
    text_item_count(Text, Count),
    utf8_size(Text, Bytes),
    Work = work{value:Count,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:false}.
reduce_work(count, terms, Terms, Work) :-
    !,
    length(Terms, Count),
    terms_utf8_size(Terms, Bytes),
    Work = work{value:Count,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:false}.
reduce_work(byte_count, text, Text, Work) :-
    !,
    utf8_size(Text, Bytes),
    text_item_count(Text, Items),
    Work = work{value:Bytes,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:false}.
reduce_work(byte_count, terms, Terms, Work) :-
    !,
    terms_utf8_size(Terms, Bytes),
    length(Terms, Items),
    Work = work{value:Bytes,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:false}.
reduce_work(Reducer, Kind, _, _) :-
    throw(context_fault(capability_denied(reduce(Kind), Reducer))).

finalize_work(exception(Exception), _, _, _, Operation, _, Outcome) :-
    !,
    structured_context_exception(Operation, Exception, Outcome).
finalize_work(work(Work), Id, Version, Handle, Operation, ElapsedMs,
              ok(Result)) :-
    Work = work{value:Value,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated},
    value_utf8_size(Value, ReturnedBytes),
    get_time(Timestamp),
    BaseTrace = context_trace{operation:Operation,
                              handle:Handle,
                              bytes_inspected:Bytes,
                              items_inspected:Items,
                              bytes_returned:ReturnedBytes,
                              truncated:Truncated,
                              elapsed_ms:ElapsedMs,
                              timestamp:Timestamp},
    record_trace(Id, Version, BaseTrace, Trace),
    Result = context_result{handle:Handle,
                            operation:Operation,
                            value:Value,
                            truncated:Truncated,
                            trace:Trace}.

record_trace(Id, Version, BaseTrace, Trace) :-
    with_mutex(rlm_context_trace,
               ( next_trace_sequence(Id, Version, Seq),
                 put_dict(sequence, BaseTrace, Seq, Trace),
                 assertz(context_event(Id, Version, Seq-Trace))
               )).

next_trace_sequence(Id, Version, Seq) :-
    findall(S, context_event(Id, Version, S-_), Existing),
    (   Existing == []
    ->  Seq = 1
    ;   max_list(Existing, Max),
        Seq is Max+1
    ).

context_delete(Handle, Outcome) :-
    resolve_handle(Handle, Resolved),
    (   Resolved = ok(record(Id, Version, _, _, _, _))
    ->  with_mutex(rlm_context_store,
                   ( retractall(context_record(Id, Version, _, _, _, _)),
                     retractall(context_tombstone(Id, _)),
                     assertz(context_tombstone(Id, Version))
                   )),
        Outcome = ok(deleted{handle:Handle})
    ;   Resolved = error(Error),
        Outcome = error(Error)
    ).

context_trace(Handle, Limit, Outcome) :-
    (   integer(Limit), Limit > 0
    ->  handle_identity(Handle, Identity),
        trace_for_identity(Identity, Limit, Outcome)
    ;   Outcome = error(context_error{operation:trace,
                                      kind:invalid_limit,
                                      message:"trace limit must be a positive integer"})
    ).

trace_for_identity(error(Error), _, error(Error)) :-
    !.
trace_for_identity(ok(Id, Version), Limit, ok(Events)) :-
    findall(Seq-Event, context_event(Id, Version, Seq-Event), Pairs),
    keysort(Pairs, Sorted),
    pairs_values_local(Sorted, AllEvents),
    take_last_n(AllEvents, Limit, Events).

resolve_handle(Handle, Outcome) :-
    handle_identity(Handle, Identity),
    resolve_identity(Identity, Outcome).

handle_identity(context_handle(Id, Version), Outcome) :-
    !,
    (   atom(Id), integer(Version), Version > 0
    ->  Outcome = ok(Id, Version)
    ;   Outcome = error(context_error{operation:resolve,
                                      kind:invalid_handle,
                                      handle:context_handle(Id, Version),
                                      message:"context handle has invalid id/version"})
    ).
handle_identity(Handle,
                error(context_error{operation:resolve,
                                    kind:invalid_handle,
                                    handle:Handle,
                                    message:"expected context_handle(Id, Version)"})).

resolve_identity(error(Error), error(Error)) :-
    !.
resolve_identity(ok(Id, Version), Outcome) :-
    (   context_record(Id, Version, Kind, Payload, Metadata, CreatedAt)
    ->  Outcome = ok(record(Id, Version, Kind, Payload, Metadata, CreatedAt))
    ;   context_record(Id, CurrentVersion, _, _, _, _),
        CurrentVersion =\= Version
    ->  Outcome = error(context_error{operation:resolve,
                                      kind:stale_handle,
                                      handle:context_handle(Id, Version),
                                      current_version:CurrentVersion,
                                      message:"context handle version is stale"})
    ;   context_tombstone(Id, DeletedVersion)
    ->  Outcome = error(context_error{operation:resolve,
                                      kind:stale_handle,
                                      handle:context_handle(Id, Version),
                                      deleted_version:DeletedVersion,
                                      message:"context handle refers to deleted context"})
    ;   Outcome = error(context_error{operation:resolve,
                                      kind:unknown_handle,
                                      handle:context_handle(Id, Version),
                                      message:"context handle is not registered"})
    ).

validate_limits(Options, Outcome) :-
    (   is_list(Options)
    ->  option_value(max_results, Options, 32, MaxResults),
        option_value(max_bytes, Options, 16384, MaxBytes),
        option_value(time_limit, Options, 0.25, TimeLimit),
        validate_limit_values(MaxResults, MaxBytes, TimeLimit, Outcome)
    ;   Outcome = error(context_error{operation:options,
                                      kind:invalid_options,
                                      message:"context options must be a list"})
    ).

validate_limit_values(MaxResults, MaxBytes, TimeLimit, ok(Limits)) :-
    integer(MaxResults), MaxResults > 0,
    integer(MaxBytes), MaxBytes > 0,
    number(TimeLimit), TimeLimit > 0,
    !,
    Limits = limits{max_results:MaxResults,
                    max_bytes:MaxBytes,
                    time_limit:TimeLimit}.
validate_limit_values(_, _, _,
                      error(context_error{operation:options,
                                          kind:invalid_limit,
                                          message:"max_results/max_bytes must be positive integers and time_limit a positive number"})).

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

structured_context_exception(Operation, time_limit_exceeded,
                             error(context_error{operation:Operation,
                                                 kind:time_limit_exceeded,
                                                 message:"context operation exceeded its wall-time budget"})) :-
    !.
structured_context_exception(Operation, time_limit_exceeded(_),
                             error(context_error{operation:Operation,
                                                 kind:time_limit_exceeded,
                                                 message:"context operation exceeded its wall-time budget"})) :-
    !.
structured_context_exception(Operation, context_fault(Fault), error(Error)) :-
    !,
    fault_error(Operation, Fault, Error).
structured_context_exception(Operation, Exception,
                             error(context_error{operation:Operation,
                                                 kind:runtime_error,
                                                 exception:Safe,
                                                 message:"context operation failed"})) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).

fault_error(Operation, out_of_range(Index),
            context_error{operation:Operation,
                          kind:out_of_range,
                          index:Index,
                          message:"context selector is outside the payload"}).
fault_error(Operation, unsupported_selector(Kind, Selector),
            context_error{operation:Operation,
                          kind:unsupported_selector,
                          context_kind:Kind,
                          selector:Selector,
                          message:"selector is not supported for this context kind"}).
fault_error(Operation, unsupported_partition(Kind, Strategy),
            context_error{operation:Operation,
                          kind:unsupported_partition,
                          context_kind:Kind,
                          strategy:Strategy,
                          message:"partition strategy is not supported for this context kind"}).
fault_error(Operation, capability_denied(Capability, Requested),
            context_error{operation:Operation,
                          kind:capability_denied,
                          capability:Capability,
                          requested:Requested,
                          message:"operation is not in the context capability allow-list"}).
fault_error(Operation, invalid_integer(Value),
            context_error{operation:Operation,
                          kind:invalid_argument,
                          value:Value,
                          message:"expected a non-negative integer"}).
fault_error(Operation, invalid_positive_integer(Value),
            context_error{operation:Operation,
                          kind:invalid_argument,
                          value:Value,
                          message:"expected a positive integer"}).
fault_error(Operation, unsupported_operation(Requested),
            context_error{operation:Operation,
                          kind:unsupported_operation,
                          requested:Requested,
                          message:"context operation is unsupported"}).
fault_error(Operation, internal_failure(Requested),
            context_error{operation:Operation,
                          kind:internal_failure,
                          requested:Requested,
                          message:"context worker failed without a structured result"}).

require_nonnegative_integer(Value) :-
    (   integer(Value), Value >= 0
    ->  true
    ;   throw(context_fault(invalid_integer(Value)))
    ).

require_positive_integer(Value) :-
    (   integer(Value), Value > 0
    ->  true
    ;   throw(context_fault(invalid_positive_integer(Value)))
    ).

text_to_string_safe(Text, String) :-
    (   string(Text)
    ->  String = Text
    ;   atom(Text)
    ->  atom_string(Text, String)
    ).

item_text(Item, Text) :-
    (   string(Item)
    ->  Text = Item
    ;   atom(Item)
    ->  atom_string(Item, Text)
    ;   term_string(Item, Text, [quoted(true), numbervars(true)])
    ).

item_utf8_size(Item, Bytes) :-
    item_text(Item, Text),
    utf8_size(Text, Bytes).

value_payload_size(Value, Bytes) :-
    (   string(Value)
    ->  utf8_size(Value, Bytes)
    ;   term_utf8_size(Value, Bytes)
    ).

utf8_size(Text, Bytes) :-
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

term_utf8_size(Term, Bytes) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    utf8_size(Text, Bytes).

terms_utf8_size(Terms, Bytes) :-
    maplist(term_utf8_size, Terms, Sizes),
    sum_list(Sizes, Bytes).

value_utf8_size(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    utf8_size(Text, Bytes).

text_item_count("", 0) :-
    !.
text_item_count(Text, Count) :-
    split_string(Text, "\n", "", Lines),
    length(Lines, Count).

truncate_text_bytes(_, MaxBytes, "", true) :-
    MaxBytes =< 0,
    !.
truncate_text_bytes(Text, MaxBytes, Bounded, Truncated) :-
    string_bytes(Text, Bytes, utf8),
    length(Bytes, Length),
    (   Length =< MaxBytes
    ->  Bounded = Text,
        Truncated = false
    ;   take_n(Bytes, MaxBytes, Prefix0),
        valid_utf8_prefix(Prefix0, Prefix),
        string_bytes(Bounded, Prefix, utf8),
        Truncated = true
    ).

valid_utf8_prefix(Bytes, Prefix) :-
    (   catch(string_bytes(_, Bytes, utf8), _, fail)
    ->  Prefix = Bytes
    ;   append(Shorter, [_], Bytes),
        valid_utf8_prefix(Shorter, Prefix)
    ).

bounded_term(Term, MaxBytes, Value, Truncated) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    truncate_text_bytes(Text, MaxBytes, Preview, Truncated),
    (   Truncated == true
    ->  Value = truncated_term{preview:Preview}
    ;   Value = Term
    ).

bounded_term_list(Terms, MaxBytes, Values, Truncated) :-
    bounded_term_list_(Terms, MaxBytes, 0, [], Rev, Truncated),
    reverse(Rev, Values).

bounded_term_list_([], _, _, Values, Values, false) :-
    !.
bounded_term_list_([Term|Terms], MaxBytes, Used0, Values0, Values,
                   Truncated) :-
    term_utf8_size(Term, TermBytes),
    Used1 is Used0+TermBytes,
    (   Used1 =< MaxBytes
    ->  bounded_term_list_(Terms, MaxBytes, Used1, [Term|Values0], Values,
                           Truncated)
    ;   Values = Values0,
        Truncated = true
    ).

bool_or(Conditions, true) :-
    member(Condition, Conditions),
    call(Condition),
    !.
bool_or(_, false).

take_n(_, 0, []) :-
    !.
take_n([], _, []) :-
    !.
take_n([Item|Items], N, [Item|Taken]) :-
    N > 0,
    N1 is N-1,
    take_n(Items, N1, Taken).

drop_n(Items, 0, Items) :-
    !.
drop_n([], _, []) :-
    !.
drop_n([_|Items], N, Rest) :-
    N > 0,
    N1 is N-1,
    drop_n(Items, N1, Rest).

take_last_n(Items, Limit, Tail) :-
    length(Items, Length),
    Drop is max(0, Length-Limit),
    drop_n(Items, Drop, Tail).

pairs_values_local([], []).
pairs_values_local([_-Value|Pairs], [Value|Values]) :-
    pairs_values_local(Pairs, Values).
