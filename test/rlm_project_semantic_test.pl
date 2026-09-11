:- begin_tests(rlm_project_semantic).

:- use_module('../prolog/rlm_async').
:- use_module(library(process)).
:- use_module(library(readutil)).
:- use_module('../prolog/rlm_plan_graph').
:- use_module('../prolog/rlm_project_source').
:- use_module('../prolog/rlm_project_query').
:- use_module('../prolog/rlm_project_semantic_pack').
:- use_module('../prolog/rlm_project_semantic').

:- dynamic semantic_test_directory/1.
:- prolog_load_context(directory, TestDirectory),
   assertz(semantic_test_directory(TestDirectory)).

fixture_path(Language, Path) :-
    semantic_test_directory(TestDirectory),
    current_prolog_flag(shared_object_extension, Extension),
    atomic_list_concat([Language, Extension], '.', FileName),
    directory_file_path(TestDirectory, 'fixtures/tree-sitter', FixtureDirectory),
    directory_file_path(FixtureDirectory, FileName, Path).

fixture_symbol(python, tree_sitter_python).
fixture_symbol(javascript, tree_sitter_javascript).
fixture_symbol(common_lisp, tree_sitter_commonlisp).

with_semantic_registry(Goal) :-
    tmp_file(project_semantic_root, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        project_source_registry_create(Registry),
        call(Goal, Registry, Root),
        ( project_semantic_registry_clear(Registry),
          project_source_registry_destroy(Registry),
          catch(delete_directory_and_contents(Root), _, true)
        )
    ).

register_project(Registry, Root, Project) :-
    project_source_project_register(Registry,
                                    project(semantic_fixture),
                                    _{origin:test, project_root:Root},
                                    ok(project(Project))).

register_file(Registry, Project, Id, Path, File) :-
    project_source_file_register(Registry,
                                 Project,
                                 _{id:Id,
                                   path:Path,
                                   generation:1,
                                   provenance:_{origin:test}},
                                 ok(File)).

activate_fixture(Registry, Language) :-
    fixture_path(Language, Path),
    fixture_symbol(Language, Symbol),
    ts_grammar_register(Registry,
                        Language,
                        _{identity:semantic_fixture(Language),
                          library:Path,
                          symbol:Symbol,
                          abi:unknown,
                          version:"fixture-v1",
                          provenance:_{origin:semantic_fixture}},
                        ok(_)),
    ts_grammar_activate(Registry, Language, ok(activated(_))).

setup_language(Registry, Root, Language, Path, File, Project) :-
    register_project(Registry, Root, Project),
    register_file(Registry, Project, main, Path, File),
    activate_fixture(Registry, Language),
    project_semantic_pack_register(Registry, Language, ok(_)),
    project_semantic_pack_activate(Registry, Language, ok(_)).

setup_language(Registry, Root, Language, Path, File) :-
    setup_language(Registry, Root, Language, Path, File, _).

extract_purposes(Language, Purposes) :-
    findall(Purpose,
            ( language_analysis_capability(Language, Purpose),
              project_semantic_pack_source(Language, Purpose, _)
            ),
            Purposes).

normalize_fixture(Registry, File, Source, Purposes, Summary) :-
    project_query_extract(Registry,
                          File,
                          Source,
                          Purposes,
                          [kb_root(none)],
                          ok(_)),
    project_semantic_normalize(Registry,
                               File,
                               Source,
                               [kb_root(none)],
                               ok(Summary)).

test(python_normalizes_definitions_references_calls_and_imports, [nondet]) :-
    with_semantic_registry(python_normalizes_definitions_references_calls_and_imports_).

