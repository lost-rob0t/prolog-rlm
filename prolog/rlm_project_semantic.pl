:- module(rlm_project_semantic,
          [ rlm_project_semantic_ready/0,
            project_semantic_normalize/5,
            project_semantic_normalize_async/5,
            project_semantic_normalize_execute/5,
            project_semantic_knowledge_state/3,
            project_semantic_definitions/4,
            project_semantic_references/4,
            project_semantic_calls/4,
            project_semantic_imports/4,
            project_semantic_exports/4,
            project_semantic_contains/4,
            project_semantic_call_reachable/5,
            project_semantic_file_dependencies/5,
            project_semantic_resolve/4,
            project_semantic_symbol_index/3,
            project_semantic_observation_provenance/3,
            project_semantic_registry_clear/1
          ]).

/** <module> Normalized semantic project knowledge (#98)

This module turns the grouped #97 query captures into closed, provenance-
carrying semantic facts about project source: definitions, references, calls,
imports, and exports, plus bounded derived relations (span containment, call
reachability, file import dependencies).

Layering:

```text
#95 source registry -> #96 syntax -> #97 query captures
        -> semantic normalization (this module)
        -> public semantic query surface (consumed by #380 later)
```

Invariants implemented here:

- Extraction and resolution are separate operations. Normalization turns
  already-published #97 captures into direct observations only; resolution
  is an explicit, bounded second pass (`project_semantic_resolve/4`).
- Resolution is never faked: `resolved`, `unresolved`, `ambiguous`,
  `external`, and `unsupported` remain distinct. Duplicate names in
  different scopes or files stay distinct symbol identities.
- Every direct observation carries the full evidence chain: project, file,
  registered file hash/generation, exact source content hash, parse identity
  and generation, grammar reference, query pack identity/hash/purpose,
  adapter identity, syntax node, and byte/point span.
- Freshness reuses #97 currentness. Semantic reads answer only while the
  extraction they were derived from is the current extraction;
  `project_semantic_knowledge_state/3` reports `current`, `stale/1`, or
  `none`. Replacing a query pack marks dependent extractions stale, which
  invalidates the semantic state derived from them. Currentness authority is
  never journaled here: the #97 extraction journal remains authoritative, so
  a restart cannot resurrect superseded semantic facts as current.
- Zero matches from a supported capability are `normalized(0)` in the
  summary; a missing capability is `unsupported`. They never collapse.
- Derived relations are computed on demand from direct observations, carry
  their supporting observation identities, and are never persisted or
  published as direct evidence.

No model calls, no scheduler, no `consult/1` of project source, and no
filesystem, Git, process, network, tool, capability, or authority access is
added by this layer. Persistence only journals closed observation records
under the already-trusted project KB root, mirroring #97.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(utf8)).
:- use_module(rlm_async).
:- use_module(rlm_project_query).
:- use_module(rlm_project_semantic_persist).
:- use_module(rlm_project_source).

:- dynamic semantic_observation/4.
:- dynamic semantic_current/3.
:- dynamic semantic_persistence/3.
:- dynamic semantic_sequence/3.

rlm_project_semantic_ready.

semantic_adapter_version(1).

/* Closed symbol-kind set, aligned with the #288 symbol_ref contract. */
symbol_kind(function).
symbol_kind(method).
symbol_kind(constructor).
symbol_kind(predicate).
symbol_kind(rule).
symbol_kind(macro).
symbol_kind(operator).
symbol_kind(class).
symbol_kind(field).
symbol_kind(property).
symbol_kind(type).
symbol_kind(module).
symbol_kind(annotation).

/* Normalization ---------------------------------------------------------- */

project_semantic_normalize(Registry, File, Source0, Options0, Outcome) :-
    project_semantic_normalize_async(Registry,
                                     File,
                                     Source0,
                                     Options0,
                                     Future),
    setup_call_cleanup(true,
                       rlm_future_await(Future, Outcome),
                       rlm_future_destroy(Future)).

project_semantic_normalize_async(Registry,
                                 File,
                                 Source0,
                                 Options0,
                                 Future) :-
    rlm_async_submit(
        rlm_project_semantic:project_semantic_normalize_execute(Registry,
                                                                 File,
                                                                 Source0,
                                                                 Options0),
        Future).

project_semantic_normalize_execute(Registry,
                                   File,
                                   Source0,
                                   Options0,
                                   Outcome) :-
    catch(project_semantic_normalize_(Registry,
                                      File,
                                      Source0,
                                      Options0,
                                      Outcome),
          Exception,
          project_semantic_exception(normalize, Exception, Outcome)).

project_semantic_normalize_(Registry, File, Source0, Options0, Outcome) :-
    registry_id(Registry, Id),
    normalize_source_text(Source0, Source),
    normalize_options(Options0, Options),
    project_source_file(Registry, File, FileRecord),
    project_source_project(Registry, FileRecord.project, ProjectMeta),
    project_source_file_language(Registry, File, ok(LanguageResolution)),
    require_known_language(LanguageResolution),
    Language = LanguageResolution.language,
    crypto_data_hash(Source,
                     ContentHash,
                     [algorithm(sha256), encoding(utf8)]),
    validate_registered_hash(FileRecord.hash, ContentHash),
    require_current_extraction(Registry, Id, File, Extraction),
    project_query_extraction_record(Registry, Extraction, ExtractionRecord),
    require_exact_generation(ExtractionRecord, ContentHash),
    semantic_packs(Registry, Language, SemanticPacks),
    ensure_semantic_persistence(Registry,
                                FileRecord.project,
                                ProjectMeta,
                                Options.kb_root),
    semantic_sequence_base(Id, Extraction, SequenceBase),
    normalize_all_packs(Registry,
                        SemanticPacks,
                        ExtractionRecord,
                        FileRecord,
                        Language,
                        Source,
                        Blueprints,
                        PackStatuses,
                        Skipped),
    assign_observation_ids(Blueprints,
                           Extraction,
                           SequenceBase,
                           FileRecord.project,
                           Observations),
    length(Observations, ObservationCount),
    (   ObservationCount =< Options.max_observations
    ->  true
    ;   throw(project_semantic_fault(observation_limit(ObservationCount,
                                                       Options.max_observations)))
    ),
    publish_semantic(Registry, Id, FileRecord.project, File, Extraction,
                     Observations),
    complete_purpose_statuses(Language, SemanticPacks, PackStatuses,
                              PurposeStatuses),
    relation_counts(Observations,
                    Definitions,
                    References,
                    Calls,
                    Imports,
                    Exports),
    Summary = project_semantic_summary{project:FileRecord.project,
                                       file:File,
                                       language:Language,
                                       extraction:Extraction,
                                       content_hash:ContentHash,
                                       definitions:Definitions,
                                       references:References,
                                       calls:Calls,
                                       imports:Imports,
                                       exports:Exports,
                                       purposes:PurposeStatuses,
                                       skipped:Skipped,
                                       observation_count:ObservationCount},
    Outcome = ok(Summary).

