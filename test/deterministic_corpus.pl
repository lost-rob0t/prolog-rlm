:- module(deterministic_corpus,
          [ aggregate_files/1,
            aggregate_suites/1,
            candidate_classification/2,
            load_corpus_files/1,
            load_aggregate_files/0,
            validate_candidate_file/1,
            validate_inventory/0,
            validate_source_file/1,
            aggregate_load_succeeded/0
          ]).

:- use_module(library(apply), [maplist/2]).
:- use_module(library(filesex), [directory_file_path/3]).
:- use_module(library(lists), [member/2]).

:- dynamic corpus_root/1.
:- dynamic aggregate_loading/0.
:- dynamic aggregate_load_error/1.
:- multifile user:term_expansion/2.
:- multifile user:message_hook/3.

:- prolog_load_context(directory, Directory),
   assertz(corpus_root(Directory)).

% Aggregate inputs are data-only test definitions.  Reject an executable main
% during term expansion, before SWI can register it as a process entrypoint.
% The guard is scoped to the corpus-loading window so unrelated sources that
% are consulted later keep their normal initialization semantics.
user:term_expansion((:- initialization(_, main)), _) :-
    deterministic_corpus:aggregate_loading,
    (   prolog_load_context(file, File)
    ->  true
    ;   File = unknown
    ),
    throw(error(permission_error(register, aggregate_main, File),
                context(deterministic_corpus, term_expansion/2))).

user:message_hook(Message, error, Lines) :-
    deterministic_corpus:aggregate_loading,
    deterministic_corpus:assertz(aggregate_load_error(message(Message, Lines))),
    fail.

% This is the sole deterministic corpus inventory.  Included entries are
% loaded and their suites are derived below; excluded entries document why a
% test-shaped file belongs to another executable gate.
corpus_entry('bootstrap_test.pl', include(bootstrap)).
corpus_entry('load_error_status_test.pl', include(load_error_status)).
corpus_entry('rlm_closed_data_test.pl', include(rlm_closed_data)).
corpus_entry('rlm_chain_test.pl', include(rlm_chain)).
corpus_entry('rlm_chain_runtime_test.pl', include(rlm_chain_runtime)).
corpus_entry('rlm_chain_message_metadata_test.pl',
             include(rlm_chain_message_metadata)).
corpus_entry('rlm_chain_control_test.pl', include(rlm_chain_control)).
corpus_entry('rlm_stream_canonical_test.pl', include(rlm_stream_canonical)).
corpus_entry('rlm_mcp_model_test.pl', include(rlm_mcp_model)).
corpus_entry('rlm_mcp_2025_test.pl', include(rlm_mcp_2025)).
corpus_entry('rlm_mcp_2026_test.pl', include(rlm_mcp_2026)).
corpus_entry('rlm_mcp_2026_matrix_test.pl', include(rlm_mcp_2026_matrix)).
corpus_entry('rlm_mcp_runtime_test.pl', include(rlm_mcp_runtime)).
corpus_entry('rlm_mcp_dual_test.pl', include(rlm_mcp_dual)).
corpus_entry('rlm_mcp_boundary_test.pl', include(rlm_mcp_boundary)).
corpus_entry('rlm_mcp_declaration_security_test.pl',
             include(rlm_mcp_declaration_security)).
corpus_entry('rlm_context_test.pl', include(rlm_context)).
corpus_entry('rlm_context_adapter_test.pl', include(rlm_context_adapter)).
corpus_entry('rlm_context_budget_test.pl', include(rlm_context_budget)).
corpus_entry('rlm_conversation_test.pl', include(rlm_conversation)).
corpus_entry('rlm_conversation_warm_test.pl',
             include(rlm_conversation_warm)).
corpus_entry('rlm_conversation_runtime_test.pl',
             include(rlm_conversation_runtime)).
corpus_entry('rlm_conversation_cold_test.pl',
             include(rlm_conversation_cold)).
corpus_entry('rlm_plan_test.pl', include(rlm_plan)).
corpus_entry('rlm_tool_test.pl', include(rlm_tool)).
corpus_entry('rlm_tool_effect_test.pl', include(rlm_tool_effect)).
corpus_entry('rlm_tool_loader_test.pl', include(rlm_tool_loader)).
corpus_entry('rlm_tool_loader_security_test.pl',
             include(rlm_tool_loader_security)).
corpus_entry('rlm_prompt_compiler_test.pl', include(rlm_prompt_compiler)).
corpus_entry('rlm_prompt_command_test.pl', include(rlm_prompt_command)).
corpus_entry('rlm_skill_test.pl', include(rlm_skill)).
corpus_entry('rlm_skill_eval_test.pl', include(rlm_skill_eval)).
corpus_entry('rlm_skill_graph_test.pl', include(rlm_skill_graph)).
corpus_entry('rlm_skill_symlink_test.pl',
             include(rlm_skill_symlink_confinement)).
corpus_entry('rlm_authority_test.pl', include(rlm_authority)).
corpus_entry('rlm_authority_hardening_test.pl',
             include(rlm_authority_hardening)).
corpus_entry('rlm_authority_lifecycle_test.pl',
             include(rlm_authority_lifecycle)).