python_normalizes_definitions_references_calls_and_imports_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File),
    Source = "import os as operating_system\nfrom collections import OrderedDict\n\ndef answer():\n    return helper(1)\n\ndef helper(n):\n    return n\n\nclass Widget:\n    def render(self):\n        return self.size\n",
    extract_purposes(python, Purposes),
    normalize_fixture(Registry, File, Source, Purposes, Summary),
    assertion(Summary.language == python),
    assertion(Summary.definitions == 4),
    assertion(Summary.calls == 1),
    assertion(Summary.references == 1),
    assertion(Summary.imports == 2),
    findall(Name-Kind,
            ( project_semantic_definitions(Registry, File, none, Definition),
              Name = Definition.name,
              Kind = Definition.kind
            ),
            Definitions),
    assertion(memberchk(answer-function, Definitions)),
    assertion(memberchk(helper-function, Definitions)),
    assertion(memberchk('Widget'-class, Definitions)),
    assertion(memberchk(render-function, Definitions)),
    findall(Callee,
            ( project_semantic_calls(Registry, File, none, Call),
              Callee = Call.callee
            ),
            Callees),
    assertion(Callees == [helper]),
    findall(Target-Alias,
            ( project_semantic_imports(Registry, File, none, Import),
              Target = Import.target,
              Alias = Import.alias
            ),
            Imports),
    assertion(memberchk(os-operating_system, Imports)),
    assertion(memberchk(collections-none, Imports)),
    findall(RefName,
            ( project_semantic_references(Registry, File, none, Reference),
              RefName = Reference.name
            ),
            RefNames),
    assertion(RefNames == [size]).

test(every_observation_has_exact_provenance, [nondet]) :-
    with_semantic_registry(every_observation_has_exact_provenance_).

every_observation_has_exact_provenance_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File, Project),
    Source = "def answer():\n    return helper(1)\n",
    extract_purposes(python, Purposes),
    normalize_fixture(Registry, File, Source, Purposes, _),
    project_source_file(Registry, File, FileRecord),
    findall(Observation,
            ( project_semantic_definitions(Registry, File, none, Observation)
            ; project_semantic_calls(Registry, File, none, Observation)
            ),
            Observations),
    assertion(Observations \= []),
    forall(member(Observation, Observations),
           ( Provenance = Observation.provenance,
             assertion(Provenance.project == Project),
             assertion(Provenance.file == File),
             assertion(Provenance.file_hash == FileRecord.hash),
             assertion(Provenance.file_generation == FileRecord.generation),
             assertion(atom(Provenance.content_hash)),
             assertion(Provenance.parse = syntax_parse(File, _)),
             assertion(integer(Provenance.parse_generation)),
             assertion(Provenance.language == python),
             assertion(Provenance.backend == tree_sitter),
             assertion(Provenance.grammar_ref = grammar_ref(python, _)),
             assertion(Provenance.pack_identity = query_pack(python, _, _)),
             assertion(atom(Provenance.pack_sha256)),
             assertion(Provenance.pack_purpose \== none),
             assertion(Provenance.extractor = semantic_adapter(python, _)),
             assertion(Provenance.node = syntax_node(_, _)),
             assertion(integer(Provenance.start_byte)),
             assertion(integer(Provenance.end_byte)),
             assertion(Observation.extraction = query_extraction(File, _)),
             assertion(Observation.id = semantic_observation(Observation.extraction, _)),
             project_semantic_observation_provenance(Registry, Observation, Provenance)
           )).

test(javascript_uses_the_same_common_predicates, [nondet]) :-
    with_semantic_registry(javascript_uses_the_same_common_predicates_).

javascript_uses_the_same_common_predicates_(Registry, Root) :-
    setup_language(Registry, Root, javascript, "src/example.js", File),
    Source = "import { helper } from \"./helper.js\";\n\nfunction answer() { return helper(1); }\n\nclass Widget {\n  render() { return this.size; }\n}\n\nconst handler = () => 1;\n\nexport function exported() { return 2; }\n",
    extract_purposes(javascript, Purposes),
    normalize_fixture(Registry, File, Source, Purposes, Summary),
    assertion(Summary.definitions == 5),
    assertion(Summary.calls == 1),
    assertion(Summary.imports == 1),
    assertion(Summary.exports == 1),
    findall(Name-Kind,
            ( project_semantic_definitions(Registry, File, none, Definition),
              Name = Definition.name,
              Kind = Definition.kind
            ),
            Definitions),
    assertion(memberchk(answer-function, Definitions)),
    assertion(memberchk('Widget'-class, Definitions)),
    assertion(memberchk(render-method, Definitions)),
    assertion(memberchk(handler-function, Definitions)),
    assertion(memberchk(exported-function, Definitions)),
    findall(Target,
            ( project_semantic_imports(Registry, File, none, Import),
              Target = Import.target
            ),
            Imports),
    assertion(Imports == ['./helper.js']),
    findall(ExportName,
            ( project_semantic_exports(Registry, File, none, Export),
              ExportName = Export.name
            ),
            ExportNames),
    assertion(ExportNames == [exported]).