%% One pack contributes its observation blueprints, its summary status, and
%% its skip reasons; statuses stay aligned with the pack order.
normalize_all_packs(_, [], _, _, _, _, [], [], []).
normalize_all_packs(Registry,
                    [Pack|Packs],
                    ExtractionRecord,
                    FileRecord,
                    Language,
                    Source,
                    Blueprints,
                    [Status|Statuses],
                    Skipped) :-
    normalize_pack(Registry,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   Source,
                   PackObservations,
                   PackSkipped),
    length(PackObservations, PackCount),
    Status = normalized(PackCount),
    normalize_all_packs(Registry,
                        Packs,
                        ExtractionRecord,
                        FileRecord,
                        Language,
                        Source,
                        RestObservations,
                        Statuses,
                        RestSkipped),
    append(PackObservations, RestObservations, Blueprints),
    append(PackSkipped, RestSkipped, Skipped).

normalize_pack(Registry,
               Pack,
               ExtractionRecord,
               FileRecord,
               Language,
               Source,
               Observations,
               Skipped) :-
    Purpose = Pack.purpose,
    (   rlm_project_semantic_pack:language_analysis_capability(Language,
                                                               Purpose)
    ->  Extraction = ExtractionRecord.extraction,
        findall(Match,
                semantic_match_for_pack(Registry, Extraction, Pack, Match),
                Matches),
        match_blueprints(Matches,
                         Pack,
                         ExtractionRecord,
                         FileRecord,
                         Language,
                         Source,
                         Observations,
                         Skipped)
    ;   Observations = [],
        Skipped = []
    ).

match_blueprints([], _, _, _, _, _, _, []).
match_blueprints([Match|Matches],
                 Pack,
                 ExtractionRecord,
                 FileRecord,
                 Language,
                 Source,
                 Blueprints,
                 Skipped) :-
    match_blueprint(Match,
                    Pack,
                    ExtractionRecord,
                    FileRecord,
                    Language,
                    Source,
                    MatchBlueprints,
                    MatchSkipped),
    match_blueprints(Matches,
                     Pack,
                     ExtractionRecord,
                     FileRecord,
                     Language,
                     Source,
                     RestBlueprints,
                     RestSkipped),
    append(MatchBlueprints, RestBlueprints, Blueprints),
    append(MatchSkipped, RestSkipped, Skipped).

/* One grouped match -> zero or one observation blueprint (or a skip
   reason).  Capture pairing: the first principal capture of a relation
   pairs with the first name/callee/target/alias/keyword detail of the same
   relation inside the match; capture order is the native order kept by
   #97. */
match_blueprint(Match,
                Pack,
                ExtractionRecord,
                FileRecord,
                Language,
                Source,
                Blueprint,
                Skipped) :-
    Purpose = Pack.purpose,
    relation_for_purpose(Purpose, Relation),
    Captures = Match.captures,
    classified_captures(Captures, Relation, principal, Principals),
    classified_captures(Captures, Relation, detail(name), Names),
    classified_captures(Captures, Relation, detail(callee), Callees),
    classified_captures(Captures, Relation, detail(target), Targets),
    classified_captures(Captures, Relation, detail(alias), Aliases),
    classified_captures(Captures, Relation, detail(keyword), Keywords),
    (   Principals == []
    ->  Blueprint = [],
        Skipped = [skipped_reason(no_principal, Purpose)]
    ;   zip_principals(Principals,
                       Names,
                       Keywords,
                       Callees,
                       Targets,
                       Aliases,
                       Relation,
                       Pack,
                       ExtractionRecord,
                       FileRecord,
                       Language,
                       Source,
                       Blueprint,
                       Skipped)
    ).

classified_captures([], _, _, []).
classified_captures([Capture|Captures],
                    Relation,
                    Want,
                    [Capture|Classified]) :-
    capture_class(Capture, Relation, Class),
    class_matches(Want, Class),
    !,
    classified_captures(Captures, Relation, Want, Classified).
classified_captures([_|Captures], Relation, Want, Classified) :-
    classified_captures(Captures, Relation, Want, Classified).

class_matches(principal, principal).
class_matches(principal, principal_kind(_)).
class_matches(detail(Role), detail(Role)).

zip_principals([], _, _, _, _, _, _, _, _, _, _, _, [], []).
zip_principals([Principal|Principals],
               Names,
               Keywords,
               Callees,
               Targets,
               Aliases,
               Relation,
               Pack,
               ExtractionRecord,
               FileRecord,
               Language,
               Source,
               Blueprints,
               Skipped) :-
    optional_capture_text(Names, Source, NameText, Names1),
    optional_capture_text(Keywords, Source, KeywordText, Keywords1),
    optional_capture_text(Callees, Source, CalleeText, Callees1),
    optional_capture_text(Targets, Source, TargetText, Targets1),
    optional_capture_text(Aliases, Source, AliasText, Aliases1),
    relation_blueprint(Relation,
                       Principal,
                       NameText,
                       CalleeText,
                       TargetText,
                       AliasText,
                       KeywordText,
                       Pack,
                       ExtractionRecord,
                       FileRecord,
                       Language,
                       PackBlueprints,
                       PackSkipped),
    zip_principals(Principals,
                   Names1,
                   Keywords1,
                   Callees1,
                   Targets1,
                   Aliases1,
                   Relation,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   Source,
                   RestBlueprints,
                   RestSkipped),
    append(PackBlueprints, RestBlueprints, Blueprints),
    append(PackSkipped, RestSkipped, Skipped).

relation_for_purpose(definitions, definition).
relation_for_purpose(references, reference).
relation_for_purpose(calls, call).
relation_for_purpose(imports, import).
relation_for_purpose(exports, export).

/* Relation blueprints ---------------------------------------------------- */

