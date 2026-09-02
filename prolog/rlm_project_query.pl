:- module(rlm_project_query,
          [ rlm_project_query_ready/0,
            project_query_pack_register/6,
            project_query_pack_activate/4,
            project_query_pack_deactivate/4,
            project_query_pack_deactivate/3,
            project_query_extract/6,
            project_query_extract_async/6,
            project_query_extract_execute/6,
            project_query_current_extraction/3,
            project_query_matches/3,
            project_query_captures/3,
            project_query_node_provenance/3,
            project_query_registry_clear/1
          ]).

/** <module> Bounded Tree-sitter query observations

This module is the mechanical query layer below semantic project knowledge.
Query packs are inert data until trusted host code activates them.  Extraction
records contain closed Prolog identities and provenance; native query, cursor,
tree, and node handles never enter published or persisted facts.
*/

:- use_module(library(crypto)).
:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(time)).
:- use_module(library(utf8)).
:- use_module(rlm_async).
:- use_module(rlm_project_query_persist).
:- use_module(rlm_project_source).

:- dynamic query_pack_record/4.
:- dynamic query_pack_active/4.
:- dynamic query_cache/3.
:- dynamic query_cache_order/2.
:- dynamic query_parse_counter/3.
:- dynamic query_latest_parse/4.
:- dynamic query_parse_fact/3.
:- dynamic query_current_parse/3.
:- dynamic query_extraction_counter/3.
:- dynamic query_latest_extraction/3.
:- dynamic query_extraction_fact/4.
:- dynamic query_match_fact/4.
:- dynamic query_current_extraction/3.
:- dynamic query_persistence/3.

rlm_project_query_ready :-
    rlm_project_source_ready.

/* Query-pack registry -------------------------------------------------- */

project_query_pack_register(Registry,
                            Language0,
                            Purpose0,
                            Source0,
                            Meta0,
                            Outcome) :-
    catch(project_query_pack_register_(Registry,
                                      Language0,
                                      Purpose0,
                                      Source0,
                                      Meta0,
                                      Outcome),
          Exception,
          project_query_exception(pack_register, Exception, Outcome)).

project_query_pack_register_(Registry,
                             Language0,
                             Purpose0,
                             Source0,
                             Meta0,
                             Outcome) :-
    registry_id(Registry, Id),
    normalize_atom(Language0, language, Language),
    normalize_atom(Purpose0, purpose, Purpose),
    normalize_query_source(Source0, Source),
    normalize_pack_meta(Meta0, Meta),
    crypto_data_hash(Source,
                     SourceHash,
                     [algorithm(sha256), encoding(utf8)]),
    pack_identity(Language, Purpose, SourceHash, Meta, Identity),
    Pack = query_pack{identity:Identity,
                      language:Language,
                      purpose:Purpose,
                      source:Source,
                      sha256:SourceHash,
                      version:Meta.version,
                      provenance:Meta.provenance},
    with_mutex(rlm_project_query,
               register_pack_locked(Id, Language, Purpose, Pack, Outcome)).

register_pack_locked(Id, Language, Purpose, Pack, Outcome) :-
    (   query_pack_record(Id, Language, Purpose, Existing)
    ->  (   Existing == Pack
        ->  Outcome = ok(existing(Pack.identity))
        ;   retractall(query_pack_record(Id, Language, Purpose, _)),
            retractall(query_pack_active(Id, Language, Purpose, _)),
            assertz(query_pack_record(Id, Language, Purpose, Pack)),
            mark_pack_extractions_stale(Id, Language, Purpose),
            Outcome = ok(replaced(Pack.identity))
        )
     ;   assertz(query_pack_record(Id, Language, Purpose, Pack)),
         Outcome = ok(registered(Pack.identity))
     ).

project_query_pack_activate(Registry, Language0, Purpose0, Outcome) :-
    catch(project_query_pack_activate_(Registry,
                                       Language0,
                                       Purpose0,
                                       Outcome),
          Exception,
          project_query_exception(pack_activate, Exception, Outcome)).

project_query_pack_activate_(Registry, Language0, Purpose0, Outcome) :-
    registry_id(Registry, Id),
    normalize_atom(Language0, language, Language),
    normalize_atom(Purpose0, purpose, Purpose),
    with_mutex(rlm_project_query,
               ( query_pack_record(Id, Language, Purpose, Pack)
               -> ( query_pack_active(Id, Language, Purpose, Existing)
                  -> Outcome = ok(already_active(Existing.identity))
                  ;  assertz(query_pack_active(Id,
                                                Language,
                                                Purpose,
                                                Pack)),
                     Outcome = ok(activated(Pack.identity))
                  )
               ;  throw(project_query_fault(pack_not_registered(Language,
                                                                   Purpose)))
                )).

project_query_pack_deactivate(Registry, Language0, Purpose0, Outcome) :-
    catch(project_query_pack_deactivate_(Registry,
                                         Language0,
                                         Purpose0,
                                         Outcome),
          Exception,
          project_query_exception(pack_deactivate, Exception, Outcome)).

project_query_pack_deactivate(Registry, Language, Purpose) :-
    project_query_pack_deactivate(Registry, Language, Purpose, _).

project_query_pack_deactivate_(Registry, Language0, Purpose0, Outcome) :-
    registry_id(Registry, Id),
    normalize_atom(Language0, language, Language),
    normalize_atom(Purpose0, purpose, Purpose),
    with_mutex(rlm_project_query,
               ( retract(query_pack_active(Id, Language, Purpose, Pack))
               -> Outcome = ok(deactivated(Pack.identity))
               ;  Outcome = ok(already_inactive(Language, Purpose))
               )).

/* Extraction public surfaces ------------------------------------------ */

project_query_extract(Registry, File, Source, Purposes, Options0, Outcome) :-
    project_query_extract_async(Registry,
                                File,
                                Source,
                                Purposes,
                                Options0,
                                Future),
    setup_call_cleanup(true,
                       rlm_future_await(Future, Outcome),
                       rlm_future_destroy(Future)).

project_query_extract_async(Registry,
                            File,
                            Source,
                            Purposes,
                            Options,
                            Future) :-
    rlm_async_submit(
        rlm_project_query:project_query_extract_execute(Registry,
                                                         File,
                                                         Source,
                                                         Purposes,
                                                         Options),
        Future).

project_query_extract_execute(Registry,
                              File,
                              Source,
                              Purposes,
                              Options0,
                              Outcome) :-
    catch(project_query_extract_(Registry,
                                 File,
                                 Source,
                                 Purposes,
                                 Options0,
                                 Outcome),
          Exception,
          project_query_exception(extract, Exception, Outcome)).