test(common_lisp_proves_the_adapter_is_not_c_family_shaped, [nondet]) :-
    with_semantic_registry(common_lisp_proves_the_adapter_is_not_c_family_shaped_).

common_lisp_proves_the_adapter_is_not_c_family_shaped_(Registry, Root) :-
    setup_language(Registry, Root, common_lisp, "src/example.lisp", File),
    Source = "(defun answer (x)\n  (helper x))\n\n(defmacro toggle (a) a)\n",
    extract_purposes(common_lisp, Purposes),
    normalize_fixture(Registry, File, Source, Purposes, Summary),
    assertion(Summary.definitions == 2),
    assertion(Summary.calls == 1),
    findall(Name-Kind,
            ( project_semantic_definitions(Registry, File, none, Definition),
              Name = Definition.name,
              Kind = Definition.kind
            ),
            Definitions),
    assertion(memberchk(answer-function, Definitions)),
    assertion(memberchk(toggle-macro, Definitions)),
    findall(Callee,
            ( project_semantic_calls(Registry, File, none, Call),
              Callee = Call.callee
            ),
            Callees),
    assertion(Callees == [helper]),
    % Structurally different language: import/export analysis is declared
    % unsupported rather than silently zero.
    \+ language_analysis_capability(common_lisp, imports),
    \+ language_analysis_capability(common_lisp, exports),
    language_analysis_capability(common_lisp, definitions),
    language_analysis_capability(common_lisp, calls).

test(zero_matches_differ_from_unsupported_capability, [nondet]) :-
    with_semantic_registry(zero_matches_differ_from_unsupported_capability_).

zero_matches_differ_from_unsupported_capability_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/empty.py", File),
    % A file whose extraction completed with zero definition matches.
    Source = "value = 1\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(Summary)),
    member(PurposeStatus, Summary.purposes),
    PurposeStatus = project_semantic_purpose_status{purpose:definitions,
                                                    status:normalized(0)},
    member(ExportStatus, Summary.purposes),
    ExportStatus = project_semantic_purpose_status{purpose:exports,
                                                   status:unsupported}.

test(duplicate_names_resolve_ambiguous_across_and_within_files, [nondet]) :-
    with_semantic_registry(duplicate_names_resolve_ambiguous_across_and_within_files_).

duplicate_names_resolve_ambiguous_across_and_within_files_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, python),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    register_file(Registry, Project, alpha, "src/alpha.py", AlphaFile),
    register_file(Registry, Project, beta, "src/beta.py", BetaFile),
    AlphaSource = "def helper(n):\n    return n\n",
    BetaSource = "def helper(n):\n    return n\n\ndef duplicate():\n    pass\n\ndef duplicate():\n    pass\n",
    project_query_extract(Registry, AlphaFile, AlphaSource, [definitions], [kb_root(none)], ok(_)),
    project_query_extract(Registry, BetaFile, BetaSource, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, AlphaFile, AlphaSource, [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, BetaFile, BetaSource, [kb_root(none)], ok(_)),
    project_semantic_resolve(Registry,
                             Project,
                             symbol_ref{name:helper, kind:function},
                             ok(ambiguous(Symbols))),
    assertion(length(Symbols, 2)),
    forall(member(Symbol, Symbols),
           assertion(Symbol = project_symbol(Project,
                                             helper,
                                             function,
                                             semantic_observation(_, _)))),
    project_semantic_resolve(Registry,
                             Project,
                             symbol_ref{name:duplicate, kind:function},
                             ok(ambiguous(Duplicates))),
    assertion(length(Duplicates, 2)).

test(unresolved_and_external_states_remain_explicit, [nondet]) :-
    with_semantic_registry(unresolved_and_external_states_remain_explicit_).

unresolved_and_external_states_remain_explicit_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File, Project),
    Source = "import os\n\ndef answer():\n    return helper(1)\n",
    extract_purposes(python, Purposes),
    normalize_fixture(Registry, File, Source, Purposes, _),
    project_semantic_resolve(Registry,
                             Project,
                             symbol_ref{name:missing, kind:function},
                             ok(unresolved)),
    ( project_semantic_imports(Registry, File, none, Import),
      Import.target == os
      -> project_semantic_resolve(Registry, Project, import(Import), ok(external))
    ).