relation_blueprint(definition,
                   Principal,
                   NameText,
                   _CalleeText,
                   _TargetText,
                   _AliasText,
                   KeywordText,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   [Definition],
                   []) :-
    normalize_name(NameText, Name),
    definition_kind(Principal, KeywordText, Kind),
    observation_provenance(Principal,
                           Pack,
                           ExtractionRecord,
                           FileRecord,
                           Language,
                           Provenance),
    Definition = project_semantic_definition{name:Name,
                                             kind:Kind,
                                             node:Principal.node,
                                             start_byte:Principal.start_byte,
                                             end_byte:Principal.end_byte,
                                             start_point:Principal.start_point,
                                             end_point:Principal.end_point,
                                             extraction:ExtractionRecord.extraction,
                                             provenance:Provenance}.

relation_blueprint(reference,
                   Principal,
                   NameText,
                   _CalleeText,
                   _TargetText,
                   _AliasText,
                   _KeywordText,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   [Reference],
                   []) :-
    normalize_name(NameText, Name),
    observation_provenance(Principal,
                           Pack,
                           ExtractionRecord,
                           FileRecord,
                           Language,
                           Provenance),
    Reference = project_semantic_reference{name:Name,
                                           kind:none,
                                           node:Principal.node,
                                           start_byte:Principal.start_byte,
                                           end_byte:Principal.end_byte,
                                           start_point:Principal.start_point,
                                           end_point:Principal.end_point,
                                           extraction:ExtractionRecord.extraction,
                                           provenance:Provenance}.

relation_blueprint(call,
                   Principal,
                   _NameText,
                   none,
                   _TargetText,
                   _AliasText,
                   _KeywordText,
                   _Pack,
                   _ExtractionRecord,
                   _FileRecord,
                   _Language,
                   [],
                   [skipped_reason(call_without_callee,
                                   Principal.start_byte)]) :- !.

relation_blueprint(call,
                   Principal,
                   _NameText,
                   CalleeText,
                   _TargetText,
                   _AliasText,
                   _KeywordText,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   [Call],
                   []) :-
    normalize_name(CalleeText, Callee),
    observation_provenance(Principal,
                           Pack,
                           ExtractionRecord,
                           FileRecord,
                           Language,
                           Provenance),
    Call = project_semantic_call{callee:Callee,
                                 node:Principal.node,
                                 start_byte:Principal.start_byte,
                                 end_byte:Principal.end_byte,
                                 start_point:Principal.start_point,
                                 end_point:Principal.end_point,
                                 extraction:ExtractionRecord.extraction,
                                 provenance:Provenance}.

relation_blueprint(import,
                   Principal,
                   _NameText,
                   _CalleeText,
                   none,
                   _AliasText,
                   _KeywordText,
                   _Pack,
                   _ExtractionRecord,
                   _FileRecord,
                   _Language,
                   [],
                   [skipped_reason(import_without_target,
                                   Principal.start_byte)]) :- !.

relation_blueprint(import,
                   Principal,
                   _NameText,
                   _CalleeText,
                   TargetText,
                   AliasText,
                   _KeywordText,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   [Import],
                   []) :-
    import_target(TargetText, Target),
    normalize_name(AliasText, Alias),
    observation_provenance(Principal,
                           Pack,
                           ExtractionRecord,
                           FileRecord,
                           Language,
                           Provenance),
    Import = project_semantic_import{target:Target,
                                     alias:Alias,
                                     node:Principal.node,
                                     start_byte:Principal.start_byte,
                                     end_byte:Principal.end_byte,
                                     start_point:Principal.start_point,
                                     end_point:Principal.end_point,
                                     extraction:ExtractionRecord.extraction,
                                     provenance:Provenance}.

relation_blueprint(export,
                   Principal,
                   none,
                   _CalleeText,
                   _TargetText,
                   _AliasText,
                   _KeywordText,
                   _Pack,
                   _ExtractionRecord,
                   _FileRecord,
                   _Language,
                   [],
                   [skipped_reason(export_without_name,
                                   Principal.start_byte)]) :- !.

relation_blueprint(export,
                   Principal,
                   NameText,
                   _CalleeText,
                   _TargetText,
                   _AliasText,
                   _KeywordText,
                   Pack,
                   ExtractionRecord,
                   FileRecord,
                   Language,
                   [Export],
                   []) :-
    normalize_name(NameText, Name),
    observation_provenance(Principal,
                           Pack,
                           ExtractionRecord,
                           FileRecord,
                           Language,
                           Provenance),
    Export = project_semantic_export{name:Name,
                                     node:Principal.node,
                                     start_byte:Principal.start_byte,
                                     end_byte:Principal.end_byte,
                                     start_point:Principal.start_point,
                                     end_point:Principal.end_point,
                                     extraction:ExtractionRecord.extraction,
                                     provenance:Provenance}.

/* Identity assignment ------------------------------------------------------ */

assign_observation_ids([], _, _, _, []).
assign_observation_ids([Blueprint|Blueprints],
                       Extraction,
                       Seq0,
                       Project,
                       [Record|Records]) :-
    Id = semantic_observation(Extraction, Seq0),
    finish_observation(Blueprint, Id, Project, Record),
    Seq1 is Seq0 + 1,
    assign_observation_ids(Blueprints, Extraction, Seq1, Project, Records).

finish_observation(Blueprint, Id, Project, Record) :-
    put_dict(id, Blueprint, Id, Record0),
    (   is_dict(Record0, project_semantic_definition)
    ->  Symbol = project_symbol(Project, Record0.name, Record0.kind, Id),
        put_dict(symbol, Record0, Symbol, Record)
    ;   Record = Record0
    ).

relation_counts([], 0, 0, 0, 0, 0).
relation_counts([Record|Records],
                Definitions,
                References,
                Calls,
                Imports,
                Exports) :-
    relation_counts(Records,
                    Definitions0,
                    References0,
                    Calls0,
                    Imports0,
                    Exports0),
    (   is_dict(Record, project_semantic_definition)
    ->  Definitions is Definitions0 + 1,
        References = References0,
        Calls = Calls0,
        Imports = Imports0,
        Exports = Exports0
    ;   is_dict(Record, project_semantic_reference)
    ->  References is References0 + 1,
        Definitions = Definitions0,
        Calls = Calls0,
        Imports = Imports0,
        Exports = Exports0
    ;   is_dict(Record, project_semantic_call)
    ->  Calls is Calls0 + 1,
        Definitions = Definitions0,
        References = References0,
        Imports = Imports0,
        Exports = Exports0
    ;   is_dict(Record, project_semantic_import)
    ->  Imports is Imports0 + 1,
        Definitions = Definitions0,
        References = References0,
        Calls = Calls0,
        Exports = Exports0
    ;   is_dict(Record, project_semantic_export)
    ->  Exports is Exports0 + 1,
        Definitions = Definitions0,
        References = References0,
        Calls = Calls0,
        Imports = Imports0
    ;   Definitions = Definitions0,
        References = References0,
        Calls = Calls0,
        Imports = Imports0,
        Exports = Exports0
    ).

