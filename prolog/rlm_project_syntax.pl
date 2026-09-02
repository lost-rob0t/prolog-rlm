:- module(rlm_project_syntax,
          [ rlm_project_syntax_ready/0,
            project_syntax_materialize/5,
            project_syntax_materialize_async/5,
            project_syntax_materialize_execute/5,
            project_syntax_current_parse/3,
            project_syntax_parse_record/3,
            project_syntax_node/4,
            project_syntax_named/2,
            project_syntax_parent/3,
            project_syntax_child/4,
            project_syntax_field/4,
            project_syntax_span/3,
            project_syntax_points/4,
            project_syntax_error/3,
            project_syntax_node_provenance/3,
            project_syntax_node_text/4,
            project_syntax_registry_clear/1
          ]).

/** <module> Versioned generic Project syntax observations

This module materializes bounded Tree-sitter CST projections as ordinary
closed Prolog data.  Native trees are temporary: node and parse identities do
not contain pointers, and all queryable observations remain valid after the
native tree is closed.

The facts are epistemic project state.  Parsing does not consult source,
activate grammars, grant capabilities, or confer execution authority.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(time)).
:- use_module(library(utf8)).
:- use_module(rlm_async).
:- use_module(rlm_project_source).

:- dynamic syntax_generation_counter/3.
:- dynamic syntax_latest_admission/4.
:- dynamic syntax_current_parse/3.
:- dynamic syntax_parse_fact/5.
:- dynamic syntax_node_fact/3.

rlm_project_syntax_ready :-
    rlm_project_source_ready.

project_syntax_materialize(Registry, File, Source0, Options0, Outcome) :-
    project_syntax_materialize_async(Registry,
                                     File,
                                     Source0,
                                     Options0,
                                     Future),
    setup_call_cleanup(true,
                       rlm_future_await(Future, Outcome),
                       rlm_future_destroy(Future)).

project_syntax_materialize_async(Registry,
                                 File,
                                 Source0,
                                 Options0,
                                 Future) :-
    rlm_async_submit(
        rlm_project_syntax:project_syntax_materialize_execute(Registry,
                                                              File,
                                                              Source0,
                                                              Options0),
        Future).

project_syntax_materialize_execute(Registry,
                                   File,
                                   Source0,
                                   Options0,
                                   Outcome) :-
    catch(project_syntax_materialize_(Registry,
                                      File,
                                      Source0,
                                      Options0,
                                      Outcome),
          Exception,
          project_syntax_exception(materialize, Exception, Outcome)).

project_syntax_materialize_(Registry, File, Source0, Options0, Outcome) :-
    normalize_source(Source0, Source),
    materialize_options(Options0, Options),
    call_with_time_limit(Options.timeout_seconds,
                         project_syntax_materialize_prepared(Registry,
                                                             File,
                                                             Source,
                                                             Options,
                                                             Outcome)).

project_syntax_materialize_prepared(Registry,
                                    File,
                                    Source,
                                    Options,
                                    Outcome) :-
    project_source_file(Registry, File, FileRecord),
    reserve_parse_admission(Registry, File, Generation),
    catch(source_bytes_bounded(Source,
                               Options.max_source_bytes,
                               Bytes,
                               _),
          project_syntax_blocked(source_limit(BytesSeen, Limit)),
          handle_source_limit(Registry,
                              File,
                              FileRecord.hash,
                              Generation,
                              Source,
                              BytesSeen,
                              Limit)),
    crypto_data_hash(Source,
                     ContentHash,
                     [algorithm(sha256), encoding(utf8)]),
    validate_admitted_hash(Registry,
                           File,
                           Generation,
                           FileRecord.hash,
                           ContentHash),
    complete_parse_admission(Registry, File, Generation, ContentHash),
    enforce_file_policy(FileRecord, Options),
    project_source_tree_parse(Registry,
                              File,
                              Source,
                              Tree,
                              ParseOutcome),
    materialize_parse_outcome(ParseOutcome,
                              Registry,
                              File,
                              Source,
                              Bytes,
                              ContentHash,
                              Generation,
                              Tree,
                              Options,
                              Outcome).

materialize_parse_outcome(error(Error), _, _, _, _, _, _, _, _, error(Error)) :- !.
materialize_parse_outcome(ok(SourceProvenance),
                          Registry,
                          File,
                          Source,
                          Bytes,
                          ContentHash,
                          Generation,
                          Tree,
                          Options,
                          Outcome) :-
    setup_call_cleanup(
        true,
        materialize_tree(Registry,
                         File,
                         Source,
                         Bytes,
                         ContentHash,
                         Generation,
                         Tree,
                         SourceProvenance,
                         Options,
                         Outcome),
        rlm_tree_sitter:ts_tree_close(Tree, _)
    ).

materialize_tree(Registry,
                 File,
                 Source,
                 Bytes,
                 ContentHash,
                 Generation,
                 Tree,
                 SourceProvenance,
                 Options,
                 Outcome) :-
    Parse = syntax_parse(File, Generation),
    rlm_tree_sitter:ts_tree_root(Tree, Root),
    tree_status(Root, TreeStatus),
    Initial = projection_state{count:0,
                               records:[],
                               status:complete,
                               reason:none},
    project_node(Root,
                 Parse,
                 [],
                 none,
                 none,
                 none,
                 0,
                 Options,
                 Initial,
                 Projected),
    reverse(Projected.records, NodeRecords),
    projection_status(Projected, Status, Reason),
    length(Bytes, SourceBytes),
    ParseRecord = project_syntax_parse{
                      parse:Parse,
                      project:SourceProvenance.project,
                      file:File,
                      language:SourceProvenance.language,
                      backend:SourceProvenance.backend,
                      grammar_ref:SourceProvenance.grammar_ref,
                      file_hash:SourceProvenance.file_hash,
                      file_generation:SourceProvenance.file_generation,
                      content_hash:ContentHash,
                      source_bytes:SourceBytes,
                      generation:Generation,
                      projection_mode:Options.mode,
                      status:Status,
                      reason:Reason,
                      tree_status:TreeStatus,
                      node_count:Projected.count,
                      currentness:current,
                      provenance:SourceProvenance.selection_provenance
                  },
    publish_parse(Registry, File, Parse, ParseRecord, Source, NodeRecords),
    Summary = project_syntax_summary{
                  parse:Parse,
                  status:Status,
                  reason:Reason,
                  tree_status:TreeStatus,
                  node_count:Projected.count,
                  content_hash:ContentHash
              },
    materialize_outcome(Status, Summary, Outcome).

materialize_outcome(complete, Summary, ok(Summary)).
materialize_outcome(partial, Summary, partial(Summary)).

reserve_parse_admission(Registry, File, Generation) :-
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_syntax,
                            transaction(reserve_parse_admission_locked(
                                            Registry, File, Generation)))
               )).

reserve_parse_admission_locked(Registry, File, Generation) :-
    (   retract(syntax_generation_counter(Registry, File, Previous))
    ->  Generation is Previous + 1
    ;   Generation = 1
    ),
    assertz(syntax_generation_counter(Registry, File, Generation)),
    retractall(syntax_latest_admission(Registry, File, _, _)),
    assertz(syntax_latest_admission(Registry,
                                    File,
                                    Generation,
                                    pending)),
    mark_current_pending(Registry, File, Generation).

mark_current_pending(Registry, File, Generation) :-
    syntax_current_parse(Registry, File, Parse),
    retract(syntax_parse_fact(Registry, File, Parse, Record0, Source)),
    !,
    Record = Record0.put(currentness, indeterminate(pending(Generation))),
    assertz(syntax_parse_fact(Registry, File, Parse, Record, Source)).
mark_current_pending(_, _, _).

complete_parse_admission(Registry, File, Generation, ContentHash) :-
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_syntax,
                            transaction(complete_parse_admission_locked(
                                            Registry,
                                            File,
                                            Generation,
                                            ContentHash)))
               )).

complete_parse_admission_locked(Registry, File, Generation, ContentHash) :-
    retract(syntax_latest_admission(Registry, File, Generation, pending)),
    !,
    assertz(syntax_latest_admission(Registry,
                                    File,
                                    Generation,
                                    ContentHash)),
    resolve_current_after_admission(Registry,
                                    File,
                                    Generation,
                                    ContentHash).
complete_parse_admission_locked(_, _, _, _).

resolve_current_after_admission(Registry, File, Generation, ContentHash) :-
    syntax_current_parse(Registry, File, Parse),
    syntax_parse_fact(Registry, File, Parse, Existing, _),
    Existing.currentness == indeterminate(pending(Generation)),
    retract(syntax_parse_fact(Registry, File, Parse, Record0, Source)),
    !,
    (   Record0.content_hash == ContentHash
    ->  Record = Record0.put(currentness, current),
        assertz(syntax_parse_fact(Registry, File, Parse, Record, Source))
    ;   retract(syntax_current_parse(Registry, File, Parse)),
        Record = Record0.put(currentness, stale),
        assertz(syntax_parse_fact(Registry, File, Parse, Record, Source))
    ).
resolve_current_after_admission(_, _, _, _).

validate_admitted_hash(Registry,
                       File,
                       Generation,
                       FileHash,
                       ContentHash) :-
    catch(validate_registered_hash(FileHash, ContentHash),
          project_syntax_fault(Reason),
          ( reject_parse_admission(Registry, File, Generation, Reason),
            throw(project_syntax_fault(Reason))
          )).

reject_parse_admission(Registry, File, Generation, Reason) :-
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_syntax,
                            transaction(reject_parse_admission_locked(
                                            Registry,
                                            File,
                                            Generation,
                                            Reason)))
               )).

reject_parse_admission_locked(Registry, File, Generation, Reason) :-
    retract(syntax_latest_admission(Registry, File, Generation, pending)),
    !,
    assertz(syntax_latest_admission(Registry,
                                    File,
                                    Generation,
                                    rejected(Reason))),
    restore_pending_current(Registry, File, Generation).
reject_parse_admission_locked(_, _, _, _).

restore_pending_current(Registry, File, Generation) :-
    syntax_current_parse(Registry, File, Parse),
    retract(syntax_parse_fact(Registry, File, Parse, Record0, Source)),
    Record0.currentness = indeterminate(pending(Generation)),
    !,
    Record = Record0.put(currentness, current),
    assertz(syntax_parse_fact(Registry, File, Parse, Record, Source)).
restore_pending_current(_, _, _).

handle_source_limit(Registry,
                    File,
                    _,
                    Generation,
                    _,
                    BytesSeen,
                    Limit) :-
    complete_parse_admission(Registry,
                             File,
                             Generation,
                             blocked_source(Generation)),
    throw(project_syntax_blocked(source_limit(BytesSeen, Limit))).

project_node(_, _, _, _, _, _, _, _, State, State) :-
    State.status == partial,
    !.
project_node(_, _, _, _, _, _, Depth, Options, State0, State) :-
    Depth > Options.max_depth,
    !,
    State = State0.put(_{status:partial,
                         reason:limit(max_depth, Options.max_depth)}).
project_node(Native,
             Parse,
             Path,
             Parent,
             ChildIndex,
             Field,
             Depth,
             Options,
             State0,
             State) :-
    (   State0.count >= Options.max_nodes
    ->  State = State0.put(_{status:partial,
                             reason:limit(max_nodes, Options.max_nodes)})
    ;   node_record(Native,
                    Parse,
                    Path,
                    Parent,
                    ChildIndex,
                    Field,
                    Record),
        Count is State0.count + 1,
        State1 = State0.put(_{count:Count,
                              records:[Record|State0.records]}),
        Node = Record.node,
        ChildDepth is Depth + 1,
        project_children(0,
                         Native,
                         Parse,
                         Path,
                         Node,
                         ChildDepth,
                         Options,
                         State1,
                         State)
    ).

project_children(_,
                 _,
                 _,
                 _,
                 _,
                 _,
                 _,
                 State0,
                 State) :-
    State0.status == partial,
    !,
    State = State0.
project_children(Index,
                 Native,
                 Parse,
                 Path,
                 Parent,
                 Depth,
                 Options,
                 State0,
                 State) :-
    projection_child_count(Options.mode, Native, Count),
    (   Index >= Count
    ->  State = State0
    ;   projection_child(Options.mode, Native, Index, Child),
        projection_child_field(Options.mode, Native, Index, Field),
        append(Path, [Index], ChildPath),
        project_node(Child,
                     Parse,
                     ChildPath,
                     Parent,
                     Index,
                     Field,
                     Depth,
                     Options,
                     State0,
                     State1),
        Next is Index + 1,
        project_children(Next,
                         Native,
                         Parse,
                         Path,
                         Parent,
                         Depth,
                         Options,
                         State1,
                         State)
    ).

projection_child_count(all, Node, Count) :-
    rlm_tree_sitter:ts_node_child_count(Node, Count).
projection_child_count(named, Node, Count) :-
    rlm_tree_sitter:ts_node_named_child_count(Node, Count).

projection_child(all, Node, Index, Child) :-
    rlm_tree_sitter:ts_node_child(Node, Index, Child).
projection_child(named, Node, Index, Child) :-
    rlm_tree_sitter:ts_node_named_child(Node, Index, Child).

projection_child_field(all, Node, Index, Field) :-
    (   rlm_tree_sitter:ts_node_child_field_name(Node, Index, Existing)
    ->  Field = Existing
    ;   Field = none
    ).
projection_child_field(named, Node, Index, Field) :-
    (   rlm_tree_sitter:ts_node_named_child_field_name(Node, Index, Existing)
    ->  Field = Existing
    ;   Field = none
    ).

node_record(Native,
            Parse,
            Path,
            Parent,
            ChildIndex,
            Field,
            Record) :-
    Node = syntax_node(Parse, Path),
    rlm_tree_sitter:ts_node_type(Native, Type),
    truth_value(rlm_tree_sitter:ts_node_named(Native), Named),
    rlm_tree_sitter:ts_node_start_byte(Native, StartByte),
    rlm_tree_sitter:ts_node_end_byte(Native, EndByte),
    rlm_tree_sitter:ts_node_start_point(Native, StartPoint),
    rlm_tree_sitter:ts_node_end_point(Native, EndPoint),
    node_error_kinds(Native, Errors),
    Record = project_syntax_node{
                 node:Node,
                 parse:Parse,
                 type:Type,
                 named:Named,
                 parent:Parent,
                 child_index:ChildIndex,
                 field:Field,
                 start_byte:StartByte,
                 end_byte:EndByte,
                 start_point:StartPoint,
                 end_point:EndPoint,
                 errors:Errors
             }.

truth_value(Goal, true) :- call(Goal), !.
truth_value(_, false).

node_error_kinds(Node, Errors) :-
    findall(Kind, node_error_kind(Node, Kind), Errors).

node_error_kind(Node, missing) :-
    rlm_tree_sitter:ts_node_is_missing(Node).
node_error_kind(Node, error) :-
    rlm_tree_sitter:ts_node_is_error(Node).
node_error_kind(Node, contains_error) :-
    rlm_tree_sitter:ts_node_has_error(Node),
    \+ rlm_tree_sitter:ts_node_is_error(Node).

tree_status(Root, recovered_with_errors) :-
    rlm_tree_sitter:ts_node_has_error(Root),
    !.
tree_status(_, parsed).

projection_status(State, partial, State.reason) :-
    State.status == partial,
    !.
projection_status(_, complete, none).

publish_parse(Registry, File, Parse, Record, Source, Nodes) :-
    with_mutex(rlm_project_source_registry,
               ( project_source_registry_valid(Registry),
                 with_mutex(rlm_project_syntax,
                            transaction(publish_parse_transaction(Registry,
                                                                  File,
                                                                  Parse,
                                                                  Record,
                                                                  Source,
                                                                  Nodes)))
               )).

publish_parse_transaction(Registry, File, Parse, Record, Source, Nodes) :-
    (   \+ syntax_latest_admission(Registry,
                                   File,
                                   Record.generation,
                                   Record.content_hash)
    ->  PublishedRecord = Record.put(currentness, stale)
    ;   (   retract(syntax_current_parse(Registry, File, Previous))
        ->  mark_parse_stale(Registry, Previous)
        ;   true
        ),
        PublishedRecord = Record,
        assertz(syntax_current_parse(Registry, File, Parse))
    ),
    assertz(syntax_parse_fact(Registry,
                              File,
                              Parse,
                              PublishedRecord,
                              Source)),
    forall(member(Node, Nodes),
           assertz(syntax_node_fact(Registry, Node.node, Node))).

mark_parse_stale(Registry, Parse) :-
    retract(syntax_parse_fact(Registry, File, Parse, Record0, Source)),
    !,
    Record = Record0.put(currentness, stale),
    assertz(syntax_parse_fact(Registry, File, Parse, Record, Source)).
mark_parse_stale(_, _).

project_syntax_current_parse(Registry, File, Parse) :-
    syntax_registry_valid(Registry),
    syntax_current_parse(Registry, File, Parse),
    syntax_parse_fact(Registry, File, Parse, Record, _),
    Record.currentness == current.

project_syntax_parse_record(Registry, Parse, Record) :-
    syntax_registry_valid(Registry),
    syntax_parse_fact(Registry, _, Parse, Record, _).

project_syntax_node(Registry, Node, Parse, Type) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, Record),
    Parse = Record.parse,
    Type = Record.type.

project_syntax_named(Registry, Node) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, Record),
    Record.named == true.

project_syntax_parent(Registry, Node, Parent) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, Record),
    Parent = Record.parent,
    Parent \== none.

project_syntax_child(Registry, Parent, Index, Child) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Child, Record),
    Record.parent == Parent,
    Index = Record.child_index.

project_syntax_field(Registry, Parent, Field, Child) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Child, Record),
    Record.parent == Parent,
    Record.field \== none,
    Field = Record.field.

project_syntax_span(Registry, Node, Span) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, NodeRecord),
    syntax_parse_fact(Registry, File, NodeRecord.parse, _, _),
    Span = source_span{file:File,
                       start_byte:NodeRecord.start_byte,
                       end_byte:NodeRecord.end_byte}.

project_syntax_points(Registry, Node, StartPoint, EndPoint) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, Record),
    StartPoint = Record.start_point,
    EndPoint = Record.end_point.

project_syntax_error(Registry, Node, Kind) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, Record),
    member(Kind, Record.errors).

project_syntax_node_provenance(Registry, Node, Provenance) :-
    syntax_registry_valid(Registry),
    syntax_node_fact(Registry, Node, NodeRecord),
    syntax_parse_fact(Registry, File, NodeRecord.parse, ParseRecord, _),
    Provenance = project_syntax_provenance{
                     project:ParseRecord.project,
                     file:File,
                     file_hash:ParseRecord.file_hash,
                     file_generation:ParseRecord.file_generation,
                     content_hash:ParseRecord.content_hash,
                     parse:NodeRecord.parse,
                     parse_generation:ParseRecord.generation,
                     language:ParseRecord.language,
                     backend:ParseRecord.backend,
                     grammar_ref:ParseRecord.grammar_ref,
                     start_byte:NodeRecord.start_byte,
                     end_byte:NodeRecord.end_byte,
                     currentness:ParseRecord.currentness
                 }.

project_syntax_node_text(Registry, Node, Options0, Outcome) :-
    catch(project_syntax_node_text_(Registry, Node, Options0, Outcome),
          Exception,
          project_syntax_exception(node_text, Exception, Outcome)).

project_syntax_node_text_(Registry, Node, Options0, Outcome) :-
    project_source_registry_valid(Registry),
    text_options(Options0, Options),
    (   syntax_node_fact(Registry, Node, NodeRecord),
        syntax_parse_fact(Registry, _, NodeRecord.parse, ParseRecord, Source)
    ->  true
    ;   throw(project_syntax_fault(unknown_node(Node)))
    ),
    enforce_currentness(ParseRecord, Options),
    TextBytes is NodeRecord.end_byte - NodeRecord.start_byte,
    enforce_text_limit(TextBytes, Options.max_bytes),
    source_bytes(Source, Bytes),
    byte_slice(Bytes,
               NodeRecord.start_byte,
               NodeRecord.end_byte,
               Slice),
    phrase(utf8_codes(Codes), Slice),
    string_codes(Text, Codes),
    Outcome = ok(Text).

enforce_currentness(ParseRecord, Options) :-
    (   ParseRecord.currentness == current
    ->  true
    ;   Options.allow_stale == true
    ->  true
    ;   throw(project_syntax_fault(stale_parse(ParseRecord.parse)))
    ).

enforce_source_limit(Bytes, Limit) :-
    (   Bytes =< Limit
    ->  true
    ;   throw(project_syntax_blocked(source_limit(Bytes, Limit)))
    ).

validate_registered_hash(unknown, _) :- !.
validate_registered_hash(Hash0, ContentHash) :-
    hash_atom(Hash0, Hash),
    (   atom_concat('sha256:', Expected0, Hash)
    ->  Expected = Expected0
    ;   Expected = Hash
    ),
    downcase_atom(Expected, ExpectedLower),
    downcase_atom(ContentHash, ContentLower),
    (   ExpectedLower == ContentLower
    ->  true
    ;   throw(project_syntax_fault(source_hash_mismatch(Hash0, ContentHash)))
    ).

hash_atom(Hash, Hash) :- atom(Hash), !.
hash_atom(Hash, Atom) :- string(Hash), !, atom_string(Atom, Hash).
hash_atom(Hash, _) :-
    throw(project_syntax_fault(invalid_file_hash(Hash))).

enforce_text_limit(Bytes, Limit) :-
    (   Bytes =< Limit
    ->  true
    ;   throw(project_syntax_blocked(text_limit(Bytes, Limit)))
    ).

enforce_file_policy(Record, Options) :-
    enforce_file_flag(excluded, Record.excluded, Options.include_excluded),
    enforce_file_flag(vendor, Record.vendor, Options.include_vendor),
    enforce_file_flag(generated, Record.generated, Options.include_generated).

enforce_file_flag(_, false, _) :- !.
enforce_file_flag(_, true, true) :- !.
enforce_file_flag(Name, true, false) :-
    throw(project_syntax_blocked(file_policy(Name))).

materialize_options(Options0, Options) :-
    require_options_list(Options0),
    allowed_options(Options0,
                    [mode, max_source_bytes, max_nodes, max_depth,
                     timeout_seconds, include_excluded, include_vendor,
                     include_generated]),
    option(mode(Mode), Options0, named),
    require_projection_mode(Mode),
    option(max_source_bytes(MaxSourceBytes), Options0, 1048576),
    option(max_nodes(MaxNodes), Options0, 10000),
    option(max_depth(MaxDepth), Options0, 256),
    require_nonnegative(max_source_bytes, MaxSourceBytes),
    require_positive(max_nodes, MaxNodes),
    require_nonnegative(max_depth, MaxDepth),
    option(timeout_seconds(TimeoutSeconds), Options0, 30.0),
    require_positive_number(timeout_seconds, TimeoutSeconds),
    option(include_excluded(IncludeExcluded), Options0, false),
    option(include_vendor(IncludeVendor), Options0, false),
    option(include_generated(IncludeGenerated), Options0, false),
    require_boolean(include_excluded, IncludeExcluded),
    require_boolean(include_vendor, IncludeVendor),
    require_boolean(include_generated, IncludeGenerated),
    Options = syntax_options{mode:Mode,
                             max_source_bytes:MaxSourceBytes,
                             max_nodes:MaxNodes,
                             max_depth:MaxDepth,
                             timeout_seconds:TimeoutSeconds,
                             include_excluded:IncludeExcluded,
                             include_vendor:IncludeVendor,
                             include_generated:IncludeGenerated}.

text_options(Options0, Options) :-
    require_options_list(Options0),
    allowed_options(Options0, [allow_stale, max_bytes]),
    option(allow_stale(AllowStale), Options0, false),
    option(max_bytes(MaxBytes), Options0, 65536),
    require_boolean(allow_stale, AllowStale),
    require_nonnegative(max_bytes, MaxBytes),
    Options = text_options{allow_stale:AllowStale, max_bytes:MaxBytes}.

allowed_options([], _).
allowed_options([Option|Rest], Names) :-
    compound(Option),
    functor(Option, Name, 1),
    memberchk(Name, Names),
    !,
    allowed_options(Rest, Names).
allowed_options([Option|_], _) :-
    throw(project_syntax_fault(invalid_option(Option))).

require_options_list(Options) :-
    (   is_list(Options)
    ->  true
    ;   throw(project_syntax_fault(invalid_options(Options)))
    ).

require_projection_mode(named) :- !.
require_projection_mode(all) :- !.
require_projection_mode(Mode) :-
    throw(project_syntax_fault(invalid_projection_mode(Mode))).

require_nonnegative(_, Value) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative(Name, Value) :-
    throw(project_syntax_fault(invalid_nonnegative(Name, Value))).

require_positive(_, Value) :-
    integer(Value),
    Value > 0,
    !.
require_positive(Name, Value) :-
    throw(project_syntax_fault(invalid_positive(Name, Value))).

require_positive_number(_, Value) :-
    number(Value),
    Value > 0,
    !.
require_positive_number(Name, Value) :-
    throw(project_syntax_fault(invalid_positive_number(Name, Value))).

require_boolean(_, true) :- !.
require_boolean(_, false) :- !.
require_boolean(Name, Value) :-
    throw(project_syntax_fault(invalid_boolean(Name, Value))).

normalize_source(Source, Text) :-
    (   string(Source)
    ->  Text = Source
    ;   atom(Source)
    ->  atom_string(Source, Text)
    ;   throw(project_syntax_fault(invalid_source(Source)))
    ).

source_bytes(Source, Bytes) :-
    string_codes(Source, Codes),
    phrase(utf8_codes(Codes), Bytes).

source_bytes_bounded(Source, Limit, Bytes, ByteCount) :-
    string_length(Source, CharacterCount),
    source_bytes_bounded_(1,
                          CharacterCount,
                          Source,
                          Limit,
                          0,
                          ByteCount,
                          Bytes,
                          []).

source_bytes_bounded_(Index,
                      CharacterCount,
                      _,
                      _,
                      ByteCount,
                      ByteCount,
                      Bytes,
                      Bytes) :-
    Index > CharacterCount,
    !.
source_bytes_bounded_(Index,
                      CharacterCount,
                      Source,
                      Limit,
                      ByteCount0,
                      ByteCount,
                      Bytes0,
                      Bytes) :-
    string_code(Index, Source, Code),
    phrase(utf8_codes([Code]), Encoded),
    length(Encoded, EncodedBytes),
    ByteCount1 is ByteCount0 + EncodedBytes,
    enforce_source_limit(ByteCount1, Limit),
    append(Encoded, Bytes1, Bytes0),
    Next is Index + 1,
    source_bytes_bounded_(Next,
                          CharacterCount,
                          Source,
                          Limit,
                          ByteCount1,
                          ByteCount,
                          Bytes1,
                          Bytes).

byte_slice(Bytes, Start, End, Slice) :-
    Length is End - Start,
    length(Prefix, Start),
    append(Prefix, Rest, Bytes),
    length(Slice, Length),
    append(Slice, _, Rest),
    !.
byte_slice(_, Start, End, _) :-
    throw(project_syntax_fault(invalid_source_span(Start, End))).

project_syntax_registry_clear(Registry) :-
    with_mutex(rlm_project_syntax,
               transaction(( retractall(syntax_generation_counter(Registry,
                                                                  _,
                                                                  _)),
                             retractall(syntax_latest_admission(Registry,
                                                               _,
                                                               _,
                                                               _)),
                             retractall(syntax_current_parse(Registry, _, _)),
                             retractall(syntax_parse_fact(Registry, _, _, _, _)),
                             retractall(syntax_node_fact(Registry, _, _))
                           ))).

syntax_registry_valid(Registry) :-
    catch(project_source_registry_valid(Registry), _, fail).

project_syntax_exception(_, project_syntax_blocked(Detail), blocked(Error)) :-
    !,
    fault_kind(Detail, Kind),
    Error = project_syntax_error{kind:Kind, detail:Detail}.
project_syntax_exception(Operation,
                         project_syntax_fault(Detail),
                         error(Error)) :-
    !,
    fault_kind(Detail, Kind),
    Error = project_syntax_error{kind:Kind,
                                 operation:Operation,
                                 detail:Detail}.
project_syntax_exception(Operation, time_limit_exceeded, error(Error)) :-
    !,
    Error = project_syntax_error{kind:timeout,
                                 operation:Operation,
                                 detail:time_limit_exceeded}.
project_syntax_exception(Operation, Exception, error(Error)) :-
    Error = project_syntax_error{kind:project_syntax_exception,
                                 operation:Operation,
                                 exception:Exception}.

fault_kind(Detail, Kind) :-
    compound(Detail),
    !,
    functor(Detail, Kind, _).
fault_kind(Kind, Kind).