test(projects_remain_isolated, [nondet]) :-
    with_semantic_registry(projects_remain_isolated_).

projects_remain_isolated_(Registry, Root) :-
    % Two DISTINCT projects, each with its own root and journal.
    project_source_project_register(Registry,
                                    project(isolated_a),
                                    _{origin:test, project_root:Root},
                                    ok(project(ProjectA))),
    directory_file_path(Root, 'other', OtherRoot0),
    make_directory_path(OtherRoot0),
    project_source_project_register(Registry,
                                    project(isolated_other),
                                    _{origin:test, project_root:OtherRoot0},
                                    ok(project(ProjectB))),
    project_source_file_register(Registry, ProjectA, _{id:alpha, path:"src/alpha.py", provenance:_{origin:test}}, ok(AlphaFile)),
    project_source_file_register(Registry, ProjectA, _{id:alpha2, path:"src/dup.py", provenance:_{origin:test}}, ok(Alpha2File)),
    project_source_file_register(Registry, ProjectB, _{id:beta, path:"src/beta.py", provenance:_{origin:test}}, ok(BetaFile)),
    activate_fixture(Registry, python),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    A = "def helper(n):\n    return n\n",
    B = "def helper(n):\n    return n\n",
    project_query_extract(Registry, AlphaFile, A, [definitions], [kb_root(none)], ok(_)),
    project_query_extract(Registry, Alpha2File, A, [definitions], [kb_root(none)], ok(_)),
    project_query_extract(Registry, BetaFile, B, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, AlphaFile, A, [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, Alpha2File, A, [kb_root(none)], ok(_)),
    % Normalizing the OTHER project switches the attached journal; project A's
    % journal must not absorb B's observations.
    project_semantic_normalize(Registry, BetaFile, B, [kb_root(none)], ok(_)),
    % Re-publish into A's journal after the switch.
    project_semantic_normalize(Registry, AlphaFile, A, [kb_root(none)], ok(_)),
    findall(_, project_semantic_definitions(Registry, AlphaFile, none, _), AlphaDefs),
    assertion(length(AlphaDefs, 1)),
    findall(_, project_semantic_definitions(Registry, BetaFile, none, _), BetaDefs),
    assertion(length(BetaDefs, 1)),
    % Ambiguity is scoped per project: A has two helper definitions, B one.
    project_semantic_resolve(Registry, ProjectA, symbol_ref{name:helper, kind:function}, ok(ambiguous(ASymbols))),
    assertion(length(ASymbols, 2)),
    project_semantic_resolve(Registry, ProjectB, symbol_ref{name:helper, kind:function}, ok(resolved(BOnlySymbol))),
    assertion(BOnlySymbol = project_symbol(ProjectB, helper, function, semantic_observation(query_extraction(BetaFile, _), _))),
    % The symbol index never mixes projects.
    project_semantic_symbol_index(Registry, ProjectA, ok(IndexA)),
    IndexA = symbol_index{project:ProjectA,
                          kinds:_,
                          definitions:ADefs2,
                          coherence:complete},
    forall(member(symbol_definition(Ref, _, _), ADefs2),
           Ref.name == helper),
    project_semantic_symbol_index(Registry, ProjectB, ok(IndexB)),
    IndexB = symbol_index{project:ProjectB,
                          kinds:_,
                          definitions:BDefs2,
                          coherence:complete},
    forall(member(symbol_definition(RefB, _, _), BDefs2),
           RefB.name == helper).

test(stale_extraction_cannot_answer_a_current_query, [nondet]) :-
    with_semantic_registry(stale_extraction_cannot_answer_a_current_query_).

stale_extraction_cannot_answer_a_current_query_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File),
    Source = "def answer():\n    return helper(1)\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(_)),
    findall(_, project_semantic_definitions(Registry, File, none, _), Before),
    assertion(Before \= []),
    % Re-registering the pack with changed source marks the extraction stale
    % and the semantic observations derived from it must stop answering.
    project_query_pack_register(Registry,
                                python,
                                definitions,
                                "(class_definition) @definition",
                                _{version:"pack-v2", provenance:_{origin:test}},
                                ok(_)),
    findall(_, project_semantic_definitions(Registry, File, none, _), After),
    assertion(After == []),
    project_semantic_knowledge_state(Registry, File, State),
    assertion(State = stale(query_extraction(File, _))).

