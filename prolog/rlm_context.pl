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

The initial backend keeps text and term contexts in process memory while
exposing only opaque versioned handles. Public operations are bounded and do
not dereference paths, URLs, streams, sockets, or arbitrary Prolog goals.
*/

:- use_module(library(uuid)).
:- use_module(library(time)).
:- use_module(library(lists)).

:- dynamic context_record/6.
:- dynamic context_tombstone/2.
:- dynamic context_event/3.

:- meta_predicate run_bounded(+, +, +, 4, -).

context_backend(memory, capabilities{
                            source_kinds:[text, terms],
                            persistent:false,
                            filesystem:false,
                            network:false
                        }).

%!  context_register(+Source, +Options, -Outcome) is det.
%
%   Register text(Text) or terms(List) and return a context_ref containing only
%   a handle and metadata. The payload never appears in the returned reference.

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
register_source(ok(SourceStats), Kind, Payload, ok(Ref)) :-
    uuid(Id, [version(4)]),
    Version = 1,
    get_time(CreatedAt),
    SourceStats = source_stats{bytes:Bytes, items:Items},
    Metadata = context_metadata{
                   backend:memory,
                   kind:Kind,
                   bytes:Bytes,
                   items:Items,
                   version:Version,
                   created_at:CreatedAt
               },
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
    ;   Outcome = error(context_error{
                            operation:register,
                            kind:invalid_source,
                            expected:text,
                            message:"text source must contain atom/string text"
                        })
    ).
normalize_source(terms(Terms), terms, Terms, Outcome) :-
    !,
    (   is_list(Terms)
    ->  terms_utf8_size(Terms, Bytes),
        length(Terms, Items),
        Outcome = ok(source_stats{bytes:Bytes, items:Items})
    ;   Outcome = error(context_error{
                            operation:register,
                            kind:invalid_source,
                            expected:list,
                            message:"terms source must contain a proper list"
                        })
    ).
normalize_source(Source, unknown, none,
                 error(context_error{
                           operation:register,
                           kind:unsupported_source,
                           source_shape:Shape,
                           message:"only text(Text) and terms(List) are accepted"
                       })) :-
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

%!  context_metadata(+Handle, -Outcome) is det.

context_metadata(Handle, Outcome) :-
    resolve_handle(Handle, Resolved),
    (   Resolved = ok(record(_, _, _, _, Metadata, _))
    ->  Outcome = ok(context_ref{handle:Handle, metadata:Metadata})
    ;   Resolved = error(Error),
        Outcome = error(Error)
    ).

%!  context_peek(+Handle, +Selector, +Options, -Outcome) is det.

context_peek(Handle, Selector, Options, Outcome) :-
    run_bounded(Handle, peek(Selector), Options,
                peek_work(Selector), Outcome).

peek_work(metadata, _, _, _,
          work{value:metadata_only,
               bytes_inspected:0,
               items_inspected:0,
               truncated:false}) :-
    !.
peek_work(head(Count), text, Text, Limits, Work) :-
    !,
    valid_nonnegative_integer(Count),
    max_text_chars(Text, Count, Limits.max_bytes, Slice, Truncated),
    utf8_size(Slice, Bytes),
    Work = work{value:Slice,
                bytes_inspected:Bytes,
                items_inspected:1,
                truncated:Truncated}.
peek_work(tail(Count), text, Text, Limits, Work) :-
    !,
    valid_nonnegative_integer(Count),
    string_length(Text, Length),
    RequestedStart is max(0, Length-Count),
    sub_string(Text, RequestedStart, _, 0, Tail),
    truncate_text_bytes(Tail, Limits.max_bytes, Slice, ByteTruncated),
    utf8_size(Slice, Bytes),
    (RequestedStart > 0 ; ByteTruncated == true -> Truncated = true ; Truncated = false),
    Work = work{value:Slice,
                bytes_inspected:Bytes,
                items_inspected:1,
                truncated:Truncated}.
peek_work(item(Index), terms, Terms, Limits, Work) :-
    !,
    valid_nonnegative_integer(Index),
    (   nth0(Index, Terms, Term)
    ->  bounded_term(Term, Limits.max_bytes, Value, Truncated),
        term_utf8_size(Term, Bytes),
        Work = work{value:Value,
                    bytes_inspected:Bytes,
                    items_inspected:1,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Index)))
    ).