project_query_extract_(Registry,
                       File,
                       Source0,
                       Purposes0,
                       Options0,
                       Outcome) :-
    normalize_query_source(Source0, Source),
    query_options(Options0, Options),
    normalize_purposes(Purposes0, Purposes),
    registry_id(Registry, Id),
    project_source_file(Registry, File, FileRecord),
    project_source_project(Registry, FileRecord.project, ProjectMeta),
    project_source_file_language(Registry, File, ok(LanguageResolution)),
    require_known_language(LanguageResolution),
    enforce_file_policy(FileRecord, Options),
    source_bytes(Source, SourceByteList),
    length(SourceByteList, SourceBytes),
    enforce_source_limit(SourceBytes, Options.max_source_bytes),
    crypto_data_hash(Source,
                     ContentHash,
                     [algorithm(sha256), encoding(utf8)]),
    validate_registered_hash(FileRecord.hash, ContentHash),
    active_packs(Id, LanguageResolution.language, Purposes, Packs),
    ensure_project_persistence(Registry,
                               FileRecord.project,
                               ProjectMeta,
                               Options),
    reserve_query_parse(Registry,
                        File,
                        ContentHash,
                        Parse,
                        ParseMode),
    reserve_extraction(Registry,
                       File,
                       Parse,
                       Packs,
                       Extraction),
    catch(call_with_time_limit(
              Options.timeout_seconds,
              extract_native(Registry,
                             File,
                             Source,
                             ContentHash,
                             FileRecord,
                             Packs,
                             Parse,
                             ParseMode,
                             Extraction,
                             Options,
                             Outcome)),
          Exception,
          ( reject_query_admission(Registry, File, Parse, Extraction),
            throw(Exception)
          )).

extract_native(Registry,
               File,
               Source,
               ContentHash,
               FileRecord,
               Packs,
               Parse,
               ParseMode,
               Extraction,
               Options,
               Outcome) :-
    project_source_tree_parse(Registry, File, Source, Tree, ParseOutcome),
    (   ParseOutcome = error(Error)
    ->  source_parse_failure(Error)
    ;   ParseOutcome = ok(ParseProvenance)
    ),
    setup_call_cleanup(
        true,
        ( rlm_tree_sitter:ts_tree_root(Tree, Root),
          must_query_stage(parse_publish,
                           complete_query_parse(Registry,
                                                File,
                                                Parse,
                                                ContentHash,
                                                ParseProvenance,
                                                ParseMode)),
          get_dict(subtree, Options, Subtree),
          must_query_stage(execution_root,
                           execution_root(Root,
                                          Parse,
                                          Subtree,
                                          ExecutionRoot)),
          must_query_stage(pack_language,
                           require_pack_languages(Packs,
                                                  ParseProvenance.language)),
          must_query_stage(run_packs,
                           run_packs(Registry,
                                     Packs,
                                     ExecutionRoot,
                                     Root,
                                     Parse,
                                     ParseProvenance,
                                     Extraction,
                                     Options,
                                     Matches,
                                     Status,
                                     Reason)),
          must_query_stage(extraction_record,
                           extraction_record(FileRecord,
                                             File,
                                             ContentHash,
                                             Packs,
                                             Parse,
                                             ParseProvenance,
                                             Extraction,
                                             Matches,
                                             Status,
                                             Reason,
                                             Record)),
          must_query_stage(publish,
                           publish_extraction(Registry,
                                              File,
                                              FileRecord.project,
                                              Extraction,
                                              Packs,
                                              Record,
                                              Matches)),
          extraction_outcome(Status,
                             Record,
                             Matches,
                             Outcome)
        ),
        rlm_tree_sitter:ts_tree_close(Tree, _)
    ).

source_parse_failure(Error) :-
    sub_term(time_limit_exceeded, Error),
    !,
    throw(project_query_timeout).
source_parse_failure(Error) :-
    throw(project_query_fault(source_parse_failed(Error))).

extraction_outcome(complete, Record, Matches, ok(Summary)) :-
    Summary = project_query_summary{extraction:Record.extraction,
                                    parse:Record.parse,
                                    status:complete,
                                    reason:none,
                                    match_count:Record.match_count,
                                    capture_count:Record.capture_count,
                                    matches:Matches,
                                    provenance:Record.provenance}.
extraction_outcome(partial(Detail), Record, Matches, partial(Summary)) :-
    Summary = project_query_summary{extraction:Record.extraction,
                                    parse:Record.parse,
                                    status:partial,
                                    reason:Detail,
                                    match_count:Record.match_count,
                                    capture_count:Record.capture_count,
                                    matches:Matches,
                                    provenance:Record.provenance}.

must_query_stage(_, Goal) :-
    call(Goal),
    !.
must_query_stage(Stage, _) :-
    throw(project_query_fault(stage_failed(Stage))).

/* Native query execution ---------------------------------------------- */

run_packs(_, [], _, _, _, _, _, _, [], complete, none).
run_packs(Registry,
          [Pack|Packs],
          ExecutionRoot,
          ParseRoot,
          Parse,
          ParseProvenance,
          Extraction,
          Options,
          Matches,
          Status,
          Reason) :-
    query_for_pack(Registry, Pack, Query),
    setup_call_cleanup(
        rlm_tree_sitter:ts_query_cursor_create(Cursor),
        ( apply_cursor_options(Cursor, Options),
          rlm_tree_sitter:ts_query_cursor_set_match_limit(Cursor,
                                                          Options.max_matches),
          rlm_tree_sitter:ts_query_cursor_exec(Cursor, Query, ExecutionRoot),
          get_time(Start),
          Deadline is Start + Options.timeout_seconds,
          collect_query_matches(Cursor,
                                Query,
                                Pack,
                                ParseRoot,
                                Parse,
                                ParseProvenance,
                                Extraction,
                                Options,
                                Deadline,
                                [],
                                0,
                                0,
                                PackMatches,
                                PackStatus,
                                PackReason)
        ),
        rlm_tree_sitter:ts_query_cursor_close(Cursor, _)
    ),
    run_packs(Registry,
              Packs,
              ExecutionRoot,
              ParseRoot,
              Parse,
              ParseProvenance,
              Extraction,
              Options,
              RestMatches,
              RestStatus,
              RestReason),
    append(PackMatches, RestMatches, Matches),
    combine_status(PackStatus, PackReason, RestStatus, RestReason, Status, Reason).

collect_query_matches(_, _, _, _, _, _, _, Options, _, Matches, MatchCount,
                      _CaptureCount, MatchesOut, partial(limit(max_matches,
                                                          Options.max_matches)),
                      _Reason) :-
    MatchCount >= Options.max_matches,
    reverse(Matches, MatchesOut),
    !.
collect_query_matches(_, _, _, _, _, _, _, Options, _Deadline, Matches, _MatchCount,
                      CaptureCount, MatchesOut, partial(limit(max_captures,
                                                          Options.max_captures)),
                      _Reason) :-
    CaptureCount >= Options.max_captures,
    reverse(Matches, MatchesOut),
    !.
collect_query_matches(_, _, _, _, _, _, _, _, Deadline, _, _, _, _, _, _) :-
    get_time(Now),
    Now > Deadline,
    !,
    throw(project_query_timeout).