test(pack_replacement_then_reextraction_publishes_a_new_generation, [nondet]) :-
    with_semantic_registry(pack_replacement_then_reextraction_publishes_a_new_generation_).

pack_replacement_then_reextraction_publishes_a_new_generation_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File),
    Source = "def answer():\n    return helper(1)\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(FirstSummary)),
    FirstExtraction = FirstSummary.extraction,
    project_query_pack_register(Registry,
                                python,
                                definitions,
                                "(function_definition name: (identifier) @definition.name) @definition.function",
                                _{version:"pack-v2", provenance:_{origin:test}},
                                ok(replaced(_))),
    project_semantic_pack_activate(Registry, python, ok(_)),
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(SecondSummary)),
    SecondExtraction = SecondSummary.extraction,
    assertion(SecondExtraction \== FirstExtraction),
    findall(Id,
            ( project_semantic_definitions(Registry, File, none, Definition),
              Id = Definition.id
            ),
            Ids),
    assertion(Ids \== []),
    forall(member(Id, Ids),
           Id = semantic_observation(SecondExtraction, _)).

test(derived_relations_expose_their_supporting_observations, [nondet]) :-
    with_semantic_registry(derived_relations_expose_their_supporting_observations_).

derived_relations_expose_their_supporting_observations_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/graph.py", File),
    Source = "def answer():\n    return helper(1)\n\ndef helper(n):\n    return n\n\nclass Widget:\n    def render(self):\n        return self.size\n",
    project_query_extract(Registry, File, Source, [definitions, calls], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(_)),
    % Span containment: Widget contains render.
    findall(Parent-Child,
            project_semantic_contains(Registry, File, Parent, Child),
            Contains),
    assertion(Contains \= []),
    forall(member(Parent-Child, Contains),
           ( assertion(Parent.id \== Child.id),
             assertion(Parent.start_byte =< Child.start_byte),
             assertion(Child.end_byte =< Parent.end_byte)
           )),
    % Call reachability: answer -> helper, with the supporting call id.
    project_semantic_call_reachable(Registry, File, answer, helper, Reach),
    Reach = ok(project_semantic_reach{from:answer, to:helper, path:Path}),
    assertion(Path \= []),
    forall(member(Step, Path),
           ( Step = project_semantic_step{from:answer,
                                          call:semantic_observation(CallExtraction, _),
                                          to:helper},
             CallExtraction = query_extraction(File, _)
           )),
    % Recursive edge terminates with cycle safety.
    Source2 = "def rec(n):\n    return rec(n - 1)\n",
    project_query_extract(Registry, File, Source2, [definitions, calls], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source2, [kb_root(none)], ok(_)),
    project_semantic_call_reachable(Registry, File, rec, rec, RecReach),
    RecReach = ok(project_semantic_reach{from:rec, to:rec, path:RecPath}),
    assertion(length(RecPath, 1)),
    % Unreachable target is explicit.
    project_semantic_call_reachable(Registry, File, answer, nothing, Missing),
    assertion(Missing == ok(unreachable)).

test(symbol_index_feeds_the_plan_graph_resolver, [nondet]) :-
    with_semantic_registry(symbol_index_feeds_the_plan_graph_resolver_).

