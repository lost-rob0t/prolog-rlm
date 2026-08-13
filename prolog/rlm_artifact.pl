:- module(rlm_artifact,
          [ rlm_artifact_ready/0,
            artifact_store_open/2,
            artifact_store_close/2,
            artifact_put/7,
            artifact_get/3,
            artifact_latest/4,
            artifact_list/4,
            artifact_ref_status/3,
            artifact_context_pack/4,
            artifact_context_refs/4,
            artifact_trace/3,
            artifact_namespace/2
          ]).

/** <module> Durable versioned artifact store for fresh reasoning roots

Artifacts are cross-run durable state, distinct from conversational transcript
and graph execution checkpoints. Every write creates an immutable version with
explicit provenance. Consumers may request compact context packs containing
only selected latest artifacts.
*/

:- use_module(library(gensym)).
:- use_module(library(option)).
:- use_module(rlm_artifact_persist).

:- dynamic artifact_memory_store/1.
:- dynamic artifact_memory_record/5.
:- dynamic artifact_memory_trace/4.

rlm_artifact_ready.

artifact_store_open(Spec, Outcome) :-
    artifact_outcome(open, artifact_store_open_(Spec), Outcome).

artifact_store_open_(memory, Store) :-
    !,
    with_mutex(rlm_artifact_memory,
               ( gensym(artifact_store_, Id),
                 assertz(artifact_memory_store(Id)) )),
    Store = artifact_store(memory, Id).
artifact_store_open_(persist(File0), Store) :-
    !,
    require_text(File0, File),
    artifact_persist_open(File),
    Store = artifact_store(persist, File).
artifact_store_open_(Spec, _) :-
    throw(artifact_fault(invalid_store_spec(Spec))).

artifact_store_close(Store, Outcome) :-
    catch(( artifact_store_close_(Store), Outcome = ok(closed) ),
          Exception,
          artifact_exception(close, Exception, Outcome)).

artifact_store_close_(artifact_store(memory, Id)) :-
    !,
    with_mutex(rlm_artifact_memory,
               ( retractall(artifact_memory_record(Id, _, _, _, _)),
                 retractall(artifact_memory_trace(Id, _, _, _)),
                 retractall(artifact_memory_store(Id)) )).
artifact_store_close_(artifact_store(persist, _)) :-
    !,
    artifact_persist_close.
artifact_store_close_(Store) :-
    throw(artifact_fault(invalid_store(Store))).

artifact_namespace(Input, Namespace) :-
    normalize_namespace(Input, Namespace).

artifact_put(Store, Namespace0, Key0, Kind0, Value0, Provenance0, Outcome) :-
    artifact_outcome(put,
                     artifact_put_(Store,
                                   Namespace0,
                                   Key0,
                                   Kind0,
                                   Value0,
                                   Provenance0),
                     Outcome).

artifact_put_(Store, Namespace0, Key0, Kind0, Value0, Provenance0, Artifact) :-
    require_store(Store),
    normalize_namespace(Namespace0, Namespace),
    require_name(Key0, Key),
    require_name(Kind0, Kind),
    canonical_value(Value0, Value),
    normalize_provenance(Provenance0, Provenance),
    BaseArtifact = rlm_artifact{namespace:Namespace,
                                key:Key,
                                kind:Kind,
                                value:Value,
                                provenance:Provenance},
    backend_append(Store, Namespace, Key, BaseArtifact, Artifact).

artifact_get(Store, Ref0, Outcome) :-
    artifact_outcome(get,
                     artifact_get_(Store, Ref0),
                     Outcome).

artifact_get_(Store, Ref0, Artifact) :-
    require_store(Store),
    normalize_ref(Ref0, Ref),
    (   backend_get(Store,
                    Ref.namespace,
                    Ref.key,
                    Ref.version,
                    Artifact)
    ->  true
    ;   throw(artifact_fault(not_found(Ref)))
    ).

artifact_latest(Store, Namespace0, Key0, Outcome) :-
    artifact_outcome(latest,
                     artifact_latest_(Store, Namespace0, Key0),
                     Outcome).

artifact_latest_(Store, Namespace0, Key0, Artifact) :-
    require_store(Store),
    normalize_namespace(Namespace0, Namespace),
    require_name(Key0, Key),
    (   backend_latest(Store, Namespace, Key, _, Artifact)
    ->  true
    ;   throw(artifact_fault(not_found(artifact_key(Namespace, Key))))
    ).