collect_query_matches(Cursor,
                      Query,
                      Pack,
                      ParseRoot,
                      Parse,
                      ParseProvenance,
                      Extraction,
                      Options,
                      Deadline,
                      Matches0,
                      MatchCount0,
                      CaptureCount0,
                      Matches,
                      Status,
                      Reason) :-
    (   rlm_tree_sitter:ts_query_next_match(Cursor, NativeMatch)
    ->  NativeMatch = ts_match(Id, PatternIndex, NativeCaptures),
        length(NativeCaptures, CaptureCount),
        CaptureCount1 is CaptureCount0 + CaptureCount,
        (   CaptureCount1 > Options.max_captures
        ->  reverse(Matches0, Matches),
            Status = partial(limit(max_captures, Options.max_captures)),
            Reason = limit(max_captures, Options.max_captures)
        ;   project_match(Query,
                          Pack,
                          ParseRoot,
                          Parse,
                          ParseProvenance,
                          Extraction,
                          Id,
                          PatternIndex,
                          NativeCaptures,
                          Match),
            MatchCount1 is MatchCount0 + 1,
            collect_query_matches(Cursor,
                                  Query,
                                  Pack,
                                  ParseRoot,
                                  Parse,
                                  ParseProvenance,
                                  Extraction,
                                  Options,
                                  Deadline,
                                  [Match|Matches0],
                                  MatchCount1,
                                  CaptureCount1,
                                  Matches,
                                  Status,
                                  Reason)
        )
    ;   ( rlm_tree_sitter:ts_query_did_exceed_match_limit(Cursor)
        -> reverse(Matches0, Matches),
           Status = partial(match_limit),
           Reason = match_limit
        ;  reverse(Matches0, Matches),
           Status = complete,
           Reason = none
        )
    ).

project_match(Query,
              Pack,
              ParseRoot,
              Parse,
              ParseProvenance,
              Extraction,
              Id,
              PatternIndex,
              NativeCaptures,
              Match) :-
    map_native_captures(NativeCaptures,
                        0,
                        Query,
                        Pack,
                        ParseRoot,
                        Parse,
                        ParseProvenance,
                        Captures),
    Match = project_query_match{extraction:Extraction,
                                id:Id,
                                pattern_index:PatternIndex,
                                pack_identity:Pack.identity,
                                captures:Captures}.

map_native_captures([], _, _, _, _, _, _, []).
map_native_captures([ts_capture(CaptureId, NativeNode)|Rest],
                    Ordinal,
                    Query,
                    Pack,
                    ParseRoot,
                    Parse,
                    ParseProvenance,
                    [Capture|Captures]) :-
    rlm_tree_sitter:ts_query_capture_name(Query, CaptureId, Name),
    rlm_tree_sitter:ts_node_start_byte(NativeNode, StartByte),
    rlm_tree_sitter:ts_node_end_byte(NativeNode, EndByte),
    rlm_tree_sitter:ts_node_start_point(NativeNode, StartPoint),
    rlm_tree_sitter:ts_node_end_point(NativeNode, EndPoint),
    native_node_path(NativeNode, Path),
    Node = syntax_node(Parse, Path),
    parse_generation(Parse, ParseGeneration),
    Capture = project_query_capture{ordinal:Ordinal,
                                    capture_id:CaptureId,
                                    name:Name,
                                    node:Node,
                                    parse:Parse,
                                    parse_generation:ParseGeneration,
                                    start_byte:StartByte,
                                    end_byte:EndByte,
                                    start_point:StartPoint,
                                    end_point:EndPoint,
                                    project:ParseProvenance.project,
                                    file:ParseProvenance.file,
                                    grammar_ref:ParseProvenance.grammar_ref,
                                    pack_identity:Pack.identity,
                                    pack_sha256:Pack.sha256,
                                    provenance:query_capture_provenance{
                                                 language:Pack.language,
                                                 grammar_ref:ParseProvenance.grammar_ref,
                                                 pack_identity:Pack.identity,
                                                 pack_sha256:Pack.sha256,
                                                 query_source_sha256:Pack.sha256,
                                                 project:ParseProvenance.project,
                                                 file:ParseProvenance.file,
                                                 parse_generation:ParseGeneration,
                                                 node:Node,
                                                 start_byte:StartByte,
                                                 end_byte:EndByte}},
    NextOrdinal is Ordinal + 1,
    map_native_captures(Rest,
                        NextOrdinal,
                        Query,
                        Pack,
                        ParseRoot,
                        Parse,
                        ParseProvenance,
                        Captures).

require_pack_languages([], _).
require_pack_languages([Pack|Packs], Language) :-
    (   Pack.language == Language
    ->  require_pack_languages(Packs, Language)
    ;   throw(project_query_fault(query_language_mismatch(Pack.language,
                                                          Language)))
    ).

native_node_path(Node, Path) :-
    (   rlm_tree_sitter:ts_node_parent(Node, Parent)
    ->  rlm_tree_sitter:ts_node_child_index(Node, Index),
        native_node_path(Parent, ParentPath),
        append(ParentPath, [Index], Path)
    ;   Path = []
    ).

apply_cursor_options(Cursor, Options) :-
    get_dict(range, Options, Range),
    (   Range = byte(Start, End)
    ->  rlm_tree_sitter:ts_query_cursor_set_byte_range(Cursor, Start, End)
    ;   Range = point(StartPoint, EndPoint)
    ->  rlm_tree_sitter:ts_query_cursor_set_point_range(Cursor,
                                                        StartPoint,
                                                        EndPoint)
    ;   true
    ).

execution_root(Root, _, none, Root) :- !.
execution_root(Root, Parse, Node, ExecutionRoot) :-
    !,
    (   Node = syntax_node(Parse, Path),
        is_list(Path),
        (   map_node_path(Root, Path, ExecutionRoot)
        ->  true
        ;   throw(project_query_fault(invalid_subtree_path(Path)))
        )
    ->  true
    ;   throw(project_query_fault(invalid_subtree(Node)))
    ).

map_node_path(Node, [], Node).
map_node_path(Node, [Index|Path], Descendant) :-
    integer(Index),
    Index >= 0,
    rlm_tree_sitter:ts_node_child(Node, Index, Child),
    map_node_path(Child, Path, Descendant).

query_for_pack(Registry, Pack, Query) :-
    registry_id(Registry, Id),
    rlm_project_source:project_source_tree_sitter_language(Registry,
                                                           Pack.language,
                                                           GrammarRef,
                                                           LanguageHandle),
    Key = query_cache_key(Pack.language, GrammarRef, Pack.sha256),
    with_mutex(rlm_project_query,
               ( query_cache(Id, Key, Query)
               -> true
               ;  compile_query(LanguageHandle, Pack, Query),
                  cache_query_locked(Id, Key, Query)
               )).

compile_query(LanguageHandle, Pack, Query) :-
    catch(rlm_tree_sitter:ts_query_compile(LanguageHandle,
                                           Pack.source,
                                           Query),
          Exception,
          project_query_compile_failure(Pack.identity, Exception)),
    rlm_tree_sitter:ts_query_pattern_count(Query, PatternCount),
    reject_query_predicates(Query, 0, PatternCount, Pack),
    !.

project_query_compile_failure(PackIdentity,
                              error(tree_sitter_error(query_compile(Kind,
                                                                    Offset),
                                                      Point),
                                    _)) :-
    !,
    throw(project_query_fault(query_compile(PackIdentity,
                                            Kind,
                                            Offset,
                                            Point))).
project_query_compile_failure(PackIdentity, Exception) :-
    throw(project_query_fault(query_compile_failed(PackIdentity,
                                                    Exception))).