symbol_index_feeds_the_plan_graph_resolver_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, python),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    register_file(Registry, Project, alpha, "src/alpha.py", AlphaFile),
    register_file(Registry, Project, beta, "src/beta.py", BetaFile),
    AlphaSource = "def answer():\n    return helper(1)\n\ndef helper(n):\n    return n\n",
    BetaSource = "def helper(n):\n    return n\n",
    project_query_extract(Registry, AlphaFile, AlphaSource, [definitions], [kb_root(none)], ok(_)),
    project_query_extract(Registry, BetaFile, BetaSource, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, AlphaFile, AlphaSource, [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, BetaFile, BetaSource, [kb_root(none)], ok(_)),
    project_semantic_symbol_index(Registry, Project, ok(Index)),
    Index = symbol_index{project:Project,
                         kinds:Kinds,
                         definitions:Definitions,
                         coherence:complete},
    memberchk(function, Kinds),
    Definitions \= [],
    forall(member(symbol_definition(Ref, Span, _), Definitions),
           ( plan_graph_symbol_ref_valid(Ref),
             plan_graph_source_span_valid(Span),
             Ref.occurrence == definition
           )),
    plan_graph_resolve_symbol(Index,
                              symbol_ref{name:answer,
                                         kind:function,
                                         occurrence:definition},
                              ok(Binding)),
    Binding = symbol_binding{span:AlphaSpan, provenance:_},
    AlphaSpan = source_span{file:'src/alpha.py', start_byte:0, end_byte:EndByte},
    assertion(EndByte > 0),
    plan_graph_resolve_symbol(Index,
                              symbol_ref{name:helper,
                                         kind:function,
                                         occurrence:definition},
                              error(plan_graph_error{phase:resolve,
                                                     kind:ambiguous,
                                                     detail:spans([_, _])})),
    plan_graph_resolve_symbol(Index,
                              symbol_ref{name:nothing,
                                         kind:function,
                                         occurrence:definition},
                              error(plan_graph_error{phase:resolve,
                                                     kind:unresolved,
                                                     detail:symbol_ref(_)})).

test(file_dependencies_are_derived_from_import_observations, [nondet]) :-
    with_semantic_registry(file_dependencies_are_derived_from_import_observations_).

file_dependencies_are_derived_from_import_observations_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, javascript),
    project_semantic_pack_register(Registry, javascript, ok(_)),
    project_semantic_pack_activate(Registry, javascript, ok(_)),
    register_file(Registry, Project, helper, "src/helper.js", HelperFile),
    register_file(Registry, Project, main, "src/main.js", MainFile),
    HelperSource = "export function helper() { return 1; }\n",
    MainSource = "import { helper } from \"./src/helper.js\";\n\nexport function main() { return helper(); }\n",
    extract_purposes(javascript, Purposes),
    project_query_extract(Registry, HelperFile, HelperSource, Purposes, [kb_root(none)], ok(_)),
    project_query_extract(Registry, MainFile, MainSource, Purposes, [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, HelperFile, HelperSource, [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, MainFile, MainSource, [kb_root(none)], ok(_)),
    findall(FromFile-ToFile-Support,
            project_semantic_file_dependencies(Registry, Project, FromFile, ToFile, Support),
            [MainFile-HelperFile-ImportSupport]),
    ImportSupport = project_semantic_support{observation:ImportId,
                                             target:'./src/helper.js'},
    ImportId = semantic_observation(query_extraction(MainFile, _), _).

test(async_and_sync_normalization_agree, [nondet]) :-
    with_semantic_registry(async_and_sync_normalization_agree_).

async_and_sync_normalization_agree_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File),
    Source = "def answer():\n    return helper(1)\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(SyncSummary)),
    project_semantic_registry_clear(Registry),
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize_async(Registry, File, Source, [kb_root(none)], Future),
    rlm_future_await(Future, AsyncOutcome),
    rlm_future_destroy(Future),
    AsyncOutcome = ok(AsyncSummary),
    assertion(AsyncSummary.definitions == SyncSummary.definitions).

test(registry_clear_removes_semantic_state, [nondet]) :-
    with_semantic_registry(registry_clear_removes_semantic_state_).

registry_clear_removes_semantic_state_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/example.py", File),
    Source = "def answer():\n    return helper(1)\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(_)),
    project_semantic_registry_clear(Registry),
    % knowledge_state is a public read: it self-hydrates from the durable
    % journal, whose extraction is still current in the query layer (#97
    % symmetry).  The re-hydrated knowledge can only come from the journal:
    % clear dropped every in-memory semantic fact and the attachment.
    project_semantic_knowledge_state(Registry, File, current),
    findall(_, project_semantic_definitions(Registry, File, none, _), Rehydrated),
    assertion(Rehydrated \= []),
    project_semantic_knowledge_state(Registry, File, current).

test(partial_index_is_never_reported_complete, [nondet]) :-
    with_semantic_registry(partial_index_is_never_reported_complete_).

partial_index_is_never_reported_complete_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, python),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    register_file(Registry, Project, alpha, "src/alpha.py", AlphaFile),
    register_file(Registry, Project, beta, "src/beta.py", BetaFile),
    AlphaSource = "def answer():\n    return helper(1)\n",
    project_query_extract(Registry, AlphaFile, AlphaSource, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, AlphaFile, AlphaSource, [kb_root(none)], ok(_)),
    % beta is registered but never indexed: the index reports it.
    project_semantic_symbol_index(Registry, Project, ok(Index)),
    Index = symbol_index{project:Project,
                         kinds:_,
                         definitions:Definitions,
                         coherence:partial(stale([]), unindexed([BetaFile]))},
    assertion(Definitions \= []),
    % A resolve that cannot be checked against beta is incomplete, not
    % "does not exist".
    project_semantic_resolve(Registry, Project, symbol_ref{name:missing, kind:function}, ok(incomplete(unresolved, missing([BetaFile])))),
    % A definition found in the indexed part is a complete answer.
    project_semantic_resolve(Registry, Project, symbol_ref{name:answer, kind:function}, ok(resolved(AnswerSymbol))),
    assertion(AnswerSymbol = project_symbol(Project, answer, function, _)),
    % After indexing beta, coherence completes and plain unresolved appears.
    BetaSource = "def helper(n):\n    return n\n",
    project_query_extract(Registry, BetaFile, BetaSource, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, BetaFile, BetaSource, [kb_root(none)], ok(_)),
    project_semantic_resolve(Registry, Project, symbol_ref{name:nothing, kind:function}, ok(unresolved)),
    project_semantic_symbol_index(Registry, Project, ok(Index2)),
    Index2.coherence == complete.