/* Purpose statuses ---------------------------------------------------------- */

complete_purpose_statuses(Language, SemanticPacks, PackStatuses, Statuses) :-
    rlm_project_semantic_pack:project_semantic_standard_purposes(
        StandardPurposes),
    complete_purpose_statuses_(StandardPurposes,
                               Language,
                               SemanticPacks,
                               PackStatuses,
                               Statuses).

complete_purpose_statuses_([], _, _, _, []).
complete_purpose_statuses_([Purpose|Purposes],
                           Language,
                           SemanticPacks,
                           PackStatuses,
                           [Entry|Entries]) :-
    (   rlm_project_semantic_pack:language_analysis_capability(Language,
                                                               Purpose)
    ->  (   semantic_pack_for(SemanticPacks, Purpose, Pack)
        ->  pack_status(Pack, SemanticPacks, PackStatuses, Status),
            Entry = project_semantic_purpose_status{purpose:Purpose,
                                                    status:Status}
        ;   Entry = project_semantic_purpose_status{purpose:Purpose,
                                                    status:inactive}
        )
    ;   Entry = project_semantic_purpose_status{purpose:Purpose,
                                                status:unsupported}
    ),
    complete_purpose_statuses_(Purposes,
                               Language,
                               SemanticPacks,
                               PackStatuses,
                               Entries).

semantic_pack_for([Pack|_], Purpose, Pack) :-
    Pack.purpose == Purpose,
    !.
semantic_pack_for([_|Packs], Purpose, Pack) :-
    semantic_pack_for(Packs, Purpose, Pack).

pack_status(Pack, [Candidate|_], [Status|_], Status) :-
    Candidate == Pack,
    !.
pack_status(Pack, [_|Candidates], [_|Statuses], Status) :-
    pack_status(Pack, Candidates, Statuses, Status).

/* Publication -------------------------------------------------------------- */

%% Authoritative publication for one file: the extraction must still be the
%% current extraction at publication time; prior observations for the file
%% are retracted, the new observations become the current knowledge, and the
%% direct observation records are journaled in sequence order.  Currentness
%% itself is never journaled: it stays derived from the #97 extraction
%% layer.
publish_semantic(Registry, Id, Project, File, Extraction, Observations) :-
    with_mutex(rlm_project_semantic,
               ( project_source_registry_valid(Registry),
                 require_current_extraction(Registry, Id, File, Extraction),
                 retractall(semantic_observation(Id, File, _, _)),
                 retractall(semantic_current(Id, File, _)),
                 publish_rows(Project, Extraction, Observations, 1, FinalSeq),
                 forall(member(Observation, Observations),
                        assertz(semantic_observation(Id,
                                                     File,
                                                     Extraction,
                                                     Observation))),
                 retractall(semantic_sequence(Id, Extraction, _)),
                 assertz(semantic_sequence(Id, Extraction, FinalSeq)),
                 assertz(semantic_current(Id, File, Extraction))
               )).

publish_rows(_, _, [], Seq, LastSeq) :-
    !,
    LastSeq is Seq - 1.
publish_rows(Project, Extraction, [Record|Records], Seq, LastSeq) :-
    project_semantic_persist_append(Project, Extraction, Seq, Record),
    NextSeq is Seq + 1,
    publish_rows(Project, Extraction, Records, NextSeq, LastSeq).

/* Publication currentness gate ------------------------------------------- */

%% Observation sequence continuation: a re-normalized extraction keeps its
%% journal sequence monotonic so restarted processes cannot reuse an
%% observation identity that is already durable.
semantic_sequence_base(Id, Extraction, Base) :-
    (   semantic_sequence(Id, Extraction, Max)
    ->  Base is Max + 1
    ;   Base = 1
    ).

require_current_extraction(Registry, _Id, File, Extraction) :-
    project_query_current_extraction(Registry, File, Extraction),
    project_query_extraction_record(Registry, Extraction, ExtractionRecord),
    ExtractionRecord.currentness == current,
    !.

require_current_extraction(_Registry, Id, File, _) :-
    (   semantic_current(Id, File, Prior)
    ->  throw(project_semantic_fault(stale_knowledge(Prior)))
    ;   throw(project_semantic_fault(no_current_extraction(File)))
    ).

require_exact_generation(ExtractionRecord, ContentHash) :-
    get_dict(content_hash, ExtractionRecord, RecordHash),
    atom(RecordHash),
    downcase_atom(RecordHash, RecordLower),
    downcase_atom(ContentHash, ContentLower),
    RecordLower == ContentLower,
    !.
require_exact_generation(ExtractionRecord, _) :-
    throw(project_semantic_fault(generation_mismatch(ExtractionRecord.extraction))).

/* Public observation reads ------------------------------------------------ */

project_semantic_definitions(Registry, File, Query, Definition) :-
    semantic_read(Registry, File, project_semantic_definition, Query,
                  Definition).

project_semantic_references(Registry, File, Query, Reference) :-
    semantic_read(Registry, File, project_semantic_reference, Query,
                  Reference).

project_semantic_calls(Registry, File, Query, Call) :-
    semantic_read(Registry, File, project_semantic_call, Query, Call).

project_semantic_imports(Registry, File, Query, Import) :-
    semantic_read(Registry, File, project_semantic_import, Query, Import).

project_semantic_exports(Registry, File, Query, Export) :-
    semantic_read(Registry, File, project_semantic_export, Query, Export).

query_filter(none, _) :- !.
query_filter(Query, Record) :-
    is_dict(Query),
    dict_keys(Query, Keys),
    query_filter_keys(Keys, Query, Record).