reject_query_predicates(_, Pattern, Pattern, _).
reject_query_predicates(Query, Pattern, PatternCount, Pack) :-
    Pattern < PatternCount,
    rlm_tree_sitter:ts_query_predicates(Query, Pattern, Predicates),
    (   Predicates == []
    ->  NextPattern is Pattern + 1,
        reject_query_predicates(Query, NextPattern, PatternCount, Pack)
    ;   rlm_tree_sitter:ts_query_close(Query, _),
        throw(project_query_fault(unsupported_predicate(Pack.identity,
                                                        Pattern,
                                                        Predicates)))
    ).

cache_query_locked(Id, Key, Query) :-
    assertz(query_cache(Id, Key, Query)),
    (   query_cache_order(Id, Existing)
    ->  append(Existing, [Key], Order)
    ;   Order = [Key]
    ),
    trim_query_cache(Id, Order),
    !.

trim_query_cache(Id, Order) :-
    length(Order, Length),
    (   Length =< 32
    ->  retractall(query_cache_order(Id, _)),
        assertz(query_cache_order(Id, Order))
    ;   Order = [OldKey|Rest],
        retract(query_cache(Id, OldKey, OldQuery)),
        rlm_tree_sitter:ts_query_close(OldQuery, _),
        trim_query_cache(Id, Rest)
    ).

combine_status(partial(Reason), Reason, _, _, partial(Reason), Reason) :- !.
combine_status(_, _, partial(Reason), Reason, partial(Reason), Reason) :- !.
combine_status(complete, none, complete, none, complete, none).

/* Parse and extraction admission/currentness -------------------------- */

reserve_query_parse(Registry, File, ContentHash, Parse, reuse) :-
    registry_id(Registry, Id),
    with_mutex(rlm_project_source_registry,
               with_mutex(rlm_project_query,
                          reusable_query_parse(Id,
                                               File,
                                               ContentHash,
                                               Parse))),
    !.
reserve_query_parse(Registry, File, _ContentHash, Parse, fresh) :-
    registry_id(Registry, Id),
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_query,
                            reserve_query_parse_locked(Id, File, Parse))
               )).

reusable_query_parse(Id, File, ContentHash, Parse) :-
    query_current_parse(Id, File, Parse),
    query_parse_fact(Id, Parse, Record),
    Record.currentness == current,
    Record.content_hash == ContentHash,
    query_latest_parse(Id, File, Generation, complete),
    Parse = syntax_parse(File, Generation).

reserve_query_parse_locked(Id, File, Parse) :-
    next_counter(query_parse_counter, Id, File, Generation),
    Parse = syntax_parse(File, Generation),
    retractall(query_latest_parse(Id, File, _, _)),
    assertz(query_latest_parse(Id, File, Generation, pending)),
    mark_current_parse_pending(Id, File, Generation).

mark_current_parse_pending(Id, File, Generation) :-
    query_current_parse(Id, File, Parse),
    retract(query_parse_fact(Id, Parse, Record0)),
    !,
    assertz(query_parse_fact(Id,
                            Parse,
                            Record0.put(currentness,
                                        indeterminate(pending(Generation))))),
    retractall(query_current_parse(Id, File, Parse)).
mark_current_parse_pending(_, _, _).

complete_query_parse(Registry,
                     File,
                     Parse,
                     ContentHash,
                     ParseProvenance,
                     ParseMode) :-
    registry_id(Registry, Id),
    Parse = syntax_parse(File, Generation),
    ParseRecord = project_query_parse{
                      parse:Parse,
                      file:File,
                      project:ParseProvenance.project,
                      language:ParseProvenance.language,
                      backend:ParseProvenance.backend,
                      grammar_ref:ParseProvenance.grammar_ref,
                      file_hash:ParseProvenance.file_hash,
                      file_generation:ParseProvenance.file_generation,
                      content_hash:ContentHash,
                      generation:Generation,
                      currentness:current,
                      provenance:ParseProvenance.selection_provenance
                  },
    with_mutex(rlm_project_source_registry,
               with_mutex(rlm_project_query,
                          publish_query_parse_locked(Id,
                                                     File,
                                                     Parse,
                                                     ParseRecord,
                                                     ParseMode))).

publish_query_parse_locked(Id, File, Parse, Record, fresh) :-
    !,
    query_latest_parse(Id, File, Record.generation, pending),
    retractall(query_latest_parse(Id, File, Record.generation, pending)),
    assertz(query_latest_parse(Id, File, Record.generation, complete)),
    retractall(query_parse_fact(Id, Parse, _)),
    assertz(query_parse_fact(Id, Parse, Record)),
    retractall(query_current_parse(Id, File, _)),
    assertz(query_current_parse(Id, File, Parse)),
    fence_prior_parse_records(Id, File).
publish_query_parse_locked(Id, File, Parse, Record, reuse) :-
    query_latest_parse(Id, File, Record.generation, complete),
    query_current_parse(Id, File, Parse),
    retractall(query_parse_fact(Id, Parse, _)),
    assertz(query_parse_fact(Id, Parse, Record)),
    retractall(query_current_parse(Id, File, _)),
    assertz(query_current_parse(Id, File, Parse)).

/* A successful publication is authoritative: no earlier record for the file
   may remain indeterminate(pending(...)).  Fence every such prior record to
   the explicit terminal stale currentness. */
fence_prior_parse_records(Id, File) :-
    findall(Prior-Record0,
            ( query_parse_fact(Id, Prior, Record0),
              Prior = syntax_parse(File, _),
              Record0.currentness = indeterminate(pending(_))
            ),
            Superseded),
    forall(member(Prior-Record0, Superseded),
           ( retractall(query_parse_fact(Id, Prior, _)),
             assertz(query_parse_fact(Id,
                                      Prior,
                                      Record0.put(currentness, stale)))
           )).

reject_query_admission(Registry, File, Parse, Extraction) :-
    catch(registry_id(Registry, Id), _, fail),
    with_mutex(rlm_project_query,
               ( Parse = syntax_parse(File, ParseGeneration),
                 retractall(query_latest_parse(Id,
                                               File,
                                               ParseGeneration,
                                               pending)),
                 assertz(query_latest_parse(Id,
                                            File,
                                            ParseGeneration,
                                            rejected)),
                 retractall(query_latest_extraction(Id, File, Extraction)),
                 mark_pending_parse_stale(Id, File, ParseGeneration),
                 mark_pending_extraction_stale(Id, File, Extraction),
                 mark_extraction_stale(Id, File, Extraction)
               )).

mark_pending_parse_stale(Id, File, ParseGeneration) :-
    Parse = syntax_parse(File, _),
    query_parse_fact(Id,
                     Parse,
                     Record0),
    Record0.currentness = indeterminate(pending(ParseGeneration)),
    retractall(query_parse_fact(Id, Parse, _)),
    assertz(query_parse_fact(Id, Parse, Record0.put(currentness, stale))),
    !.
mark_pending_parse_stale(_, _, _).

mark_pending_extraction_stale(Id, File, Extraction) :-
    query_extraction_fact(Id, File, Existing, Record0),
    Record0.currentness = indeterminate(pending(Extraction)),
    retractall(query_extraction_fact(Id, File, Existing, _)),
    assertz(query_extraction_fact(Id,
                                  File,
                                  Existing,
                                  Record0.put(currentness, stale))),
    !.