test(ambiguous_resolve_reports_missing_files, [nondet]) :-
    with_semantic_registry(ambiguous_resolve_reports_missing_).

ambiguous_resolve_reports_missing_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, python),
    project_semantic_pack_register(Registry, python, ok(_)),
    project_semantic_pack_activate(Registry, python, ok(_)),
    register_file(Registry, Project, alpha, "src/alpha.py", AlphaFile),
    register_file(Registry, Project, beta, "src/beta.py", BetaFile),
    % alpha carries two same-name definitions so the indexed part alone is
    % ambiguous; beta is registered but never indexed, so the answer must be
    % reported incomplete, never as a plain ambiguous.
    AlphaSource = "def helper():\n    def helper():\n        return 1\n    return helper\n",
    project_query_extract(Registry, AlphaFile, AlphaSource, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, AlphaFile, AlphaSource, [kb_root(none)], ok(_)),
    project_semantic_resolve(Registry, Project, symbol_ref{name:helper, kind:function}, ok(incomplete(ambiguous(Symbols), missing([BetaFile])))),
    assertion(length(Symbols, 2)).

test(shadowed_names_stay_ambiguous, [nondet]) :-
    with_semantic_registry(shadowed_names_stay_ambiguous_).

shadowed_names_stay_ambiguous_(Registry, Root) :-
    setup_language(Registry, Root, python, "src/shadow.py", File, Project),
    Source = "def helper():\n    def helper():\n        return 1\n    return helper\n",
    project_query_extract(Registry, File, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, File, Source, [kb_root(none)], ok(Summary)),
    assertion(Summary.definitions == 2),
    project_semantic_resolve(Registry, Project, symbol_ref{name:helper, kind:function}, ok(ambiguous(Symbols))),
    assertion(length(Symbols, 2)),
    maplist(arg(1), Symbols, SymbolIds),
    sort(SymbolIds, SortedIds),
    SymbolIds \== SortedIds -> sort(SymbolIds, _).

test(host_registered_adapter_extends_the_surface, [nondet]) :-
    with_semantic_registry(host_registered_adapter_extends_the_surface_).