query_filter_keys([], _, _) :- !.
query_filter_keys([Key|Keys], Query, Record) :-
    get_dict(Key, Query, Value),
    get_dict(Key, Record, Value),
    query_filter_keys(Keys, Query, Record).

semantic_read(Registry, File, Tag, Query, Record) :-
    registry_id(Registry, Id),
    semantic_read_gate(Registry, File, Extraction),
    semantic_observation(Id, File, Extraction, Record),
    is_dict(Record, Tag),
    query_filter(Query, Record).

%% A read answers only while the extraction it was derived from is the
%% current extraction.  A stale or missing gate simply yields no rows; use
%% project_semantic_knowledge_state/3 to distinguish stale from none.
semantic_read_gate(Registry, File, Extraction) :-
    ensure_semantic_reads(Registry, File),
    registry_id(Registry, Id),
    semantic_current(Id, File, Extraction),
    project_query_current_extraction(Registry, File, Extraction),
    !.

ensure_semantic_reads(Registry, File) :-
    project_source_file(Registry, File, FileRecord),
    project_source_project(Registry, FileRecord.project, ProjectMeta),
    ensure_semantic_persistence(Registry,
                                FileRecord.project,
                                ProjectMeta,
                                none).

project_semantic_knowledge_state(Registry, File, State) :-
    registry_id(Registry, Id),
    (   semantic_current(Id, File, Extraction)
    ->  (   project_query_current_extraction(Registry, File, Extraction)
        ->  State = current
        ;   State = stale(Extraction)
        )
    ;   State = none
    ).

project_semantic_observation_provenance(Registry, Observation, Provenance) :-
    registry_id(Registry, _),
    is_dict(Observation),
    get_dict(provenance, Observation, Provenance),
    !.
project_semantic_observation_provenance(_, Observation, _) :-
    throw(project_semantic_fault(invalid_observation(Observation))).

/* Derived relations -------------------------------------------------------- */

%% Direct span containment among definition observations.  The supporting
%% observations are the two definition identities carried by the returned
%% records themselves.
project_semantic_contains(Registry, File, Parent, Child) :-
    registry_id(Registry, Id),
    semantic_read_gate(Registry, File, Extraction),
    file_definitions(Id, File, Extraction, Definitions),
    member(Child, Definitions),
    immediate_container(Definitions, Child, Parent).

file_definitions(Id, File, Extraction, Definitions) :-
    findall(Definition,
            (   semantic_observation(Id, File, Extraction, Definition),
                is_dict(Definition, project_semantic_definition)
            ),
            Definitions).

immediate_container(Definitions, Child, Parent) :-
    member(Parent, Definitions),
    Parent.id \== Child.id,
    span_contains(Parent, Child),
    \+ (   member(Intermediate, Definitions),
           Intermediate.id \== Parent.id,
           Intermediate.id \== Child.id,
           span_contains(Parent, Intermediate),
           span_contains(Intermediate, Child)
       ).

span_contains(Outer, Inner) :-
    Outer.start_byte =< Inner.start_byte,
    Inner.end_byte =< Outer.end_byte.

%% Bounded, cycle-safe name-level call reachability.  Each path step names
%% the supporting call observation identity.  The caller of a call
%% observation is the innermost definition containing its span; this is a
%% name-level approximation, stated as such.
project_semantic_call_reachable(Registry, File, From0, To0, Outcome) :-
    registry_id(Registry, Id),
    semantic_read_gate(Registry, File, Extraction),
    normalize_name(From0, From),
    normalize_name(To0, To),
    From \== none,
    To \== none,
    call_edges(Id, File, Extraction, Edges),
    reach_depth(Depth),
    (   reach_path(Edges, From, To, [From], Depth, PathSteps)
    ->  Outcome = ok(project_semantic_reach{from:From,
                                            to:To,
                                            path:PathSteps})
    ;   Outcome = ok(unreachable)
    ).

reach_depth(8).

call_edges(Id, File, Extraction, Edges) :-
    file_definitions(Id, File, Extraction, Definitions),
    findall(edge(CallerName, CalleeName, CallId),
            (   semantic_observation(Id, File, Extraction, Call),
                is_dict(Call, project_semantic_call),
                immediate_container(Definitions, Call, Caller),
                CallerName = Caller.name,
                CallerName \== none,
                CalleeName = Call.callee,
                CallId = Call.id
            ),
            EdgeList),
    sort(EdgeList, Edges).

reach_path(Edges, Current, Target, _, _, [Step]) :-
    member(edge(Current, Target, CallId), Edges),
    Step = project_semantic_step{from:Current,
                                 call:CallId,
                                 to:Target}.
reach_path(Edges, Current, Target, Visited, Depth, [Step|Path]) :-
    Depth > 1,
    member(edge(Current, Next, CallId), Edges),
    Next \== Target,
    \+ memberchk(Next, Visited),
    NextDepth is Depth - 1,
    reach_path(Edges, Next, Target, [Next|Visited], NextDepth, Path),
    Step = project_semantic_step{from:Current,
                                 call:CallId,
                                 to:Next}.

%% Derived file dependency: an import observation of FromFile whose target
%% resolves textually onto ToFile's registered path.  The import target text
%% is not a proved module identity; resolution stays explicit.
project_semantic_file_dependencies(Registry, Project, FromFile, ToFile,
                                   Support) :-
    registry_id(Registry, Id),
    project_source_project_file(Registry, Project, FromFile),
    semantic_current(Id, FromFile, Extraction),
    project_query_current_extraction(Registry, FromFile, Extraction),
    semantic_observation(Id, FromFile, Extraction, Import),
    is_dict(Import, project_semantic_import),
    dependency_target(Import.target, DependencyPath),
    project_source_file(Registry, ToFile, ToRecord),
    ToRecord.project == Project,
    text_atom(ToRecord.path, ToPath),
    DependencyPath == ToPath,
    Support = project_semantic_support{observation:Import.id,
                                       target:Import.target}.

/* Resolution ---------------------------------------------------------------- */

%% Explicit bounded resolution over current semantic knowledge.  Extraction
%% and resolution stay separate: nothing here runs a parser or an extractor.
project_semantic_resolve(Registry, Project, Request, Outcome) :-
    catch(project_semantic_resolve_(Registry, Project, Request, Outcome),
          Exception,
          project_semantic_exception(resolve, Exception, Outcome)).

project_semantic_resolve_(Registry, Project, Request, Outcome) :-
    registry_id(Registry, Id),
    project_source_project(Registry, Project, _),
    resolve_request(Registry, Id, Project, Request, Outcome).

