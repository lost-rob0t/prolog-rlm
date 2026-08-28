:- initialization(main, main).

/** <module> #288 plan-graph contract presence gate

One Prolog fact per externally observable requirement from issue #288.  The
runner loops over every fact, verifies it against the current checkout, and
exits non-zero while any requirement is undefined.  Behavioral edge cases stay
in test/rlm_plan_graph_test.pl; this file pins that the required public
surface *exists at all* (module exports, closed op vocabulary, resolver
contract, docs, tests, authority invariants).

Usage: swipl -q -s scripts/plan_graph_contract_check.pl
*/

:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(readutil)).

main(_) :-
    (   plan_graph_module_loaded
    ->  run_checks
    ;   format("contract: prolog/rlm_plan_graph.pl missing or unloadable~n"),
        report([missing_module]),
        halt(1)
    ).

plan_graph_module_loaded :-
    plan_graph_file(File),
    exists_file(File),
    catch(use_module(File, []), _, fail).

plan_graph_file(File) :-
    prolog_load_context(file, Source),
    file_directory_name(Source, ScriptDir),
    atomic_list_concat([ScriptDir, '/../prolog/rlm_plan_graph.pl'], File).

repo_file(Rel, File) :-
    prolog_load_context(file, Source),
    file_directory_name(Source, ScriptDir),
    atomic_list_concat([ScriptDir, '/../', Rel], File).

run_checks :-
    findall(Id-Status, check_one(Id, Status), Results),
    report(Results),
    (   member(_-failed, Results)
    ->  halt(1)
    ;   halt(0)
    ).

check_one(Id, ok) :-
    contract(Id, Goal),
    !,
    catch(Goal,
          Error,
          ( format("  [~w] threw: ~w~n", [Id, Error]),
            fail )),
    !.
check_one(Id, failed) :-
    (   contract(Id, _)
    ->  format("  [~w] FAIL~n", [Id])
    ;   format("  [~w] malformed contract fact~n", [Id])
    ).

report(Results) :-
    include(failed_result, Results, Failures),
    length(Failures, N),
    (   N == 0
    ->  format("contract: ALL REQUIREMENTS DEFINED~n")
    ;   format("contract: ~w REQUIREMENT(S) UNDEFINED~n", [N])
    ).

failed_result(_-failed).
failed_result(missing_module).

/* Presence helpers ----------------------------------------------------- */

exported(Name/Arity) :-
    module_property(rlm_plan_graph, exports(Exports)),
    memberchk(Name/Arity, Exports).

module_export(Name/Arity) :-
    exported(Name/Arity).

file_contains(File, Needle) :-
    exists_file(File),
    read_file_to_string(File, Text, []),
    sub_string(Text, _, _, _, Needle).

tests_mention(Needle) :-
    repo_file('test/rlm_plan_graph_test.pl', File),
    file_contains(File, Needle).

plan_graph_source_mentions(Needle) :-
    plan_graph_file(File),
    file_contains(File, Needle).

/* Contract facts: one per requirement from #288 ------------------------ */

contract(module_loads_and_exports_parse,
         module_export(plan_graph_parse/2)).
contract(module_loads_and_exports_normalize,
         module_export(plan_graph_normalize/2)).
contract(module_loads_and_exports_validate,
         module_export(plan_graph_validate/4)).
contract(module_loads_and_exports_ready,
         module_export(plan_graph_ready/3)).
contract(module_loads_and_exports_execute,
         module_export(plan_graph_execute/5)).
contract(module_loads_and_exports_run,
         module_export(plan_graph_run/5)).
contract(module_loads_and_exports_budget,
         module_export(default_plan_graph_budget/1)).
contract(module_loads_and_exports_symbol_resolver,
         module_export(plan_graph_resolve_symbol/3)).
contract(module_loads_and_exports_symbol_ref_valid,
         module_export(plan_graph_symbol_ref_valid/1)).
contract(module_loads_and_exports_source_span_valid,
         module_export(plan_graph_source_span_valid/1)).

contract(vocabulary_exactly_closed_set, vocabulary_closed).
contract(vocabulary_no_call_escape, no_call_escape).

contract(capability_per_op_required,
         plan_graph_source_mentions('plan_capability_required')).
contract(expert_registry_host_supplied,
         plan_graph_source_mentions('experts')).
contract(expert_registry_preflight_before_execution,
         plan_graph_source_mentions('preflight')).

contract(rejects_cycles_before_execution,
         tests_mention('rejects_cycle')).
contract(rejects_unknown_dependency,
         tests_mention('rejects_unknown_dependency')).
contract(rejects_duplicate_step_id,
         tests_mention('rejects_duplicate_step_id')).
contract(ready_step_scheduling_order,
         tests_mention('ready_step')).
contract(failure_blocks_dependents_structured,
         tests_mention('blocks_dependents')).
contract(capability_denial_per_op,
         tests_mention('capability_denied')).
contract(validate_op_uses_frozen_spec_and_host_verifier,
         tests_mention('validate_step')).
contract(delegate_narrows_capabilities,
         tests_mention('delegate')).
contract(resolver_unresolved_state,
         tests_mention('unresolved')).
contract(resolver_ambiguous_state,
         tests_mention('ambiguous')).
contract(resolver_unsupported_state,
         tests_mention('unsupported')).
contract(parse_json_and_term_forms,
         tests_mention('parses')).
contract(budget_bounds_step_count,
         tests_mention('budget')).

contract(test_module_exists,
         repo_file('test/rlm_plan_graph_test.pl', File),
         exists_file(File)).
contract(docs_exist_and_document_ready_step,
         repo_file('docs/plan-graph-runtime.md', File),
         file_contains(File, 'ready_step')).
contract(docs_link_typed_plans,
         repo_file('docs/typed-plans.md', File),
         file_contains(File, 'plan-graph-runtime.md')).

/* Vocabulary helpers --------------------------------------------------- */

expected_vocabulary([sync_remote/1,
                     index/1,
                     search/2,
                     locate/1,
                     read/1,
                     diff/2,
                     edit/2,
                     create/2,
                     delete/1,
                     run/1,
                     validate/1,
                     delegate/2]).

vocabulary_closed :-
    expected_vocabulary(Expected),
    findall(Name/Arity,
            catch(rlm_plan_graph:plan_graph_op(Name/Arity), _, fail),
            Found0),
    sort(Found0, Found),
    sort(Expected, ExpectedS),
    Found == ExpectedS.

no_call_escape :-
    \+ current_predicate(rlm_plan_graph:plan_graph_eval/1),
    \+ current_predicate(rlm_plan_graph:plan_graph_call/1),
    \+ current_predicate(rlm_plan_graph:plan_graph_shell/1).