mark_pending_extraction_stale(_, _, _).

reserve_extraction(Registry, File, _Parse, Packs, Extraction) :-
    registry_id(Registry, Id),
    next_counter(query_extraction_counter, Id, File, Generation),
    Extraction = query_extraction(File, Generation),
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_query,
                            ( retractall(query_latest_extraction(Id,
                                                                 File,
                                                                 _)),
                              assertz(query_latest_extraction(Id,
                                                              File,
                                                              Extraction)),
                              mark_current_extraction_pending(Id,
                                                              File,
                                                               Extraction,
                                                               Packs)
                            ))
               )).

mark_current_extraction_pending(Id, File, Extraction, _) :-
    query_current_extraction(Id, File, Existing),
    retract(query_extraction_fact(Id, File, Existing, Record0)),
    !,
    assertz(query_extraction_fact(Id,
                                  File,
                                  Existing,
                                  Record0.put(currentness,
                                              indeterminate(pending(Extraction))))),
    retractall(query_current_extraction(Id, File, Existing)).
mark_current_extraction_pending(_, _, _, _).

mark_extraction_stale(Id, File, Extraction) :-
    query_extraction_fact(Id, File, Extraction, Record0),
    retractall(query_extraction_fact(Id, File, Extraction, _)),
    assertz(query_extraction_fact(Id,
                                  File,
                                  Extraction,
                                  Record0.put(currentness, stale))),
    retractall(query_current_extraction(Id, File, Extraction)).
mark_extraction_stale(_, _, _).

mark_pack_extractions_stale(Id, Language, Purpose) :-
    findall(File-Extraction-Record,
            ( query_extraction_fact(Id, File, Extraction, Record),
              memberchk(Purpose, Record.purposes),
              Record.language == Language
            ),
            Rows),
    forall(member(File-Extraction-Record, Rows),
           ( retractall(query_extraction_fact(Id, File, Extraction, _)),
             StaleRecord = Record.put(currentness, stale),
             assertz(query_extraction_fact(Id, File, Extraction, StaleRecord)),
             retractall(query_current_extraction(Id, File, Extraction))
             , persist_stale_extraction(Id, Extraction, StaleRecord)
           )).

persist_stale_extraction(Id, Extraction, Record) :-
    query_persistence(Id, Project, _),
    !,
    project_query_persist_replace(Project, Extraction, Record).
persist_stale_extraction(_, _, _).

publish_extraction(Registry,
                   File,
                   Project,
                   Extraction,
                   Packs,
                   Record,
                   Matches) :-
    registry_id(Registry, Id),
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_query,
                            ( query_latest_extraction(Id,
                                                      File,
                                                      Extraction),
                              packs_remain_current(Id, Packs),
                              project_query_persist_append(Project,
                                                           Extraction,
                                                           Record,
                                                           Matches),
                              retractall(query_extraction_fact(Id,
                                                               File,
                                                               Extraction,
                                                               _)),
                              assertz(query_extraction_fact(Id,
                                                            File,
                                                            Extraction,
                                                            Record)),
                              retractall(query_current_extraction(Id,
                                                                  File,
                                                                  _)),
                              assertz(query_current_extraction(Id,
                                                               File,
                                                               Extraction)),
                              forall(member(Match, Matches),
                                     assertz(query_match_fact(Id,
                                                              File,
                                                              Extraction,
                                                              Match))),
                              fence_prior_extraction_records(Id, File)
                            ))
               )).

/* Publication fencing twin of fence_prior_parse_records/2: prior extraction
   records for the file must not survive as indeterminate(pending(...)) once a
   newer extraction is authoritative.  The stale currentness is persisted so a
   restart cannot resurrect a superseded record as current. */
fence_prior_extraction_records(Id, File) :-
    findall(Extraction-Record0,
            ( query_extraction_fact(Id, File, Extraction, Record0),
              Record0.currentness = indeterminate(pending(_))
            ),
            Superseded),
    forall(member(Extraction-Record0, Superseded),
           ( StaleRecord = Record0.put(currentness, stale),
             retractall(query_extraction_fact(Id, File, Extraction, _)),
             assertz(query_extraction_fact(Id,
                                           File,
                                           Extraction,
                                           StaleRecord)),
             persist_stale_extraction(Id, Extraction, StaleRecord)
           )).

packs_remain_current(_, []).
packs_remain_current(Id, [Pack|Packs]) :-
    query_pack_active(Id,
                      Pack.language,
                      Pack.purpose,
                      Current),
    Current.identity == Pack.identity,
    Current.sha256 == Pack.sha256,
    !,
    packs_remain_current(Id, Packs).
packs_remain_current(_, [Pack|_]) :-
    throw(project_query_fault(stale_query_pack(Pack.identity))).

/* Pack/extraction records --------------------------------------------- */

extraction_record(FileRecord,
                  File,
                  ContentHash,
                  Packs,
                  Parse,
                  ParseProvenance,
                  Extraction,
                  Matches,
                  Status,
                  Reason,
                  Record) :-
    maplist(pack_identity_value, Packs, PackIdentities),
    maplist(pack_hash_value, Packs, PackHashes),
    maplist(pack_grammar_value(ParseProvenance), Packs, GrammarRefs),
    maplist(pack_provenance_value, Packs, PackProvenance),
    first(Packs, FirstPack),
    length(Matches, MatchCount),
    findall(Capture,
            ( member(Match, Matches),
              member(Capture, Match.captures)
            ),
            AllCaptures),
    length(AllCaptures, CaptureCount),
    extraction_record_status(Status, Reason, RecordStatus),
    parse_generation(Parse, ParseGeneration),
    Record = project_query_extraction{
                 extraction:Extraction,
                 parse:Parse,
                 project:FileRecord.project,
                 file:File,
                 language:ParseProvenance.language,
                 backend:ParseProvenance.backend,
                 grammar_ref:ParseProvenance.grammar_ref,
                 grammar_refs:GrammarRefs,
                 pack_identity:FirstPack.identity,
                 pack_identities:PackIdentities,
                 pack_sha256:FirstPack.sha256,
                 pack_sha256s:PackHashes,
                 query_source_sha256:FirstPack.sha256,
                 purposes:PackPurposes,
                 parse_generation:ParseGeneration,
                 status:RecordStatus,
                 reason:Reason,
                 currentness:current,
                 match_count:MatchCount,
                 capture_count:CaptureCount,
                 file_hash:FileRecord.hash,
                 file_generation:FileRecord.generation,
                 content_hash:ContentHash,
                 provenance:query_extraction_provenance{project:FileRecord.project,
                              file:File,
                              language:ParseProvenance.language,
                              backend:ParseProvenance.backend,
                              grammar_ref:ParseProvenance.grammar_ref,
                              pack_identities:PackIdentities,
                              pack_sha256s:PackHashes,
                              parse:Parse,
                              parse_generation:ParseGeneration,
                              content_hash:ContentHash,
                              query_source_sha256:FirstPack.sha256,
                              pack_provenance:PackProvenance}
             },
    findall(Purpose,
            ( member(Pack, Packs),
              Purpose = Pack.purpose
            ),
            PackPurposes).

extraction_record_status(complete, none, complete) :- !.
extraction_record_status(partial(Reason), Reason, partial).