resolve_request(Registry, Id, Project, Request, Outcome) :-
    (   is_dict(Request)
    ->  resolve_definitions(Registry, Id, Project, Request, Outcome)
    ;   Request = reference(Rec)
    ->  is_dict(Rec),
        dict_create(Ref, symbol_ref, [name-Rec.name]),
        resolve_definitions(Registry, Id, Project, Ref, Outcome)
    ;   Request = symbol_ref(Ref)
    ->  resolve_definitions(Registry, Id, Project, Ref, Outcome)
    ;   Request = import(Rec)
    ->  resolve_import(Registry, Id, Project, Rec, Outcome)
    ;   throw(project_semantic_fault(invalid_resolution_request(Request)))
    ).

resolve_definitions(Registry, Id, Project, Ref, Outcome) :-
    require_project_knowledge(Registry, Id, Project),
    get_dict(name, Ref, Name),
    atom(Name),
    Name \== '',
    (   get_dict(kind, Ref, Kind)
    ->  true
    ;   Kind = none
    ),
    findall(Symbol,
            (   project_source_project_file(Registry, Project, File),
                semantic_current(Id, File, Extraction),
                project_query_current_extraction(Registry, File, Extraction),
                semantic_observation(Id, File, Extraction, Definition),
                is_dict(Definition, project_semantic_definition),
                Definition.name == Name,
                (   Kind == none
                ->  true
                ;   Definition.kind == Kind
                ),
                Symbol = Definition.symbol
            ),
            Symbols0),
    sort(Symbols0, Symbols),
    (   Symbols == []
    ->  Outcome = ok(unresolved)
    ;   Symbols = [Symbol]
    ->  Outcome = ok(resolved(Symbol))
    ;   Outcome = ok(ambiguous(Symbols))
    ).

resolve_import(Registry, Id, Project, Import, Outcome) :-
    require_project_knowledge(Registry, Id, Project),
    dependency_target(Import.target, DependencyPath),
    findall(File,
            (   project_source_project_file(Registry, Project, File),
                project_source_file(Registry, File, FileRecord),
                text_atom(FileRecord.path, FilePath),
                DependencyPath == FilePath
            ),
            Files0),
    sort(Files0, Files),
    (   Files == []
    ->  Outcome = ok(external)
    ;   Files = [File]
    ->  Outcome = ok(resolved(file(File)))
    ;   Outcome = ok(ambiguous(Files))
    ).

require_project_knowledge(Registry, Id, Project) :-
    (   semantic_current_for_project(Registry, Id, Project, _)
    ->  true
    ;   throw(project_semantic_fault(stale_knowledge(project(Project))))
    ).

semantic_current_for_project(Registry, Id, Project, File) :-
    semantic_current(Id, File, _),
    project_source_file(Registry, File, FileRecord),
    FileRecord.project == Project.

/* Symbol index -------------------------------------------------------------- */

%% #288-compatible index over the project's current semantic knowledge.
%% Definitions come only from extractions that are still current; files
%% whose semantic knowledge went stale are reported through coherence
%% instead of silently contributing stale spans.
project_semantic_symbol_index(Registry, Project, Outcome) :-
    catch(project_semantic_symbol_index_(Registry, Project, Outcome),
          Exception,
          project_semantic_exception(symbol_index, Exception, Outcome)).

project_semantic_symbol_index_(Registry, Project, Outcome) :-
    registry_id(Registry, Id),
    project_source_project(Registry, Project, _),
    findall(File,
            project_source_project_file(Registry, Project, File),
            Files0),
    sort(Files0, Files),
    index_stale_files(Registry, Id, Files, Stale),
    findall(symbol_definition(Ref, Span, Provenance),
            (   member(File, Files),
                index_file_definition(Registry, Id, File, Ref, Span,
                                      Provenance)
            ),
            Definitions),
    findall(Kind, symbol_kind(Kind), Kinds0),
    sort(Kinds0, Kinds),
    (   Stale == []
    ->  Coherence = complete
    ;   Coherence = partial(Stale)
    ),
    Index = symbol_index{project:Project,
                         kinds:Kinds,
                         definitions:Definitions,
                         coherence:Coherence},
    Outcome = ok(Index).

index_stale_files(Registry, Id, Files, Stale) :-
    findall(File,
            (   member(File, Files),
                semantic_current(Id, File, Extraction),
                \+ project_query_current_extraction(Registry, File, Extraction)
            ),
            Stale0),
    sort(Stale0, Stale).

index_file_definition(Registry, Id, File, Ref, Span, Provenance) :-
    semantic_current(Id, File, Extraction),
    project_query_current_extraction(Registry, File, Extraction),
    semantic_observation(Id, File, Extraction, Definition),
    is_dict(Definition, project_semantic_definition),
    project_source_file(Registry, File, FileRecord),
    text_atom(FileRecord.path, FilePath),
    Ref = symbol_ref{name:Definition.name,
                     kind:Definition.kind,
                     occurrence:definition},
    Span = source_span{file:FilePath,
                       start_byte:Definition.start_byte,
                       end_byte:Definition.end_byte},
    Provenance = Definition.provenance.

/* Persistence --------------------------------------------------------------- */

ensure_semantic_persistence(Registry, Project, ProjectMeta, OptionRoot) :-
    registry_id(Registry, Id),
    (   semantic_persistence(Id, Project, _)
    ->  true
    ;   semantic_kb_file(Project, ProjectMeta, OptionRoot, Path),
        project_semantic_persist_open(Path, ok(_)),
        with_mutex(rlm_project_semantic,
                   (   retractall(semantic_persistence(Id, _, _)),
                       assertz(semantic_persistence(Id, Project, Path)),
                       hydrate_semantic(Registry, Id, Project)
                   ))
    ).

semantic_kb_file(Project, ProjectMeta, OptionRoot, Path) :-
    (   OptionRoot \== none
    ->  Root = OptionRoot
    ;   get_dict(project_root, ProjectMeta, Root)
    ->  true
    ;   throw(project_semantic_fault(kb_unwritable(no_project_root)))
    ),
    normalize_path_atom(Root, RootAtom),
    (   is_absolute_file_name(RootAtom),
        exists_directory(RootAtom),
        access_file(RootAtom, write)
    ->  directory_file_path(RootAtom, '.kb', KBRoot),
        directory_file_path(KBRoot, 'project-semantic', SemanticRoot),
        catch(make_directory_path(SemanticRoot), _, fail),
        access_file(SemanticRoot, write),
        project_filename(Project, FileName),
        directory_file_path(SemanticRoot, FileName, Path)
    ;   throw(project_semantic_fault(kb_unwritable(RootAtom)))
    ).