% TypeScript has no grammar in the standard bundle: a host registers the
% grammar (here the javascript library under the typescript language
% identity - a host grammar-mapping decision, per the #95 registry design)
% and the adapter data, after which .ts files flow through the generic path.
host_registered_adapter_extends_the_surface_(Registry, Root) :-
    register_project(Registry, Root, Project),
    activate_fixture(Registry, javascript),
    fixture_path(javascript, JsGrammar),
    ts_grammar_register(Registry,
                        typescript,
                        _{identity:semantic_fixture(typescript),
                          library:JsGrammar,
                          symbol:tree_sitter_javascript,
                          abi:unknown,
                          version:"host-ts",
                          provenance:_{origin:host_adapter_fixture}},
                        ok(_)),
    ts_grammar_activate(Registry, typescript, ok(_)),
    project_semantic_adapter_register(typescript,
                                      [definitions-"(function_declaration name: (identifier) @definition.name) @definition.function"],
                                      ok(registered(typescript))),
    language_analysis_capability(typescript, definitions),
    \+ language_analysis_capability(typescript, imports),
    project_semantic_pack_source(typescript, definitions, TsSource),
    assertion(sub_atom(TsSource, _, _, _, "function_declaration")),
    project_semantic_pack_register(Registry, typescript, ok(_)),
    project_semantic_pack_activate(Registry, typescript, ok(_)),
    register_file(Registry, Project, ts, "src/example.ts", TsFile),
    project_source_file_language(Registry, TsFile, ok(TsResolution)),
    TsResolution.language == typescript,
    Source = "function answer() { return 1; }\n",
    project_query_extract(Registry, TsFile, Source, [definitions], [kb_root(none)], ok(_)),
    project_semantic_normalize(Registry, TsFile, Source, [kb_root(none)], ok(Summary)),
    assertion(Summary.definitions == 1),
    findall(Name,
            ( project_semantic_definitions(Registry, TsFile, none, Definition),
              Name = Definition.name
            ),
            Names),
    assertion(Names == [answer]).

test(no_provider_stack_is_imported_by_the_project_layers, [nondet]) :-
    \+ predicate_property(rlm_project_semantic:_, imported_from(rlm_chain)),
    \+ predicate_property(rlm_project_semantic:_, imported_from(rlm_completion)),
    \+ predicate_property(rlm_project_semantic:_, imported_from(rlm_openai_compatible)),
    \+ predicate_property(rlm_project_query:_, imported_from(rlm_chain)),
    \+ predicate_property(rlm_project_source:_, imported_from(rlm_chain)).

%% Fresh-process durability: the semantic journal is durable when the first
%% process dies, and the restarted process answers semantic queries from the
%% journal alone - no source, no extraction, no model calls.
test(semantic_kb_answers_in_a_fresh_process, [nondet]) :-
    tmp_file(project_semantic_restart, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        true,
        ( run_killed_phase('test/rlm_project_semantic_restart_phase1.pl', Root, current),
          run_phase('test/rlm_project_semantic_restart_phase2.pl', Root, current)
        ),
        catch(delete_directory_and_contents(Root), _, true)).

%% A superseded extraction's semantic observations must never resurrect as
%% current after a restart: the query journal keeps currentness authority.
test(stale_semantic_state_does_not_resurrect_in_a_fresh_process, [nondet]) :-
    tmp_file(project_semantic_restart, Root),
    make_directory_path(Root),
    setup_call_cleanup(
        true,
        ( run_killed_phase('test/rlm_project_semantic_restart_phase1.pl', Root, stale),
          run_phase('test/rlm_project_semantic_restart_phase2.pl', Root, stale)
        ),
        catch(delete_directory_and_contents(Root), _, true)).

run_phase(RelativeScript, Root, Mode) :-
    absolute_file_name(RelativeScript, Script, [access(read)]),
    process_create(path(swipl),
                   ['-q', '-s', Script, '--', Root, Mode],
                   [process(Pid), stdout(pipe(Out))]),
    setup_call_cleanup(
        true,
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "semantic_kb_phase2_complete"),
          process_wait(Pid, Status),
          assertion(Status == exit(0))
        ),
        ( catch(close(Out), _, true),
          catch(process_kill(Pid, kill), _, true),
          catch(process_wait(Pid, _), _, true)
        )
    ).

run_killed_phase(RelativeScript, Root, Mode) :-
    absolute_file_name(RelativeScript, Script, [access(read)]),
    process_create(path(swipl),
                   ['-q', '-s', Script, '--', Root, Mode],
                   [process(Pid), stdin(pipe(In)), stdout(pipe(Out))]),
    setup_call_cleanup(
        true,
        ( read_line_to_string(Out, Marker),
          assertion(Marker == "semantic_kb_phase_complete"),
          process_kill(Pid, kill),
          process_wait(Pid, Status),
          assertion(Status = killed(_))
        ),
        ( catch(close(In), _, true),
          catch(close(Out), _, true),
          catch(process_kill(Pid, kill), _, true),
          catch(process_wait(Pid, _), _, true)
        )
    ).

:- end_tests(rlm_project_semantic).