parse_generation(syntax_parse(_, Generation), Generation).

pack_identity_value(Pack, Pack.identity).
pack_hash_value(Pack, Pack.sha256).
pack_grammar_value(ParseProvenance, _Pack, ParseProvenance.grammar_ref).
pack_provenance_value(Pack, query_pack_provenance{identity:Pack.identity,
                              language:Pack.language,
                              purpose:Pack.purpose,
                              sha256:Pack.sha256,
                              version:Pack.version,
                              provenance:Pack.provenance}).

first([Value|_], Value).

/* Public observation queries ------------------------------------------ */

project_query_current_extraction(Registry, File, Extraction) :-
    registry_id(Registry, Id),
    (   query_current_extraction(Id, File, Extraction)
    ->  true
    ;   project_source_file(Registry, File, FileRecord),
        project_source_project(Registry, FileRecord.project, ProjectMeta),
        ensure_project_persistence_root(Registry,
                                        FileRecord.project,
                                        ProjectMeta,
                                        none),
        query_current_extraction(Id, File, Extraction)
    ).

project_query_matches(Registry, Extraction, Match) :-
    registry_id(Registry, Id),
    query_match_fact(Id, _, Extraction, Match).

project_query_captures(Registry, Extraction, Capture) :-
    project_query_matches(Registry, Extraction, Match),
    member(Capture, Match.captures).

project_query_node_provenance(Registry, Node, Provenance) :-
    registry_id(Registry, Id),
    query_match_fact(Id, _, _, Match),
    member(Capture, Match.captures),
    Node = Capture.node,
    Provenance = project_query_node_provenance{
                     project:Capture.provenance.project,
                     file:Capture.provenance.file,
                     language:Capture.provenance.language,
                     grammar_ref:Capture.provenance.grammar_ref,
                     pack_identity:Capture.provenance.pack_identity,
                     pack_sha256:Capture.provenance.pack_sha256,
                     query_source_sha256:Capture.provenance.query_source_sha256,
                     parse:Capture.parse,
                     parse_generation:Capture.parse_generation,
                     node:Node,
                     start_byte:Capture.start_byte,
                     end_byte:Capture.end_byte,
                     start_point:Capture.start_point,
                     end_point:Capture.end_point,
                     extraction:Match.extraction
                 }.

project_query_registry_clear(Registry) :-
    (   Registry = project_source_registry(Id)
    ->  true
    ;   fail
    ),
    with_mutex(rlm_project_query,
               ( findall(Query,
                         query_cache(Id, _, Query),
                         Queries),
                 maplist(close_cached_query, Queries),
                 retractall(query_pack_record(Id, _, _, _)),
                 retractall(query_pack_active(Id, _, _, _)),
                 retractall(query_cache(Id, _, _)),
                 retractall(query_cache_order(Id, _)),
                 retractall(query_parse_counter(Id, _, _)),
                 retractall(query_latest_parse(Id, _, _, _)),
                 retractall(query_parse_fact(Id, _, _)),
                 retractall(query_current_parse(Id, _, _)),
                 retractall(query_extraction_counter(Id, _, _)),
                 retractall(query_latest_extraction(Id, _, _)),
                 retractall(query_extraction_fact(Id, _, _, _)),
                 retractall(query_match_fact(Id, _, _, _)),
                 retractall(query_current_extraction(Id, _, _)),
                 ( query_persistence(Id, _, _)
                 -> retractall(query_persistence(Id, _, _)),
                    project_query_persist_close
                 ;  true
                 )
               )).

close_cached_query(Query) :-
    catch(rlm_tree_sitter:ts_query_close(Query, _), _, true).

/* Persistence ---------------------------------------------------------- */

ensure_project_persistence(Registry, Project, ProjectMeta, Options) :-
    get_dict(kb_root, Options, Root),
    ensure_project_persistence_root(Registry, Project, ProjectMeta, Root).

ensure_project_persistence_root(Registry, Project, ProjectMeta, Root) :-
    registry_id(Registry, Id),
    project_query_kb_file(Project, ProjectMeta, Root, Path),
    (   query_persistence(Id, Project, Path)
    ->  true
    ;   project_query_persist_open(Path, OpenOutcome),
        (   OpenOutcome = ok(_)
        ->  hydrate_persistence(Id, Project),
            retractall(query_persistence(Id, _, _)),
            assertz(query_persistence(Id, Project, Path))
        ;   throw(project_query_fault(kb_unwritable(OpenOutcome)))
        )
    ).

hydrate_persistence(Id, Project) :-
    project_query_persist_snapshot(Project, Records, Matches),
    forall(member(Extraction-Record, Records),
           hydrate_extraction(Id, Extraction, Record)),
    forall(member(Extraction-_-Match, Matches),
           hydrate_match(Id, Extraction, Match)),
    hydrate_counters(Id, Records).

hydrate_extraction(Id, Extraction, Record) :-
    Extraction = query_extraction(File, _Generation),
    (   query_extraction_fact(Id, File, Extraction, _)
    ->  true
    ;   assertz(query_extraction_fact(Id, File, Extraction, Record))
    ),
    (   Record.currentness == current
    ->  retractall(query_current_extraction(Id, File, _)),
        assertz(query_current_extraction(Id, File, Extraction))
    ;   true
    ),
    retractall(query_latest_extraction(Id, File, _)),
    assertz(query_latest_extraction(Id, File, Extraction)),
    hydrate_query_parse(Id, File, Record).

hydrate_query_parse(Id, File, Record) :-
    Record.currentness == current,
    Record.parse = syntax_parse(File, ParseGeneration),
    retractall(query_parse_fact(Id, Record.parse, _)),
    assertz(query_parse_fact(Id,
                            Record.parse,
                            project_query_parse{
                                parse:Record.parse,
                                file:File,
                                content_hash:Record.content_hash,
                                generation:ParseGeneration,
                                currentness:current
                            })),
    retractall(query_current_parse(Id, File, _)),
    assertz(query_current_parse(Id, File, Record.parse)),
    retractall(query_latest_parse(Id, File, ParseGeneration, _)),
    assertz(query_latest_parse(Id, File, ParseGeneration, complete)),
    !.
hydrate_query_parse(_, _, _).

hydrate_match(Id, Extraction, Match) :-
    Extraction = query_extraction(File, _),
    (   query_match_fact(Id, File, Extraction, Match)
    ->  true
    ;   assertz(query_match_fact(Id, File, Extraction, Match))
    ).

hydrate_counters(Id, Records) :-
    findall(File-Generation,
            ( member(Extraction-_, Records),
              Extraction = query_extraction(File, Generation)
            ),
            ExtractionRows),
    sort(ExtractionRows, UniqueExtractionRows),
    hydrate_extraction_counter_files(Id, UniqueExtractionRows),
    findall(File-Generation,
            ( member(_-Record, Records),
              Record.parse = syntax_parse(File, Generation)
            ),
            Rows),
    sort(Rows, UniqueRows),
    hydrate_counter_files(Id, UniqueRows).