project_filename(Project, FileName) :-
    with_output_to(string(Text), write_canonical(Project)),
    crypto_data_hash(Text,
                     Hash,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('project-', Hash, Prefix),
    atom_concat(Prefix, '.pl', FileName).

hydrate_semantic(Registry, Id, Project) :-
    project_semantic_persist_snapshot(Project, Rows),
    hydrate_rows(Id, Rows),
    hydrate_current(Registry, Id, Project).

hydrate_rows(_, []).
hydrate_rows(Id, [Extraction-Seq-Record|Rows]) :-
    Extraction = query_extraction(File, _),
    (   semantic_observation(Id, File, Extraction, Record)
    ->  true
    ;   assertz(semantic_observation(Id, File, Extraction, Record))
    ),
    (   semantic_sequence(Id, Extraction, Max),
        Max >= Seq
    ->  true
    ;   retractall(semantic_sequence(Id, Extraction, _)),
        assertz(semantic_sequence(Id, Extraction, Seq))
    ),
    hydrate_rows(Id, Rows).

%% Journal rows for superseded extractions stay historical: only an
%% extraction that the query layer still holds current re-establishes
%% semantic currentness after a restart, so stale knowledge can never be
%% resurrected as current.
hydrate_current(Registry, Id, Project) :-
    findall(File-Extraction,
            (   semantic_observation(Id, File, Extraction, _),
                project_source_file(Registry, File, FileRecord),
                FileRecord.project == Project
            ),
            FileRows0),
    sort(FileRows0, FileRows),
    forall(member(File-Extraction, FileRows),
           (   project_query_current_extraction(Registry, File, Current),
               Current == Extraction
           ->  (   semantic_current(Id, File, Extraction)
               ->  true
               ;   assertz(semantic_current(Id, File, Extraction))
               )
           ;   true
           )).

project_semantic_registry_clear(Registry) :-
    (   Registry = project_source_registry(Id)
    ->  true
    ;   fail
    ),
    with_mutex(rlm_project_semantic,
               (   retractall(semantic_observation(Id, _, _, _)),
                   retractall(semantic_current(Id, _, _)),
                   retractall(semantic_sequence(Id, _, _)),
                   (   semantic_persistence(Id, _, _)
                   ->  retractall(semantic_persistence(Id, _, _)),
                       project_semantic_persist_close
                   ;   true
                   )
               )).

/* Helpers ------------------------------------------------------------------- */

semantic_packs(Registry, Language, Packs) :-
    rlm_project_semantic_pack:project_semantic_standard_purposes(StandardPurposes),
    findall(Pack,
            (   project_query_active_packs(Registry, Language, Pack),
                memberchk(Pack.purpose, StandardPurposes)
            ),
            Packs0),
    sort(Packs0, Packs).

semantic_match_for_pack(Registry, Extraction, Pack, Match) :-
    project_query_matches(Registry, Extraction, Match),
    Match.pack_identity == Pack.identity,
    Match.captures = [FirstCapture|_],
    FirstCapture.pack_sha256 == Pack.sha256.

capture_class(Capture, Relation, Class) :-
    capture_name_parts(Capture, Parts),
    capture_class_parts(Parts, Relation, Class).

capture_name_parts(Capture, Parts) :-
    Name = Capture.name,
    atom_string(Name, NameString),
    split_string(NameString, ".", "", Parts).

capture_class_parts([Only], Relation, principal) :-
    atom_string(Relation, Only),
    !.
capture_class_parts([First, Second], Relation, Class) :-
    atom_string(Relation, First),
    !,
    (   member(Role, ["name", "callee", "target", "alias", "keyword"]),
        Role == Second
    ->  atom_string(RoleAtom, Second),
        Class = detail(RoleAtom)
    ;   atom_string(Kind, Second),
        symbol_kind(Kind)
    ->  Class = principal_kind(Kind)
    ;   Class = not_this_relation
    ).
capture_class_parts(_, _, not_this_relation).

optional_capture_text([], _, none, []).
optional_capture_text([Capture|Captures], Source, Text, Rest) :- !,
    capture_text(Capture, Source, Text),
    Rest = Captures.

capture_text(Capture, Source, Text) :-
    StartByte = Capture.start_byte,
    EndByte = Capture.end_byte,
    Length is EndByte - StartByte,
    (   Length >= 0
    ->  true
    ;   throw(project_semantic_fault(invalid_capture_span(StartByte, EndByte)))
    ),
    string_codes(Source, SourceCodes),
    phrase(utf8_codes(SourceCodes), SourceBytes),
    byte_slice(SourceBytes, StartByte, Length, Slice),
    phrase(utf8_codes(TextCodes), Slice),
    string_codes(Text, TextCodes).

byte_slice(Bytes, 0, Length, Slice) :- !,
    length(Slice, Length),
    append(Slice, _, Bytes).
byte_slice([_|Bytes], Index, Length, Slice) :-
    Index > 0,
    Index1 is Index - 1,
    byte_slice(Bytes, Index1, Length, Slice).

%% string -> atom conversion; the documented direction with the atom slot
%% unbound and the string slot bound.
text_atom(Text, Atom) :-
    string(Text),
    !,
    atom_string(Atom, Text).
text_atom(Text, Text) :-
    atom(Text).

import_target(Text, Target) :-
    Text \== none,
    text_atom(Text, TextAtom),
    strip_quotes(TextAtom, Unquoted),
    normalize_name(Unquoted, Target),
    Target \== none.

dependency_target(Text, DependencyPath) :-
    Text \== none,
    text_atom(Text, TextAtom),
    strip_quotes(TextAtom, Unquoted),
    (   atom_concat('./', Rest, Unquoted)
    ->  DependencyPath = Rest
    ;   DependencyPath = Unquoted
    ).

strip_quotes(Text, Unquoted) :-
    atom(Text),
    atom_length(Text, Length),
    Length >= 2,
    sub_atom(Text, 0, 1, _, First),
    sub_atom(Text, _, 1, 0, Last),
    First == Last,
    quote_char(First),
    !,
    Inner is Length - 2,
    sub_atom(Text, 1, Inner, _, Unquoted).
strip_quotes(Text, Text).

quote_char('\'').
quote_char('"').

normalize_name(none, none) :- !.
normalize_name(Text, Name) :-
    text_atom(Text, TextAtom),
    (   TextAtom == ''
    ->  Name = none
    ;   Name = TextAtom
    ).

definition_kind(Principal, _KeywordText, Kind) :-
    capture_class(Principal, definition, principal_kind(Kind)),
    !.
definition_kind(Principal, KeywordText, Kind) :-
    capture_class(Principal, definition, principal),
    KeywordText \== none,
    atom_string(KeywordAtom, KeywordText),
    keyword_kind(KeywordAtom, Kind),
    !.
definition_kind(Principal, _KeywordText, _) :-
    throw(project_semantic_fault(invalid_pack_shape(missing_definition_kind,
                                                    Principal.start_byte))).


keyword_kind('defun', function).
keyword_kind('defgeneric', function).
keyword_kind('defmethod', method).
keyword_kind('defmacro', macro).
keyword_kind('defclass', class).
keyword_kind('define-condition', class).
keyword_kind('defstruct', type).
keyword_kind('deftype', type).
keyword_kind('defpackage', module).
keyword_kind('defparameter', property).
keyword_kind('defvar', property).
keyword_kind('defconstant', property).

normalize_source_text(Source, Source) :-
    string(Source),
    !.
normalize_source_text(Source, Text) :-
    atom(Source),
    !,
    atom_string(Source, Text).
normalize_source_text(Source, _) :-
    throw(project_semantic_fault(type_error(semantic_source, Source))).

normalize_options(Options0, Options) :-
    (   is_list(Options0)
    ->  true
    ;   throw(project_semantic_fault(invalid_options(Options0)))
    ),
    (   ground(Options0), acyclic_term(Options0)
    ->  true
    ;   throw(project_semantic_fault(non_ground_options))
    ),
    allowed_options(Options0,
                    [max_observations-1, kb_root-1]),
    option(max_observations(MaxObservations), Options0, 20000),
    option(kb_root(KBRoot0), Options0, none),
    require_positive(max_observations, MaxObservations),
    normalize_optional_path(KBRoot0, KBRoot),
    Options = semantic_options{kb_root:KBRoot,
                               max_observations:MaxObservations}.

allowed_options([], _).
allowed_options([Option|Options], Names) :-
    compound(Option),
    functor(Option, Name, Arity),
    memberchk(Name-Arity, Names),
    !,
    allowed_options(Options, Names).
allowed_options([Option|_], _) :-
    throw(project_semantic_fault(invalid_option(Option))).

require_positive(_Name, Value) :-
    integer(Value),
    Value > 0,
    !.
require_positive(Name, Value) :-
    throw(project_semantic_fault(invalid_positive(Name, Value))).

require_known_language(Resolution) :-
    memberchk(Resolution.status, [known, explicit_override]),
    Resolution.language \== unknown,
    !.
require_known_language(Resolution) :-
    throw(project_semantic_fault(language_unresolved(Resolution))).

validate_registered_hash(unknown, _) :- !.
validate_registered_hash(Hash0, ContentHash) :-
    (   atom(Hash0)
    ->  Hash = Hash0
    ;   string(Hash0)
    ->  atom_string(Hash, Hash0)
    ;   throw(project_semantic_fault(invalid_file_hash(Hash0)))
    ),
    (   atom_concat('sha256:', Expected0, Hash)
    ->  Expected = Expected0
    ;   Expected = Hash
    ),
    downcase_atom(Expected, ExpectedLower),
    downcase_atom(ContentHash, ContentLower),
    (   ExpectedLower == ContentLower
    ->  true
    ;   throw(project_semantic_fault(source_hash_mismatch(Hash0, ContentHash)))
    ).

normalize_optional_path(none, none) :- !.
normalize_optional_path(Value0, Value) :-
    normalize_path_atom(Value0, Value).

normalize_path_atom(Value, Path) :-
    (   atom(Value) -> Path = Value
    ;   string(Value) -> atom_string(Path, Value)
    ),
    !.
normalize_path_atom(Value, _) :-
    throw(project_semantic_fault(invalid_path(Value))).

registry_id(Registry, Id) :-
    Registry = project_source_registry(Id),
    project_source_registry_valid(Registry),
    !.
registry_id(Registry, _) :-
    throw(project_semantic_fault(invalid_registry(Registry))).

observation_provenance(Principal,
                       Pack,
                       ExtractionRecord,
                       FileRecord,
                       Language,
                       Provenance) :-
    semantic_adapter_identity(Language, Extractor),
    Provenance = project_semantic_provenance{
        project:FileRecord.project,
        file:FileRecord.identity,
        file_hash:ExtractionRecord.file_hash,
        file_generation:ExtractionRecord.file_generation,
        content_hash:ExtractionRecord.content_hash,
        parse:ExtractionRecord.parse,
        parse_generation:ExtractionRecord.parse_generation,
        language:Language,
        backend:ExtractionRecord.backend,
        grammar_ref:ExtractionRecord.grammar_ref,
        pack_identity:Pack.identity,
        pack_sha256:Pack.sha256,
        pack_purpose:Pack.purpose,
        extractor:Extractor,
        node:Principal.node,
        start_byte:Principal.start_byte,
        end_byte:Principal.end_byte,
        start_point:Principal.start_point,
        end_point:Principal.end_point,
        extraction:ExtractionRecord.extraction
    }.

semantic_adapter_identity(Language, semantic_adapter(Language, Version)) :-
    semantic_adapter_version(Version).

project_semantic_exception(Operation,
                           project_semantic_fault(Fault),
                           error(Error)) :-
    !,
    fault_kind(Fault, Kind),
    Error = project_semantic_error{kind:Kind,
                                   operation:Operation,
                                   detail:Fault,
                                   message:"project semantic operation failed"}.
project_semantic_exception(Operation, Exception, error(Error)) :-
    Error = project_semantic_error{kind:project_semantic_exception,
                                   operation:Operation,
                                   exception:Exception,
                                   message:"project semantic operation raised an exception"}.

fault_kind(Fault, Kind) :-
    compound(Fault),
    !,
    functor(Fault, Kind, _).
fault_kind(Fault, Fault).