artifact_list(Store, Namespace0, Options, Outcome) :-
    artifact_outcome(list,
                     artifact_list_(Store, Namespace0, Options),
                     Outcome).

artifact_list_(Store, Namespace0, Options, Artifacts) :-
    require_store(Store),
    require_options(Options),
    normalize_namespace(Namespace0, Namespace),
    backend_list(Store, Namespace, All0),
    sort_artifacts(All0, All),
    option(history(History), Options, false),
    require_boolean(History, history),
    select_history(History, All, Versioned),
    filter_artifacts(Versioned, Options, Artifacts).

artifact_ref_status(Store, Ref0, Outcome) :-
    artifact_outcome(ref_status,
                     artifact_ref_status_(Store, Ref0),
                     Outcome).

artifact_ref_status_(Store, Ref0, Status) :-
    require_store(Store),
    normalize_ref(Ref0, Ref),
    (   backend_latest(Store,
                       Ref.namespace,
                       Ref.key,
                       LatestVersion,
                       Latest)
    ->  (   backend_get(Store,
                        Ref.namespace,
                        Ref.key,
                        Ref.version,
                        _)
        ->  (   Ref.version =:= LatestVersion
            ->  Status = current(Ref)
            ;   Status = stale(Ref, Latest.ref)
            )
        ;   Status = missing_version(Ref, Latest.ref)
        )
    ;   Status = missing(Ref)
    ).

artifact_context_pack(Store, Namespace0, Options, Outcome) :-
    artifact_outcome(context_pack,
                     artifact_context_pack_(Store, Namespace0, Options),
                     Outcome).

artifact_context_pack_(Store, Namespace0, Options, Pack) :-
    require_options(Options),
    context_limits(Options, MaxItems, MaxChars),
    artifact_list_(Store,
                   Namespace0,
                   [history(false)|Options],
                   Artifacts),
    take_context_entries(Artifacts,
                         MaxItems,
                         MaxChars,
                         Entries,
                         Chars,
                         Truncated),
    normalize_namespace(Namespace0, Namespace),
    entries_refs(Entries, Refs),
    length(Entries, ItemCount),
    trace_context_consumption(Store, Namespace, Options, Refs, []),
    Pack = artifact_context_pack{namespace:Namespace,
                                 entries:Entries,
                                 refs:Refs,
                                 item_count:ItemCount,
                                 chars:Chars,
                                 truncated:Truncated}.

artifact_context_refs(Store, Refs0, Options, Outcome) :-
    artifact_outcome(context_refs,
                     artifact_context_refs_(Store, Refs0, Options),
                     Outcome).

artifact_context_refs_(Store, Refs0, Options, Pack) :-
    require_store(Store),
    require_options(Options),
    require_ref_list(Refs0),
    context_limits(Options, MaxItems, MaxChars),
    maplist(normalize_ref, Refs0, Refs1),
    resolve_latest_refs(Store, Refs1, [], Resolved0, [], Stale0),
    reverse(Resolved0, Resolved1),
    reverse(Stale0, Stale),
    sort_artifacts(Resolved1, Resolved2),
    latest_per_key(Resolved2, [], Latest0),
    sort_artifacts(Latest0, Latest1),
    filter_artifacts(Latest1, Options, Artifacts),
    take_context_entries(Artifacts,
                         MaxItems,
                         MaxChars,
                         Entries,
                         Chars,
                         Truncated),
    entries_refs(Entries, Refs),
    length(Entries, ItemCount),
    trace_ref_consumption(Store, Options, Entries, Stale),
    Pack = artifact_ref_context_pack{entries:Entries,
                                     refs:Refs,
                                     stale_refs:Stale,
                                     item_count:ItemCount,
                                     chars:Chars,
                                     truncated:Truncated}.

artifact_trace(Store, Namespace0, Outcome) :-
    artifact_outcome(trace,
                     artifact_trace_(Store, Namespace0),
                     Outcome).

artifact_trace_(Store, Namespace0, Events) :-
    require_store(Store),
    normalize_namespace(Namespace0, Namespace),
    backend_trace(Store, Namespace, Events).