hydrate_extraction_counter_files(_, []).
hydrate_extraction_counter_files(Id, Rows) :-
    Rows = [File-_|_],
    findall(Generation,
            member(File-Generation, Rows),
            Generations),
    max_list(Generations, Maximum),
    retractall(query_extraction_counter(Id, File, _)),
    assertz(query_extraction_counter(Id, File, Maximum)),
    exclude(same_file_row(File), Rows, Rest),
    hydrate_extraction_counter_files(Id, Rest).

hydrate_counter_files(_, []).
hydrate_counter_files(Id, Rows) :-
    Rows = [File-_|_],
    findall(Generation,
            member(File-Generation, Rows),
            Generations),
    max_list(Generations, Maximum),
    retractall(query_parse_counter(Id, File, _)),
    assertz(query_parse_counter(Id, File, Maximum)),
    exclude(same_file_row(File), Rows, Rest),
    hydrate_counter_files(Id, Rest).

same_file_row(File, File-_).

project_query_kb_file(Project, ProjectMeta, OptionRoot, Path) :-
    (   OptionRoot \== none
    ->  Root = OptionRoot
    ;   get_dict(project_root, ProjectMeta, Root)
    ->  true
    ;   throw(project_query_fault(kb_unwritable(no_project_root)))
    ),
    normalize_path(Root, RootAtom),
    (   is_absolute_file_name(RootAtom),
        exists_directory(RootAtom),
        access_file(RootAtom, write)
    ->  directory_file_path(RootAtom, '.kb', KBRoot),
        directory_file_path(KBRoot, 'project-query', QueryRoot),
        catch(make_directory_path(QueryRoot), _, fail),
        access_file(QueryRoot, write),
        project_filename(Project, FileName),
        directory_file_path(QueryRoot, FileName, Path)
    ;   throw(project_query_fault(kb_unwritable(RootAtom)))
    ).

project_filename(Project, FileName) :-
    with_output_to(string(Text), write_canonical(Project)),
    crypto_data_hash(Text,
                     Hash,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('project-', Hash, Prefix),
    atom_concat(Prefix, '.pl', FileName).

/* Validation and normalization ---------------------------------------- */

registry_id(Registry, Id) :-
    Registry = project_source_registry(Id),
    project_source_registry_valid(Registry),
    !.
registry_id(Registry, _) :-
    throw(project_query_fault(invalid_registry(Registry))).

active_packs(Id, Language, Purposes, Packs) :-
    maplist(active_pack(Id, Language), Purposes, Packs).

active_pack(Id, Language, Purpose, Pack) :-
    query_pack_active(Id, Language, Purpose, Pack),
    !,
    true.
active_pack(Id, _, Purpose, Pack) :-
    query_pack_active(Id, _, Purpose, Pack),
    !.
active_pack(_, _, Purpose, _) :-
    throw(project_query_fault(pack_not_active(Purpose))).

require_known_language(Resolution) :-
    memberchk(Resolution.status, [known, explicit_override]),
    Resolution.language \== unknown,
    !.
require_known_language(Resolution) :-
    throw(project_query_fault(language_unresolved(Resolution))).

normalize_purposes(Purposes0, Purposes) :-
    (   is_list(Purposes0)
    ->  ( Purposes0 == []
        -> throw(project_query_fault(invalid_purposes(Purposes0)))
        ;  Purposes1 = Purposes0
        )
    ;   ( atom(Purposes0) ; string(Purposes0) )
    ->  Purposes1 = [Purposes0]
    ;   throw(project_query_fault(invalid_purposes(Purposes0)))
    ),
    maplist(normalize_atom_purpose, Purposes1, Purposes).
normalize_atom_purpose(Value0, Value) :-
    normalize_atom(Value0, purpose, Value).

normalize_pack_meta(Meta0, Meta) :-
    is_dict(Meta0),
    dict_keys(Meta0, Keys),
    subtract(Keys, [identity, version, provenance], []),
    ( get_dict(identity, Meta0, Identity0) -> closed_data(Identity0, Identity) ; Identity = none ),
    ( get_dict(version, Meta0, Version0) -> closed_data(Version0, Version) ; Version = 1 ),
    ( get_dict(provenance, Meta0, Provenance0) -> closed_data(Provenance0, Provenance) ; Provenance = query_pack_provenance{} ),
    is_dict(Provenance),
    Meta = query_pack_meta{identity:Identity, version:Version, provenance:Provenance},
    !.
normalize_pack_meta(Value, _) :-
    throw(project_query_fault(invalid_pack_meta(Value))).

pack_identity(Language, Purpose, SourceHash, Meta, Identity) :-
    (   Meta.identity == none
    ->  Identity = query_pack(Language, Purpose, SourceHash)
    ;   Identity = Meta.identity
    ).

normalize_query_source(Source, Source) :-
    string(Source),
    !.
normalize_query_source(Source, Text) :-
    atom(Source),
    !,
    atom_string(Source, Text).
normalize_query_source(Source, _) :-
    throw(project_query_fault(type_error(query_source, Source))).

normalize_atom(Value, _, Value) :-
    atom(Value),
    Value \== '',
    !.
normalize_atom(Value, _, Atom) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Atom, Value).
normalize_atom(Value, Name, _) :-
    throw(project_query_fault(type_error(Name, Value))).

closed_data(Value0, _) :-
    var(Value0),
    !,
    throw(project_query_fault(non_ground_data)).
closed_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(closed_pair, Pairs0, Pairs),
    dict_pairs(Value, query_data, Pairs).
closed_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(closed_data, Values0, Values).
closed_data(Value0, Value) :-
    compound(Value0),
    !,
    (   acyclic_term(Value0)
    ->  Value0 =.. [Functor|Args0],
        maplist(closed_data, Args0, Args),
        Value =.. [Functor|Args]
    ;   throw(project_query_fault(cyclic_data))
    ).
closed_data(Value, Value) :-
    atomic(Value),
    !.
closed_data(Value, _) :-
    throw(project_query_fault(unsupported_data(Value))).

closed_pair(Key-Value0, Key-Value) :-
    atom(Key),
    closed_data(Value0, Value).
closed_pair(Key-_, _) :-
    throw(project_query_fault(invalid_dict_key(Key))).

query_options(Options0, Options) :-
    (   is_list(Options0)
    ->  true
    ;   throw(project_query_fault(invalid_options(Options0)))
    ),
    (   ground(Options0), acyclic_term(Options0)
    ->  true
    ;   throw(project_query_fault(non_ground_options))
    ),
    allowed_options(Options0),
    option(max_source_bytes(MaxSourceBytes), Options0, 1048576),
    option(max_matches(MaxMatches), Options0, 10000),
    option(max_captures(MaxCaptures), Options0, 50000),
    option(timeout_seconds(Timeout), Options0, 30.0),
    option(kb_root(KBRoot0), Options0, none),
    option(subtree(Subtree), Options0, none),
    reject_multiple_ranges(Options0),
    query_range(Options0, Range),
    require_nonnegative(max_source_bytes, MaxSourceBytes),
    require_positive(max_matches, MaxMatches),
    require_positive(max_captures, MaxCaptures),
    require_positive_number(timeout_seconds, Timeout),
    normalize_optional_path(KBRoot0, KBRoot),
    ( Subtree == none -> true ; true ),
    Options = query_options{max_source_bytes:MaxSourceBytes,
                            max_matches:MaxMatches,
                            max_captures:MaxCaptures,
                            timeout_seconds:Timeout,
                            kb_root:KBRoot,
                            subtree:Subtree,
                            range:Range}.