peek_work(head(Count), terms, Terms, Limits, Work) :-
    !,
    valid_nonnegative_integer(Count),
    Requested is min(Count, Limits.max_results),
    take_n(Terms, Requested, Taken),
    bounded_term_list(Taken, Limits.max_bytes, Values, TruncatedBytes),
    length(Values, Returned),
    length(Terms, Total),
    (Returned < min(Count, Total) ; Count > Limits.max_results ; TruncatedBytes == true
    -> Truncated = true ; Truncated = false),
    terms_utf8_size(Taken, Bytes),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Returned,
                truncated:Truncated}.
peek_work(tail(Count), terms, Terms, Limits, Work) :-
    !,
    valid_nonnegative_integer(Count),
    length(Terms, Total),
    Requested is min(Count, Limits.max_results),
    Start is max(0, Total-Requested),
    drop_n(Terms, Start, Tail),
    bounded_term_list(Tail, Limits.max_bytes, Values, TruncatedBytes),
    length(Values, Returned),
    (Returned < min(Count, Total) ; Count > Limits.max_results ; TruncatedBytes == true
    -> Truncated = true ; Truncated = false),
    terms_utf8_size(Tail, Bytes),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Returned,
                truncated:Truncated}.
peek_work(Selector, Kind, _, _, _) :-
    throw(context_fault(unsupported_selector(Kind, Selector))).

%!  context_slice(+Handle, +Start, +Length, +Options, -Outcome) is det.
%
%   Start is zero-based. Text slices address characters; term slices address
%   list items.

context_slice(Handle, Start, Length, Options, Outcome) :-
    run_bounded(Handle, slice(Start, Length), Options,
                slice_work(Start, Length), Outcome).

slice_work(Start, Length, text, Text, Limits, Work) :-
    !,
    valid_nonnegative_integer(Start),
    valid_nonnegative_integer(Length),
    string_length(Text, Total),
    (   Start =< Total
    ->  Available is Total-Start,
        Requested is min(Length, Available),
        sub_string(Text, Start, Requested, _, Raw),
        truncate_text_bytes(Raw, Limits.max_bytes, Value, ByteTruncated),
        utf8_size(Raw, InspectedBytes),
        (Requested < Length ; ByteTruncated == true -> Truncated = true ; Truncated = false),
        Work = work{value:Value,
                    bytes_inspected:InspectedBytes,
                    items_inspected:1,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Start)))
    ).
slice_work(Start, Length, terms, Terms, Limits, Work) :-
    valid_nonnegative_integer(Start),
    valid_nonnegative_integer(Length),
    length(Terms, Total),
    (   Start =< Total
    ->  drop_n(Terms, Start, Rest),
        Requested is min(Length, Limits.max_results),
        take_n(Rest, Requested, Raw),
        bounded_term_list(Raw, Limits.max_bytes, Value, ByteTruncated),
        length(Value, Returned),
        (Start+Length > Total ; Length > Limits.max_results ;
         Returned < Requested ; ByteTruncated == true
        -> Truncated = true ; Truncated = false),
        terms_utf8_size(Raw, InspectedBytes),
        length(Raw, InspectedItems),
        Work = work{value:Value,
                    bytes_inspected:InspectedBytes,
                    items_inspected:InspectedItems,
                    truncated:Truncated}
    ;   throw(context_fault(out_of_range(Start)))
    ).

%!  context_search(+Handle, +Pattern, +Options, -Outcome) is det.

context_search(Handle, Pattern0, Options, Outcome) :-
    (   text_to_string_safe(Pattern0, Pattern), Pattern \== ""
    ->  run_bounded(Handle, search(Pattern), Options,
                    search_work(Pattern), Outcome)
    ;   Outcome = error(context_error{
                            operation:search,
                            kind:invalid_pattern,
                            message:"search pattern must be non-empty text"
                        })
    ).