resolve_latest_refs(_, [], Artifacts, Artifacts, Stale, Stale).
resolve_latest_refs(Store, [Ref|Refs], Artifacts0, Artifacts, Stale0, Stale) :-
    (   backend_latest(Store,
                       Ref.namespace,
                       Ref.key,
                       LatestVersion,
                       Latest)
    ->  (   Ref.version =:= LatestVersion
        ->  Stale1 = Stale0
        ;   Stale1 = [artifact_stale_ref{requested:Ref,
                                         current:Latest.ref}|Stale0]
        ),
        Artifacts1 = [Latest|Artifacts0]
    ;   throw(artifact_fault(not_found(Ref)))
    ),
    resolve_latest_refs(Store, Refs, Artifacts1, Artifacts, Stale1, Stale).

context_limits(Options, MaxItems, MaxChars) :-
    option(max_items(MaxItems), Options, 16),
    option(max_chars(MaxChars), Options, 12000),
    require_positive_integer(MaxItems, max_items),
    require_positive_integer(MaxChars, max_chars).

entries_refs(Entries, Refs) :-
    findall(Ref,
            ( member(Entry, Entries), Ref = Entry.ref ),
            Refs).

trace_context_consumption(Store, Namespace, Options, Refs, Stale) :-
    consumer_from_options(Options, Consumer),
    BaseEvent = artifact_trace{type:consumed,
                               refs:Refs,
                               consumer:Consumer,
                               stale_refs:Stale},
    backend_trace_append(Store, Namespace, BaseEvent, _).

trace_ref_consumption(Store, Options, Entries, Stale) :-
    findall(Namespace,
            ( member(Entry, Entries), Namespace = Entry.namespace ),
            Namespaces0),
    sort(Namespaces0, Namespaces),
    maplist(trace_namespace_entries(Store, Options, Entries, Stale), Namespaces).

trace_namespace_entries(Store, Options, Entries, Stale, Namespace) :-
    findall(Ref,
            ( member(Entry, Entries),
              Entry.namespace == Namespace,
              Ref = Entry.ref ),
            Refs),
    include(stale_for_namespace(Namespace), Stale, NamespaceStale),
    trace_context_consumption(Store,
                              Namespace,
                              Options,
                              Refs,
                              NamespaceStale).

stale_for_namespace(Namespace, Stale) :-
    Stale.requested.namespace == Namespace.

consumer_from_options(Options, Consumer) :-
    option(consumer(Consumer0), Options, none),
    canonical_value(Consumer0, Consumer).

/* ---------------------------------------------------------------------- */

backend_append(artifact_store(memory, Id), Namespace, Key, BaseArtifact,
               Artifact) :-
    require_memory_store(Id),
    with_mutex(rlm_artifact_memory,
               ( findall(V,
                         artifact_memory_record(Id,
                                                Namespace,
                                                Key,
                                                V,
                                                _),
                         Versions),
                 next_version(Versions, Version),
                 Ref = artifact_ref{namespace:Namespace,
                                    key:Key,
                                    version:Version},
                 put_dict(_{ref:Ref, version:Version},
                          BaseArtifact,
                          Artifact),
                 assertz(artifact_memory_record(Id,
                                                Namespace,
                                                Key,
                                                Version,
                                                Artifact)),
                 BaseEvent = artifact_trace{type:published,
                                            ref:Ref,
                                            producer:Artifact.provenance},
                 memory_trace_append_locked(Id,
                                            Namespace,
                                            BaseEvent,
                                            _)
               )).
backend_append(artifact_store(persist, File), Namespace, Key, BaseArtifact,
               Artifact) :-
    artifact_persist_open(File),
    artifact_persist_append(Namespace, Key, BaseArtifact, Artifact).

backend_get(artifact_store(memory, Id), Namespace, Key, Version, Artifact) :-
    require_memory_store(Id),
    artifact_memory_record(Id, Namespace, Key, Version, Artifact).
backend_get(artifact_store(persist, File), Namespace, Key, Version, Artifact) :-
    artifact_persist_open(File),
    artifact_persist_get(Namespace, Key, Version, Artifact).

backend_latest(artifact_store(memory, Id), Namespace, Key, Version, Artifact) :-
    require_memory_store(Id),
    findall(V-A,
            artifact_memory_record(Id, Namespace, Key, V, A),
            Pairs),
    Pairs \== [],
    keysort(Pairs, Sorted),
    last(Sorted, Version-Artifact).
backend_latest(artifact_store(persist, File), Namespace, Key, Version, Artifact) :-
    artifact_persist_open(File),
    artifact_persist_latest(Namespace, Key, Version, Artifact).

backend_list(artifact_store(memory, Id), Namespace, Artifacts) :-
    require_memory_store(Id),
    findall(Artifact,
            artifact_memory_record(Id, Namespace, _, _, Artifact),
            Artifacts).