reject_multiple_ranges(Options) :-
    findall(Name,
            ( member(Option, Options),
              functor(Option, Name, Arity),
              memberchk(Name-Arity, [byte_range-2, point_range-2])
            ),
            Ranges),
    (   length(Ranges, Count),
        Count =< 1
    ->  true
    ;   throw(project_query_fault(multiple_ranges(Ranges)))
    ).

allowed_options([]).
allowed_options([Option|Options]) :-
    compound(Option),
    functor(Option, Name, Arity),
    memberchk(Name-Arity,
              [ max_source_bytes-1,
                max_matches-1,
                max_captures-1,
                timeout_seconds-1,
                kb_root-1,
                byte_range-2,
                point_range-2,
                subtree-1
              ]),
    !,
    allowed_options(Options).
allowed_options([Option|_]) :-
    throw(project_query_fault(invalid_option(Option))).

query_range(Options, byte(Start, End)) :-
    member(byte_range(Start0, End0), Options),
    !,
    require_nonnegative(byte_range_start, Start0),
    require_nonnegative(byte_range_end, End0),
    (   Start0 =< End0
    ->  true
    ;   throw(project_query_fault(invalid_byte_range(Start0, End0)))
    ),
    Start = Start0,
    End = End0.
query_range(Options, point(Start, End)) :-
    member(point_range(Start0, End0), Options),
    !,
    normalize_point(Start0, Start),
    normalize_point(End0, End),
    (   point_leq(Start, End)
    ->  true
    ;   throw(project_query_fault(invalid_point_range(Start, End)))
    ).
query_range(_, none).

normalize_point(point(Row, Column), point(Row, Column)) :-
    require_nonnegative(point_row, Row),
    require_nonnegative(point_column, Column),
    !.
normalize_point(Value, _) :-
    throw(project_query_fault(invalid_point(Value))).

point_leq(point(Row0, Column0), point(Row, Column)) :-
    Row0 < Row ; Row0 =:= Row, Column0 =< Column.

normalize_optional_path(none, none) :- !.
normalize_optional_path(Value0, Value) :-
    normalize_path(Value0, Value).

normalize_path(Value, Path) :-
    ( atom(Value) -> Path = Value ; string(Value) -> atom_string(Path, Value) ; fail ),
    !.
normalize_path(Value, _) :-
    throw(project_query_fault(invalid_path(Value))).

validate_registered_hash(unknown, _) :- !.
validate_registered_hash(Hash0, ContentHash) :-
    (   atom(Hash0)
    ->  Hash = Hash0
    ;   string(Hash0)
    ->  atom_string(Hash, Hash0)
    ;   throw(project_query_fault(invalid_file_hash(Hash0)))
    ),
    (   atom_concat('sha256:', Expected0, Hash)
    ->  Expected = Expected0
    ;   Expected = Hash
    ),
    downcase_atom(Expected, ExpectedLower),
    downcase_atom(ContentHash, ContentLower),
    (   ExpectedLower == ContentLower
    ->  true
    ;   throw(project_query_fault(source_hash_mismatch(Hash0, ContentHash)))
    ).

source_bytes(Source, Bytes) :-
    string_codes(Source, Codes),
    phrase(utf8_codes(Codes), Bytes).

enforce_source_limit(Bytes, Limit) :-
    (   Bytes =< Limit
    ->  true
    ;   throw(project_query_blocked(source_limit(Bytes, Limit)))
    ).

enforce_file_policy(Record, Options) :-
    enforce_file_flag(excluded, Record.excluded, Options),
    enforce_file_flag(vendor, Record.vendor, Options),
    enforce_file_flag(generated, Record.generated, Options).

enforce_file_flag(_, false, _) :- !.
enforce_file_flag(Name, true, Options) :-
    (   get_dict(include, Options, Includes), memberchk(Name, Includes)
    ->  true
    ;   throw(project_query_blocked(file_policy(Name)))
    ).

require_nonnegative(_, Value) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative(Name, Value) :-
    throw(project_query_fault(invalid_nonnegative(Name, Value))).

require_positive(_, Value) :-
    integer(Value),
    Value > 0,
    !.
require_positive(Name, Value) :-
    throw(project_query_fault(invalid_positive(Name, Value))).

require_positive_number(_, Value) :-
    number(Value),
    Value > 0,
    !.
require_positive_number(Name, Value) :-
    throw(project_query_fault(invalid_positive_number(Name, Value))).

next_counter(Predicate, Id, File, Generation) :-
    (   Predicate = query_parse_counter
    ->  ( retract(query_parse_counter(Id, File, Previous)) -> true ; Previous = 0 ),
        Generation is Previous + 1,
        assertz(query_parse_counter(Id, File, Generation))
    ;   ( retract(query_extraction_counter(Id, File, Previous)) -> true ; Previous = 0 ),
        Generation is Previous + 1,
        assertz(query_extraction_counter(Id, File, Generation))
    ).

project_query_exception(Operation,
                        project_query_fault(query_compile(PackIdentity,
                                                          Kind,
                                                          Offset,
                                                          Point)),
                        error(Error)) :-
    !,
    Error = project_query_error{kind:query_compile,
                                operation:Operation,
                                pack_identity:PackIdentity,
                                query_error:Kind,
                                byte_offset:Offset,
                                point:Point,
                                message:"Tree-sitter query compilation failed"}.
project_query_exception(Operation,
                        project_query_fault(Fault),
                        error(Error)) :-
    !,
    fault_kind(Fault, Kind),
    Error = project_query_error{kind:Kind,
                                operation:Operation,
                                detail:Fault,
                                message:"project query operation failed"}.
project_query_exception(Operation,
                        project_query_blocked(Detail),
                        blocked(Error)) :-
    !,
    fault_kind(Detail, Kind),
    Error = project_query_error{kind:Kind,
                                operation:Operation,
                                detail:Detail,
                                message:"project query operation blocked"}.
project_query_exception(Operation,
                        project_query_timeout,
                        error(Error)) :-
    !,
    Error = project_query_error{kind:timeout,
                                operation:Operation,
                                detail:deadline_exceeded}.
project_query_exception(Operation,
                        time_limit_exceeded,
                        error(Error)) :-
    !,
    Error = project_query_error{kind:timeout,
                                operation:Operation,
                                detail:deadline_exceeded}.
project_query_exception(Operation,
                        error(tree_sitter_error(query_compile(Kind, Offset),
                                                Point),
                              _),
                        error(Error)) :-
    !,
    Error = project_query_error{kind:query_compile,
                                operation:Operation,
                                query_error:Kind,
                                byte_offset:Offset,
                                point:Point,
                                message:"Tree-sitter query compilation failed"}.
project_query_exception(Operation, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = project_query_error{kind:project_query_exception,
                                operation:Operation,
                                exception:Safe,
                                context:Exception,
                                message:"project query operation raised an exception"}.

fault_kind(Fault, Kind) :-
    compound(Fault),
    !,
    functor(Fault, Kind, _).
fault_kind(Fault, Fault).

safe_exception(error(Formal, _), Formal) :- !.
safe_exception(Exception, Exception).