corpus_entry('rlm_effect_test.pl', include(rlm_effect)).
corpus_entry('rlm_effect_authority_test.pl', include(rlm_effect_authority)).
corpus_entry('rlm_effect_executor_test.pl', include(rlm_effect_executor)).
corpus_entry('rlm_effect_restart_test.pl', include(rlm_effect_restart)).
corpus_entry('rlm_effect_hardening_test.pl', include(rlm_effect_hardening)).
corpus_entry('rlm_effect_adversarial_test.pl',
             include(rlm_effect_adversarial)).
corpus_entry('rlm_effect_migration_test.pl', include(rlm_effect_migration)).
corpus_entry('rlm_effect_migration_restart_test.pl',
             include(rlm_effect_migration_restart)).
corpus_entry('rlm_tool_mcp_async_test.pl', include(rlm_tool_mcp_async)).
corpus_entry('rlm_tool_mcp_scheduler_test.pl',
             include(rlm_tool_mcp_scheduler)).
corpus_entry('rlm_completion_test.pl', include(rlm_completion)).
corpus_entry('rlm_completion_planner_validation_retry_test.pl',
             include(rlm_completion_planner_validation_retry)).
corpus_entry('rlm_completion_hardening_test.pl',
             include(rlm_completion_hardening)).
corpus_entry('rlm_completion_tool_visibility_test.pl',
             include(rlm_completion_tool_visibility)).
corpus_entry('rlm_nested_usage_test.pl', include(rlm_nested_usage)).
corpus_entry('rlm_nested_trajectory_test.pl',
             include(rlm_nested_trajectory)).
corpus_entry('rlm_outcome_test.pl', include(rlm_outcome)).
corpus_entry('rlm_artifact_test.pl', include(rlm_artifact)).
corpus_entry('rlm_agent_test.pl', include(rlm_agent)).
corpus_entry('rlm_subagent_test.pl', include(rlm_subagent)).
corpus_entry('rlm_subagent_deadline_test.pl', include(rlm_subagent_deadline)).
corpus_entry('rlm_subagent_supervision_test.pl',
             include(rlm_subagent_supervision)).
corpus_entry('rlm_evolution_test.pl', include(rlm_evolution)).
corpus_entry('rlm_agent_authority_test.pl', include(rlm_agent_authority)).
corpus_entry('rlm_graph_test.pl', include(rlm_graph)).
corpus_entry('rlm_graph_authority_test.pl', include(rlm_graph_authority)).
corpus_entry('rlm_agent_graph_async_test.pl',
             include(rlm_agent_graph_async)).
corpus_entry('rlm_recursion_policy_test.pl', include(rlm_recursion_policy)).
corpus_entry('rlm_recursion_runtime_test.pl',
             include(rlm_recursion_runtime)).
corpus_entry('rlm_benchmark_test.pl', include(rlm_benchmark)).
corpus_entry('rlm_conformance_test.pl', include(rlm_conformance)).
corpus_entry('rlm_deep_experiment_test.pl', include(rlm_deep_experiment)).
corpus_entry('rlm_trace_test.pl', include(rlm_trace)).
corpus_entry('rlm_demo_test.pl', include(rlm_demo)).
corpus_entry('rlm_cli_test.pl', include(rlm_cli)).
corpus_entry('rlm_async_test.pl', include(rlm_async)).
corpus_entry('rlm_async_canonical_test.pl', include(rlm_async_canonical)).
corpus_entry('rlm_async_control_test.pl', include(rlm_async_control)).
corpus_entry('rlm_agent_zero_adapter_test.pl',
             include(rlm_agent_zero_adapter)).
corpus_entry('rlm_spec_verify_test.pl', include(rlm_spec_verify)).
corpus_entry('rlm_result_accept_test.pl', include(rlm_result_accept)).
corpus_entry('rlm_spec_lang_test.pl', include(rlm_spec_lang)).
corpus_entry('rlm_spec_workflow_test.pl', include(rlm_spec_workflow)).
corpus_entry('rlm_project_source_test.pl', include(rlm_project_source)).
corpus_entry('prolog_agent_ui_v1_test.pl', include(prolog_agent_ui_v1)).
corpus_entry('prolog_agent_ui_fixture_command_codec_test.pl',
             include(prolog_agent_ui_fixture_command_codec)).

corpus_entry('rlm_tree_sitter_test.pl',
             exclude(native_ffi, 'runs through the Tree-sitter gate')).
corpus_entry('rlm_project_source_native_test.pl',
             exclude(native_ffi, 'runs through the native source gate')).