backend_list(artifact_store(persist, File), Namespace, Artifacts) :-
    artifact_persist_open(File),
    artifact_persist_list(Namespace, Artifacts).

backend_trace_append(artifact_store(memory, Id), Namespace, BaseEvent, Event) :-
    require_memory_store(Id),
    with_mutex(rlm_artifact_memory,
               memory_trace_append_locked(Id, Namespace, BaseEvent, Event)).
backend_trace_append(artifact_store(persist, File), Namespace, BaseEvent, Event) :-
    artifact_persist_open(File),
    artifact_persist_trace_append(Namespace, BaseEvent, Event).

backend_trace(artifact_store(memory, Id), Namespace, Events) :-
    require_memory_store(Id),
    findall(Sequence-Event,
            artifact_memory_trace(Id, Namespace, Sequence, Event),
            Pairs0),
    keysort(Pairs0, Pairs),
    findall(Event, member(_-Event, Pairs), Events).
backend_trace(artifact_store(persist, File), Namespace, Events) :-
    artifact_persist_open(File),
    artifact_persist_trace(Namespace, Events).

memory_trace_append_locked(Id, Namespace, BaseEvent, Event) :-
    findall(S,
            artifact_memory_trace(Id, Namespace, S, _),
            Sequences),
    next_version(Sequences, Sequence),
    put_dict(sequence, BaseEvent, Sequence, Event),
    assertz(artifact_memory_trace(Id, Namespace, Sequence, Event)).

require_store(artifact_store(memory, Id)) :-
    !,
    require_memory_store(Id).
require_store(artifact_store(persist, File)) :-
    !,
    require_text(File, _).
require_store(Store) :-
    throw(artifact_fault(invalid_store(Store))).

require_memory_store(Id) :-
    (   artifact_memory_store(Id)
    ->  true
    ;   throw(artifact_fault(closed_memory_store(Id)))
    ).

next_version([], 1).
next_version(Versions, Version) :-
    Versions \== [],
    max_list(Versions, Latest),
    Version is Latest+1.

sort_artifacts(Artifacts0, Artifacts) :-
    findall(Key-Version-Artifact,
            ( member(Artifact, Artifacts0),
              Key = Artifact.key,
              Version = Artifact.version ),
            Rows0),
    keysort(Rows0, Rows),
    findall(Artifact, member(_-_-Artifact, Rows), Artifacts).

select_history(true, Artifacts, Artifacts) :- !.
select_history(false, Artifacts, Latest) :-
    latest_per_key(Artifacts, [], Latest0),
    sort_artifacts(Latest0, Latest).

latest_per_key([], Acc, Acc).
latest_per_key([Artifact|Artifacts], Acc0, Acc) :-
    replace_latest(Artifact, Acc0, Acc1),
    latest_per_key(Artifacts, Acc1, Acc).

replace_latest(Artifact, [], [Artifact]).
replace_latest(Artifact, [Existing|Rest], [Artifact|Rest]) :-
    same_artifact_key(Artifact, Existing),
    Artifact.version > Existing.version,
    !.
replace_latest(Artifact, [Existing|Rest], [Existing|Rest]) :-
    same_artifact_key(Artifact, Existing),
    !.
replace_latest(Artifact, [Existing|Rest], [Existing|Updated]) :-
    replace_latest(Artifact, Rest, Updated).

same_artifact_key(A, B) :-
    A.namespace == B.namespace,
    A.key == B.key.

filter_artifacts(Artifacts0, Options, Artifacts) :-
    option(kinds(Kinds0), Options, all),
    option(keys(Keys0), Options, all),
    normalize_filter_names(Kinds0, Kinds),
    normalize_filter_names(Keys0, Keys),
    include(matches_filters(Kinds, Keys), Artifacts0, Artifacts).

matches_filters(Kinds, Keys, Artifact) :-
    filter_matches(Kinds, Artifact.kind),
    filter_matches(Keys, Artifact.key).

filter_matches(all, _).
filter_matches(Names, Value) :- memberchk(Value, Names).

normalize_filter_names(all, all) :- !.
normalize_filter_names(Names0, Names) :-
    is_list(Names0),
    !,
    maplist(require_name, Names0, Names).
normalize_filter_names(Value, _) :-
    throw(artifact_fault(invalid_filter(Value))).