search_work(Pattern, text, Text, Limits, Work) :-
    !,
    split_string(Text, "\n", "", Lines),
    search_items(Lines, Pattern, Limits, 0, 0, [], RevMatches,
                 Bytes, Items, Truncated),
    reverse(RevMatches, Matches),
    Work = work{value:Matches,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
search_work(Pattern, terms, Terms, Limits, Work) :-
    search_terms(Terms, Pattern, Limits, 0, 0, [], RevMatches,
                 Bytes, Items, Truncated),
    reverse(RevMatches, Matches),
    Work = work{value:Matches,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.

search_items([], _, _, _, Bytes, Matches, Matches, Bytes, 0, false).
search_items([Line|Lines], Pattern, Limits, Index, Bytes0, Matches0,
             Matches, Bytes, Items, Truncated) :-
    utf8_size(Line, LineBytes),
    Bytes1 is Bytes0+LineBytes,
    length(Matches0, MatchCount),
    (   sub_string(Line, _, _, _, Pattern)
    ->  bounded_text_match(Index, Line, Limits.max_bytes, Match),
        Matches1 = [Match|Matches0]
    ;   Matches1 = Matches0
    ),
    length(Matches1, NewCount),
    Index1 is Index+1,
    (   NewCount >= Limits.max_results
    ->  Matches = Matches1,
        Bytes = Bytes1,
        Items = Index1,
        Truncated = (Lines \== [])
    ;   search_items(Lines, Pattern, Limits, Index1, Bytes1, Matches1,
                     Matches, Bytes, RestItems, Truncated),
        Items = RestItems
    ),
    MatchCount >= 0.

search_terms([], _, _, _, Bytes, Matches, Matches, Bytes, 0, false).
search_terms([Term|Terms], Pattern, Limits, Index, Bytes0, Matches0,
             Matches, Bytes, Items, Truncated) :-
    term_string(Term, Text, [quoted(true), numbervars(true)]),
    utf8_size(Text, TermBytes),
    Bytes1 is Bytes0+TermBytes,
    (   sub_string(Text, _, _, _, Pattern)
    ->  truncate_text_bytes(Text, Limits.max_bytes, Preview, _),
        Matches1 = [match{index:Index, value:Preview}|Matches0]
    ;   Matches1 = Matches0
    ),
    length(Matches1, MatchCount),
    Index1 is Index+1,
    (   MatchCount >= Limits.max_results
    ->  Matches = Matches1,
        Bytes = Bytes1,
        Items = Index1,
        Truncated = (Terms \== [])
    ;   search_terms(Terms, Pattern, Limits, Index1, Bytes1, Matches1,
                     Matches, Bytes, RestItems, Truncated),
        Items = RestItems
    ).

bounded_text_match(Index, Text, MaxBytes,
                   match{index:Index, value:Preview}) :-
    truncate_text_bytes(Text, MaxBytes, Preview, _).

%!  context_partition(+Handle, +Strategy, +Options, -Outcome) is det.

context_partition(Handle, Strategy, Options, Outcome) :-
    run_bounded(Handle, partition(Strategy), Options,
                partition_work(Strategy), Outcome).

partition_work(fixed(Size), text, Text, Limits, Work) :-
    !,
    valid_positive_integer(Size),
    string_length(Text, Length),
    text_partitions(Text, Length, Size, Limits, 0, [], RevParts,
                    Bytes, Count, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:Truncated}.
partition_work(lines(Size), text, Text, Limits, Work) :-
    !,
    valid_positive_integer(Size),
    split_string(Text, "\n", "", Lines),
    list_partitions(Lines, Size, Limits, 0, [], RevParts,
                    Bytes, Count, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:Truncated}.
partition_work(fixed(Size), terms, Terms, Limits, Work) :-
    !,
    valid_positive_integer(Size),
    list_partitions(Terms, Size, Limits, 0, [], RevParts,
                    Bytes, Count, Truncated),
    reverse(RevParts, Parts),
    Work = work{value:Parts,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:Truncated}.
partition_work(Strategy, Kind, _, _, _) :-
    throw(context_fault(unsupported_partition(Kind, Strategy))).

text_partitions(_, Length, _, _, Start, Parts, Parts, 0, 0, false) :-
    Start >= Length,
    !.
text_partitions(Text, Length, Size, Limits, Start, Parts0, Parts,
                Bytes, Count, Truncated) :-
    length(Parts0, Existing),
    (   Existing >= Limits.max_results
    ->  Parts = Parts0,
        Bytes = 0,
        Count = 0,
        Truncated = true
    ;   ChunkLength is min(Size, Length-Start),
        sub_string(Text, Start, ChunkLength, _, Raw),
        truncate_text_bytes(Raw, Limits.max_bytes, Chunk, ByteTruncated),
        utf8_size(Raw, ChunkBytes),
        Part = partition{index:Existing,
                         start:Start,
                         length:ChunkLength,
                         value:Chunk},
        Next is Start+ChunkLength,
        (   ByteTruncated == true
        ->  Parts = [Part|Parts0],
            Bytes = ChunkBytes,
            Count = 1,
            Truncated = true
        ;   text_partitions(Text, Length, Size, Limits, Next,
                            [Part|Parts0], Parts,
                            RestBytes, RestCount, RestTruncated),
            Bytes is ChunkBytes+RestBytes,
            Count is RestCount+1,
            Truncated = RestTruncated
        )
    ).

list_partitions([], _, _, _, Parts, Parts, 0, 0, false) :- !.
list_partitions(Items, Size, Limits, Offset, Parts0, Parts,
                Bytes, Count, Truncated) :-
    length(Parts0, Existing),
    (   Existing >= Limits.max_results
    ->  Parts = Parts0,
        Bytes = 0,
        Count = 0,
        Truncated = true
    ;   take_n(Items, Size, Chunk),
        length(Chunk, ChunkCount),
        bounded_term_list(Chunk, Limits.max_bytes, BoundedChunk,
                          ByteTruncated),
        terms_utf8_size(Chunk, ChunkBytes),
        Part = partition{index:Existing,
                         start:Offset,
                         length:ChunkCount,
                         value:BoundedChunk},
        drop_n(Items, ChunkCount, Rest),
        NextOffset is Offset+ChunkCount,
        (   ByteTruncated == true
        ->  Parts = [Part|Parts0],
            Bytes = ChunkBytes,
            Count = ChunkCount,
            Truncated = true
        ;   list_partitions(Rest, Size, Limits, NextOffset,
                            [Part|Parts0], Parts,
                            RestBytes, RestCount, RestTruncated),
            Bytes is ChunkBytes+RestBytes,
            Count is ChunkCount+RestCount,
            Truncated = RestTruncated
        )
    ).

%!  context_map(+Handle, +Transform, +Options, -Outcome) is det.
%
%   Transform is allow-listed; no arbitrary callable is accepted.

context_map(Handle, Transform, Options, Outcome) :-
    run_bounded(Handle, map(Transform), Options,
                map_work(Transform), Outcome).

map_work(Transform, text, Text, Limits, Work) :-
    split_string(Text, "\n", "", Lines),
    map_items(Lines, Transform, Limits, Values, Bytes, Items, Truncated),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.
map_work(Transform, terms, Terms, Limits, Work) :-
    map_items(Terms, Transform, Limits, Values, Bytes, Items, Truncated),
    Work = work{value:Values,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated}.

map_items(Items, Transform, Limits, Values, Bytes, Count, Truncated) :-
    ensure_transform(Transform),
    take_n(Items, Limits.max_results, Taken),
    maplist(transform_item(Transform), Taken, RawValues),
    bounded_term_list(RawValues, Limits.max_bytes, Values, ByteTruncated),
    terms_utf8_size(Taken, Bytes),
    length(Taken, Count),
    length(Items, Total),
    (Count < Total ; ByteTruncated == true -> Truncated = true ; Truncated = false).

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

%!  context_reduce(+Handle, +Reducer, +Options, -Outcome) is det.
%
%   Reducers are allow-listed and cannot invoke caller-supplied predicates.

context_reduce(Handle, Reducer, Options, Outcome) :-
    run_bounded(Handle, reduce(Reducer), Options,
                reduce_work(Reducer), Outcome).

reduce_work(count, text, Text, _, Work) :-
    !,
    text_item_count(Text, Count),
    utf8_size(Text, Bytes),
    Work = work{value:Count,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:false}.
reduce_work(count, terms, Terms, _, Work) :-
    !,
    length(Terms, Count),
    terms_utf8_size(Terms, Bytes),
    Work = work{value:Count,
                bytes_inspected:Bytes,
                items_inspected:Count,
                truncated:false}.
reduce_work(byte_count, text, Text, _, Work) :-
    !,
    utf8_size(Text, Bytes),
    text_item_count(Text, Items),
    Work = work{value:Bytes,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:false}.
reduce_work(byte_count, terms, Terms, _, Work) :-
    !,
    terms_utf8_size(Terms, Bytes),
    length(Terms, Items),
    Work = work{value:Bytes,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:false}.
reduce_work(Reducer, Kind, _, _, _) :-
    throw(context_fault(capability_denied(reduce(Kind), Reducer))).

%!  context_delete(+Handle, -Outcome) is det.

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

%!  context_trace(+Handle, +Limit, -Outcome) is det.

context_trace(Handle, Limit, Outcome) :-
    (   valid_positive_integer(Limit)
    ->  handle_identity(Handle, HandleOutcome),
        trace_for_handle(HandleOutcome, Handle, Limit, Outcome)
    ;   Outcome = error(context_error{
                            operation:trace,
                            kind:invalid_limit,
                            message:"trace limit must be a positive integer"
                        })
    ).

trace_for_handle(error(Error), _, _, error(Error)) :- !.
trace_for_handle(ok(Id, Version), _, Limit, ok(Events)) :-
    findall(Seq-Event, context_event(Id, Version, Seq-Event), Pairs),
    keysort(Pairs, Sorted),
    pairs_values_local(Sorted, AllEvents),
    take_last_n(AllEvents, Limit, Events).

run_bounded(Handle, Operation, Options, Work, Outcome) :-
    resolve_handle(Handle, Resolved),
    (   Resolved = error(Error)
    ->  Outcome = error(Error)
    ;   validate_limits(Options, LimitsOutcome),
        run_resolved(LimitsOutcome, Resolved, Handle, Operation, Work,
                     Outcome)
    ).

run_resolved(error(Error), _, _, _, _, error(Error)) :- !.
run_resolved(ok(Limits), ok(record(Id, Version, Kind, Payload, _, _)),
             Handle, Operation, Work, Outcome) :-
    get_time(Start),
    catch(call_with_time_limit(Limits.time_limit,
                               once(call(Work, Kind, Payload, Limits, WorkResult))),
          Exception,
          WorkResult = exception(Exception)),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    finalize_work(WorkResult, Id, Version, Handle, Operation, ElapsedMs,
                  Outcome).

finalize_work(exception(Exception), _, _, _, Operation, _, Outcome) :-
    !,
    structured_context_exception(Operation, Exception, Outcome).
finalize_work(Work, Id, Version, Handle, Operation, ElapsedMs,
              ok(Result)) :-
    Work = work{value:Value,
                bytes_inspected:Bytes,
                items_inspected:Items,
                truncated:Truncated},
    value_utf8_size(Value, ReturnedBytes),
    next_trace_sequence(Id, Version, Seq),
    get_time(Timestamp),
    Trace = context_trace{
                sequence:Seq,
                operation:Operation,
                handle:Handle,
                bytes_inspected:Bytes,
                items_inspected:Items,
                bytes_returned:ReturnedBytes,
                truncated:Truncated,
                elapsed_ms:ElapsedMs,
                timestamp:Timestamp
            },
    assertz(context_event(Id, Version, Seq-Trace)),
    Result = context_result{
                 handle:Handle,
                 operation:Operation,
                 value:Value,
                 truncated:Truncated,
                 trace:Trace
             }.

next_trace_sequence(Id, Version, Seq) :-
    findall(S, context_event(Id, Version, S-_), Existing),
    (   Existing == []
    ->  Seq = 1
    ;   max_list(Existing, Max),
        Seq is Max+1
    ).

resolve_handle(Handle, Outcome) :-
    handle_identity(Handle, Identity),
    resolve_identity(Identity, Outcome).

handle_identity(context_handle(Id, Version), Outcome) :-
    !,
    (   atom(Id), integer(Version), Version > 0
    ->  Outcome = ok(Id, Version)
    ;   Outcome = error(context_error{
                            operation:resolve,
                            kind:invalid_handle,
                            handle:context_handle(Id, Version),
                            message:"context handle has invalid id/version"
                        })
    ).
handle_identity(Handle,
                error(context_error{
                          operation:resolve,
                          kind:invalid_handle,
                          handle:Handle,
                          message:"expected context_handle(Id, Version)"
                      })).

resolve_identity(error(Error), error(Error)) :- !.
resolve_identity(ok(Id, Version), Outcome) :-
    (   context_record(Id, Version, Kind, Payload, Metadata, CreatedAt)
    ->  Outcome = ok(record(Id, Version, Kind, Payload, Metadata, CreatedAt))
    ;   context_record(Id, OtherVersion, _, _, _, _),
        OtherVersion =\= Version
    ->  Outcome = error(context_error{
                            operation:resolve,
                            kind:stale_handle,
                            handle:context_handle(Id, Version),
                            current_version:OtherVersion,
                            message:"context handle version is stale"
                        })
    ;   context_tombstone(Id, DeletedVersion)
    ->  Outcome = error(context_error{
                            operation:resolve,
                            kind:stale_handle,
                            handle:context_handle(Id, Version),
                            deleted_version:DeletedVersion,
                            message:"context handle refers to deleted context"
                        })
    ;   Outcome = error(context_error{
                            operation:resolve,
                            kind:unknown_handle,
                            handle:context_handle(Id, Version),
                            message:"context handle is not registered"
                        })
    ).

validate_limits(Options, Outcome) :-
    (   is_list(Options)
    ->  option_value(max_results, Options, 32, MaxResults),
        option_value(max_bytes, Options, 16384, MaxBytes),
        option_value(time_limit, Options, 0.25, TimeLimit),
        validate_limit_values(MaxResults, MaxBytes, TimeLimit, Outcome)
    ;   Outcome = error(context_error{
                            operation:options,
                            kind:invalid_options,
                            message:"context options must be a list"
                        })
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
                      error(context_error{
                                operation:options,
                                kind:invalid_limit,
                                message:"max_results/max_bytes must be positive integers and time_limit a positive number"
                            })).

option_value(Name, Options, Default, Value) :-
    (   member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

structured_context_exception(Operation, time_limit_exceeded,
                             error(context_error{
                                       operation:Operation,
                                       kind:time_limit_exceeded,
                                       message:"context operation exceeded its wall-time budget"
                                   })) :-
    !.
structured_context_exception(Operation, time_limit_exceeded(_),
                             error(context_error{
                                       operation:Operation,
                                       kind:time_limit_exceeded,
                                       message:"context operation exceeded its wall-time budget"
                                   })) :-
    !.
structured_context_exception(Operation, context_fault(Fault),
                             error(Error)) :-
    !,
    fault_error(Operation, Fault, Error).
structured_context_exception(Operation, Exception,
                             error(context_error{
                                       operation:Operation,
                                       kind:runtime_error,
                                       exception:Safe,
                                       message:"context operation failed"
                                   })) :-
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

valid_nonnegative_integer(Value) :-
    (integer(Value), Value >= 0 -> true ; throw(context_fault(invalid_integer(Value)))).

valid_positive_integer(Value) :-
    integer(Value), Value > 0.

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

text_item_count("", 0) :- !.
text_item_count(Text, Count) :-
    split_string(Text, "\n", "", Lines),
    length(Lines, Count).

max_text_chars(Text, Count, MaxBytes, Slice, Truncated) :-
    string_length(Text, Length),
    Requested is min(Count, Length),
    sub_string(Text, 0, Requested, _, Raw),
    truncate_text_bytes(Raw, MaxBytes, Slice, ByteTruncated),
    (Requested < Count ; Requested < Length ; ByteTruncated == true
    -> Truncated = true ; Truncated = false).

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
    (Truncated == true -> Value = truncated_term{preview:Preview} ; Value = Term).

bounded_term_list(Terms, MaxBytes, Values, Truncated) :-
    bounded_term_list_(Terms, MaxBytes, 0, [], Rev, Truncated),
    reverse(Rev, Values).

bounded_term_list_([], _, _, Values, Values, false).
bounded_term_list_([Term|Terms], MaxBytes, Used0, Values0, Values, Truncated) :-
    term_utf8_size(Term, TermBytes),
    Used1 is Used0+TermBytes,
    (   Used1 =< MaxBytes
    ->  bounded_term_list_(Terms, MaxBytes, Used1, [Term|Values0], Values,
                           Truncated)
    ;   Values = Values0,
        Truncated = true
    ).

take_n(_, 0, []) :- !.
take_n([], _, []) :- !.
take_n([Item|Items], N, [Item|Taken]) :-
    N > 0,
    N1 is N-1,
    take_n(Items, N1, Taken).

drop_n(Items, 0, Items) :- !.
drop_n([], _, []) :- !.
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