corpus_entry('live_chain_stream_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).
corpus_entry('live_plan_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).
corpus_entry('live_tool_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).
corpus_entry('live_completion_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).
corpus_entry('live_repair_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).
corpus_entry('live_openrouter_test.pl',
             exclude(live_provider, 'requires the credentialed live gate')).

% These path policies cover test-shaped support files if one is added later.
% Top-level live/native files remain exact entries above so their exclusion is
% individually reviewable rather than inferred from a broad filename pattern.
corpus_exclusion_policy('support/', support_fixture,
                        'support fixtures are not aggregate tests').
corpus_exclusion_policy('effect_restart_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('effect_projection_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('effect_store_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('effect_migration_crash_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('graph_restart_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('artifact_restart_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('tool_effect_crash_', restart_phase_fixture,
                        'restart phases run in fresh-process fixtures').
corpus_exclusion_policy('run_', standalone_executable,
                        'standalone runners are not aggregate test definitions').
corpus_exclusion_policy('pack_', standalone_executable,
                        'standalone pack checks are not aggregate tests').

aggregate_files(Files) :-
    findall(File, corpus_entry(File, include(_)), Files).

aggregate_suites(Suites) :-
    findall(Suite, corpus_entry(_, include(Suite)), Suites).

load_aggregate_files :-
    retractall(aggregate_load_error(_)),
    setup_call_cleanup(
        assertz(aggregate_loading),
        catch(load_aggregate_files_unsafe, Exception,
              record_aggregate_load_error(Exception)),
        retractall(aggregate_loading)).

load_aggregate_files_unsafe :-
    validate_inventory,
    validate_manifest,
    validate_aggregate_sources,
    aggregate_files(Files),
    maplist(load_aggregate_file, Files).

load_corpus_files(Files) :-
    retractall(aggregate_load_error(_)),
    setup_call_cleanup(
        assertz(aggregate_loading),
        catch(load_corpus_files_unsafe(Files), Exception,
              record_aggregate_load_error(Exception)),
        retractall(aggregate_loading)).

load_corpus_files_unsafe(Files) :-
    maplist(validate_source_file, Files),
    maplist(load_aggregate_file, Files).

load_aggregate_file(Relative) :-
    corpus_file_path(Relative, File),
    (   load_files(File, [if(not_loaded)])
    ->  (   aggregate_load_error(Error)
        ->  throw(error(load_error(File, Error),
                       context(deterministic_corpus,
                               load_aggregate_file/1)))
        ;   true
        )
    ;   throw(error(load_error(File),
                   context(deterministic_corpus, load_aggregate_file/1)))
    ).

record_aggregate_load_error(Exception) :-
    assertz(aggregate_load_error(Exception)),
    format(user_error, 'ERROR: deterministic corpus load failed: ~q~n',
           [Exception]).

aggregate_load_succeeded :-
    \+ aggregate_load_error(_).

validate_inventory :-
    validate_manifest,
    findall(File, candidate_test_file(File), Candidates),
    maplist(validate_candidate_file, Candidates).

validate_manifest :-
    findall(File, corpus_entry(File, _), Files),
    sort(Files, UniqueFiles),
    length(Files, FileCount),
    length(UniqueFiles, FileCount),
    findall(Suite, corpus_entry(_, include(Suite)), Suites),
    sort(Suites, UniqueSuites),
    length(Suites, SuiteCount),
    length(UniqueSuites, SuiteCount),
    maplist(validate_manifest_file, Files).

validate_manifest_file(Relative) :-
    corpus_file_path(Relative, File),
    (   exists_file(File)
    ->  true
    ;   throw(error(existence_error(source_sink, File),
                   context(deterministic_corpus, validate_manifest/0)))
    ).

validate_candidate_file(Relative) :-
    candidate_classification(Relative, Classification),
    (   Classification == unclassified
    ->  throw(error(existence_error(corpus_entry, Relative),
                   context(deterministic_corpus,
                           validate_candidate_file/1)))
    ;   true
    ).

candidate_classification(Relative, include(Suite)) :-
    corpus_entry(Relative, include(Suite)),
    !.
candidate_classification(Relative, exclude(Category, Reason)) :-
    corpus_entry(Relative, exclude(Category, Reason)),
    !.
candidate_classification(Relative, exclude(Category, Reason)) :-
    corpus_exclusion_policy(Prefix, Category, Reason),
    atom_concat(Prefix, _, Relative),
    !.
candidate_classification(_, unclassified).

validate_aggregate_sources :-
    aggregate_files(Files),
    maplist(validate_source_file, Files).

validate_source_file(Relative) :-
    corpus_file_path(Relative, File),
    (   exists_file(File)
    ->  true
    ;   throw(error(existence_error(source_sink, File),
                   context(deterministic_corpus, validate_source_file/1)))
    ).

corpus_file_path(Relative, File) :-
    corpus_root(Root),
    directory_file_path(Root, Relative, File).

candidate_test_file(Relative) :-
    corpus_root(Root),
    relative_file(Root, '', Relative),
    atom_concat(_, '_test.pl', Relative).

relative_file(Directory, Prefix, Relative) :-
    directory_files(Directory, Entries),
    member(Name, Entries),
    Name \= '.',
    Name \= '..',
    directory_file_path(Directory, Name, File),
    (   exists_directory(File)
    ->  relative_path(Prefix, Name, NextPrefix),
        relative_file(File, NextPrefix, Relative)
    ;   relative_path(Prefix, Name, Relative)
    ).

relative_path('', Name, Name).
relative_path(Prefix, Name, Relative) :-
    Prefix \= '',
    atomic_list_concat([Prefix, Name], '/', Relative).