take_context_entries(Artifacts, MaxItems, MaxChars,
                     Entries, Chars, Truncated) :-
    take_context_entries_(Artifacts,
                          MaxItems,
                          MaxChars,
                          0,
                          [],
                          Rev,
                          Chars,
                          Truncated),
    reverse(Rev, Entries).

take_context_entries_([], _, _, Chars, Entries, Entries, Chars, false).
take_context_entries_([_|_], 0, _, Chars, Entries, Entries, Chars, true) :- !.
take_context_entries_([Artifact|Rest], Remaining, MaxChars,
                      Chars0, Entries0, Entries, Chars, Truncated) :-
    compact_entry(Artifact, Entry, EntryChars),
    NextChars is Chars0+EntryChars,
    (   NextChars =< MaxChars
    ->  NextRemaining is Remaining-1,
        take_context_entries_(Rest,
                              NextRemaining,
                              MaxChars,
                              NextChars,
                              [Entry|Entries0],
                              Entries,
                              Chars,
                              Truncated)
    ;   Entries = Entries0,
        Chars = Chars0,
        Truncated = true
    ).

compact_entry(Artifact, Entry, Chars) :-
    Entry = artifact_context_entry{ref:Artifact.ref,
                                   namespace:Artifact.namespace,
                                   key:Artifact.key,
                                   kind:Artifact.kind,
                                   value:Artifact.value,
                                   provenance:Artifact.provenance},
    term_string(Entry, Text, [quoted(true), numbervars(true)]),
    string_length(Text, Chars).

normalize_namespace(Input, Namespace) :-
    (   is_list(Input)
    ->  maplist(require_name, Input, Namespace),
        Namespace \== []
    ;   require_name(Input, Name),
        Namespace = [Name]
    ),
    !.
normalize_namespace(Input, _) :-
    throw(artifact_fault(invalid_namespace(Input))).

normalize_ref(Ref0, Ref) :-
    is_dict(Ref0),
    get_dict(namespace, Ref0, Namespace0),
    get_dict(key, Ref0, Key0),
    get_dict(version, Ref0, Version),
    normalize_namespace(Namespace0, Namespace),
    require_name(Key0, Key),
    require_positive_integer(Version, version),
    Ref = artifact_ref{namespace:Namespace, key:Key, version:Version}.

require_ref_list(Refs) :-
    (   is_list(Refs)
    ->  true
    ;   throw(artifact_fault(invalid_ref_list(Refs)))
    ).

normalize_provenance(Provenance0, Provenance) :-
    is_dict(Provenance0),
    !,
    canonical_value(Provenance0, Canonical),
    dict_pairs(Canonical, _, Pairs),
    dict_pairs(Provenance, artifact_provenance, Pairs).
normalize_provenance(Provenance, _) :-
    throw(artifact_fault(invalid_provenance(Provenance))).

canonical_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_pair, Pairs0, Pairs),
    dict_pairs(Value, artifact_data, Pairs).
canonical_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_value, Values0, Values).
canonical_value(Value, Value) :-
    atomic(Value),
    !.
canonical_value(Value, Value) :-
    ground(Value),
    !.
canonical_value(Value, _) :-
    throw(artifact_fault(non_ground_value(Value))).

canonical_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_value(Value0, Value).
canonical_pair(Key-_, _) :-
    throw(artifact_fault(invalid_dict_key(Key))).

require_name(Value, Value) :- atom(Value), Value \== '', !.
require_name(Value, Name) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Name, Value).
require_name(Value, _) :- throw(artifact_fault(invalid_name(Value))).

require_text(Value, Value) :- string(Value), !.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(artifact_fault(expected_text(Value))).

require_options(Options) :-
    ( is_list(Options) -> true ; throw(artifact_fault(invalid_options(Options))) ).

require_boolean(Value, _) :- memberchk(Value, [true,false]), !.
require_boolean(Value, Name) :-
    throw(artifact_fault(invalid_boolean(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(artifact_fault(invalid_positive_integer(Name, Value))).

artifact_outcome(Operation, Goal, Outcome) :-
    catch(( call(Goal, Value), Result = ok(Value) ),
          Exception,
          artifact_exception(Operation, Exception, Result)),
    Outcome = Result.

artifact_exception(Operation, artifact_fault(Detail), error(Error)) :-
    !,
    Error = artifact_error{phase:Operation,
                           kind:artifact_error,
                           detail:Detail,
                           message:"durable artifact operation failed"}.
artifact_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = artifact_error{phase:Operation,
                           kind:exception,
                           exception:Safe,
                           message:"durable artifact backend raised an exception"}.
