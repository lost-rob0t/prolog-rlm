/* Design-consistency check for the SPEC/PLAN authority refinement (PR #290).
 *
 * Validates, as inert design facts and pure data checks:
 *   1. docs/research/spec-plan-authority.md exists and covers all 20 refinement items;
 *   2. the SPEC grammar delta (closed symbols + desugaring) and the Section 3
 *      example spec shape-check against it;
 *   3. the structured diagnostics vocabulary (spec_fault details);
 *   4. the gate invariants G1..G5;
 *   5. the PLAN vocabulary (ops/capabilities/experts/desugar), the Section 8
 *      example plan, symbolRef shape, and the diff endpoint grammar;
 *   6. the lambda-RLM mapping table;
 *   7. the implementation slices S1..S10 (acyclic, covering all design tasks);
 *   8. the refinement KB reports every task done.
 *
 * Exit code 0 = all checks pass; 1 = at least one failure.
 */
:- use_module(library(lists)).

check(Name, Goal) :-
    (   catch(Goal, E, report_check_error_(E))
    ->  format('ok    ~w~n', [Name])
    ;   format('FAIL  ~w~n', [Name]),
        nb_getval(spec_plan_failures, N0),
        N1 is N0 + 1,
        nb_setval(spec_plan_failures, N1)
    ).

pad2_task_(N, Task) :-
    (   N < 10
    ->  format(atom(Task), 't0~w', [N])
    ;   format(atom(Task), 't~w', [N])
    ).

report_check_error_(check(Detail)) :- !,
    format('      fault: ~w~n', [Detail]),
    fail.
report_check_error_(E) :-
    print_message(error, E),
    fail.

/* ---- item 1: doc + 20 refinement items ------------------------------- */

doc_('docs/research/spec-plan-authority.md').

refinement_item(1,  'Corrected authority flow',      sec(1)).
refinement_item(2,  'Execution modes preserved',     sec(2)).
refinement_item(3,  'SPEC grammar',                  sec(3)).
refinement_item(4,  'SPEC type system',              sec(4)).
refinement_item(5,  'validateSpec hard gate',        sec(5)).
refinement_item(6,  'Frozen Spec semantics',         sec(6)).
refinement_item(7,  'SPEC to PLAN compiler',         sec(7)).
refinement_item(8,  'PLAN grammar',                  sec(8)).
refinement_item(9,  'PLAN schema validation',        sec(9)).
refinement_item(10, 'Dependency representation',     sec(10)).
refinement_item(11, 'Plan-state representation',     sec(11)).
refinement_item(12, 'Normalized references',         sec(12)).
refinement_item(13, 'Retrieval engine + diff',       sec(13)).
refinement_item(14, 'Write engine',                  sec(14)).
refinement_item(15, 'Validation engine',             sec(15)).
refinement_item(16, 'Expert mapping',                sec(16)).
refinement_item(17, 'Intent system',                 sec(17)).
refinement_item(18, 'Strategy selection',            sec(17)).
refinement_item(19, 'Lambda-RLM mapping',            sec(18)).
refinement_item(20, 'Long-horizon KB + slices',      sec(19)).

doc_covers_all_items :-
    doc_(Doc),
    exists_file(Doc),
    forall(refinement_item(_, _, sec(N)), section_present_(Doc, N)).

section_present_(Doc, N) :-
    format(atom(Header), '## ~w. ', [N]),
    setup_call_cleanup(
        open(Doc, read, In),
        (   repeat,
            read_line_to_string(In, Line),
            (   Line == end_of_file
            ->  !, fail
            ;   sub_atom(Line, 0, _, _, Header)
            ->  !
            ;   fail
            )
        ),
        close(In)
    ).

/* ---- item 3: SPEC grammar delta --------------------------------------- */

spec_symbol(spec, 1).
spec_symbol(schema_version, 1).
spec_symbol(subject, 1).
spec_symbol(require, 2).
spec_symbol(require, 3).
spec_symbol(optional, 2).
spec_symbol(optional, 3).
spec_symbol(invariant, 1).
spec_symbol(output_contract, 1).
spec_symbol(provenance, 1).
spec_symbol(assertion, 2).
spec_symbol(assertion, 3).
spec_symbol(evidence_policy, 1).
spec_symbol(input, 2).
spec_symbol(artifact, 2).
spec_symbol(artifact, 3).
spec_symbol(forbidden, 1).
spec_symbol(ordering, 2).
spec_symbol(conflicts, 2).

spec_singleton(schema_version).
spec_singleton(subject).
spec_singleton(output_contract).
spec_singleton(provenance).

desugar(forbidden(Effect), invariant(forbidden_effect(Effect))).

grammar_delta_complete :-
    forall(member(S/A, [input/2, artifact/2, artifact/3, forbidden/1,
                        ordering/2, conflicts/2, evidence_policy/1]),
           spec_symbol(S, A)).

/* Section 3 example spec, shape-checked as inert data */
example_spec(
    spec(
        updateFoo,
        [ subject(update(symbol(foo))),
          schema_version(1),
          input(base_revision, revision_ref),
          require(remote_synchronized, assertion(remote_state, in_sync(origin))),
          require(project_indexed, assertion(project_index, current)),
          require(foo_satisfies_x,
                  assertion(symbol_semantics, satisfies_x(symbol(foo))),
                  [evidence_policy(evidence_policy{freshness:current})]),
          ordering(remote_synchronized, foo_satisfies_x),
          invariant(preserve_public_api),
          forbidden(delete(file('src/foo.py'))),
          artifact(test_report, test_report),
          evidence_policy(evidence_policy{source_classes:[trusted_runtime,
                                                          external_observation]}),
          provenance(_{author:"design", ticket:"290"})
        ]
    )
).

example_spec_shape_ok :-
    example_spec(spec(_, Forms)),
    is_list(Forms),
    forall(member(Form, Forms),
           (   functor(Form, Name, Arity),
               (   spec_symbol(Name, Arity)
               ->  true
               ;   throw(check(example_form_unknown(Form)))
               )
           )),
    forall(member(S, [schema_version, subject, output_contract, provenance]),
           (   findall(Form2, ( member(Form2, Forms), functor(Form2, S, _) ), Xs),
               length(Xs, Count),
               Count =< 1
           )),
    findall(R, ( member(Form, Forms), Form =.. [require, R|_] ), Reqs),
    length(Reqs, NReqs),
    NReqs >= 3,
    forall(member(Form, Forms),
           (   (   Form = ordering(A, B)
               ;   Form = conflicts(A, B)
               )
           ->  (   memberchk(A, Reqs),
                   memberchk(B, Reqs)
               ->  true
               ;   throw(check(dangling_relation(Form)))
               )
           ;   true
           )),
    (   member(Form, Forms),
        Form = forbidden(Effect),
        !,
        ground(Effect),
        Effect = delete(file(Path)),
        atom(Path)
    ->  true
    ;   throw(check(missing_forbidden))
    ).

/* ---- item 5: diagnostics vocabulary ----------------------------------- */

spec_diagnostic(unknown_assertion_kind(_)).
spec_diagnostic(missing_capability(_)).
spec_diagnostic(contradiction(_, _)).
spec_diagnostic(impossible_requirement(_, _)).
spec_diagnostic(unknown_reference(_)).
spec_diagnostic(missing_input(_)).
spec_diagnostic(invalid_output_contract(_)).
spec_diagnostic(incompatible_constraints(_, _)).
spec_diagnostic(forbidden_effect_conflict(_, _)).
spec_diagnostic(cycle(_)).
spec_diagnostic(no_validation_mechanism(_)).

diagnostics_vocabulary_complete :-
    findall(D, spec_diagnostic(D), Ds),
    length(Ds, 11).

/* ---- gate invariants --------------------------------------------------- */

gate_invariant(g1, no_seed_from_non_frozen_spec).
gate_invariant(g2, validate_is_first_class_hard_gate).
gate_invariant(g3, model_text_is_inert_until_validated).
gate_invariant(g4, spec_repair_vs_verification_repair_are_distinct).
gate_invariant(g5, final_requires_verification_passed).

gates_documented :-
    findall(G, gate_invariant(G, _), Gs),
    sort(Gs, [g1, g2, g3, g4, g5]).

/* ---- item 8: PLAN vocabulary + example plan ---------------------------- */

plan_op(sync_remote, project(sync), source_control, tool(git_sync)).
plan_op(index, project(read), project_retrieval, tool(project_index)).
plan_op(search, project(read), project_retrieval, tool(project_search)).
plan_op(locate, project(read), project_retrieval, tool(project_locate)).
plan_op(read, project(read), project_retrieval, tool(project_read)).
plan_op(diff, project(read), project_retrieval, tool(project_diff)).
plan_op(edit, project(write), project_write, tool(project_edit)).
plan_op(create, project(write), project_write, tool(project_create)).
plan_op(delete, project(write), project_write, tool(project_delete)).
plan_op(run, project(run), project_run, tool(project_run)).
plan_op(validate, project(validate), project_validation, validate_spec).
plan_op(delegate, delegation, delegation, spawn_agent).

plan_vocabulary_complete :-
    findall(Op, plan_op(Op, _, _, _), Ops),
    sort(Ops, Sorted),
    length(Sorted, 12).

example_plan(
    plan([ sync_remote(origin),
           index(project),
           locate(symbolRef(name(foo), kind(function))),
           diff(symbol(foo), revision(remote('origin', 'main'))),
           edit(symbol(foo), change(satisfy(updateFoo)), satisfies(updateFoo)),
           validate(updateFoo)
         ])
).

example_plan_ops_known :-
    example_plan(plan(Steps)),
    forall(member(Step, Steps),
           (   functor(Step, Op, _),
               (   plan_op(Op, _, _, _)
               ->  true
               ;   throw(check(unknown_plan_op(Op)))
               )
           )).

plan_ops_capability_consistent :-
    forall(plan_op(Op, Cap, Intent, _),
           (   atom(Op),
               ground(Cap),
               ground(Intent)
           )).

/* symbolRef shape */
symbol_ref_ok(Ref) :-
    Ref =.. [symbolRef, name(N), kind(K) | Extra],
    atom(N),
    memberchk(K, [function, predicate, method, class, module, type,
                  variable, rule]),
    forall(member(E, Extra), allowed_symbol_field(E)).

allowed_symbol_field(owner(O)) :- ground(O).
allowed_symbol_field(arity(N)) :- integer(N), N >= 0.
allowed_symbol_field(signature(S)) :- integer(S), S >= 0.

example_symbol_refs_ok :-
    symbol_ref_ok(symbolRef(name(foo), kind(function))),
    symbol_ref_ok(symbolRef(name(member), kind(predicate), arity(2))),
    symbol_ref_ok(symbolRef(name(foo), kind(method), owner(class('Bar')))),
    \+ symbol_ref_ok(symbolRef(name(foo), kind(dance))),
    \+ symbol_ref_ok(symbolRef(name(42), kind(function))).

/* diff endpoint grammar */
diff_endpoint(working_tree).
diff_endpoint(index_stage).
diff_endpoint(commit(_)).
diff_endpoint(branch(_)).
diff_endpoint(remote(_, _)).
diff_endpoint(artifact(_)).
diff_endpoint(symbol_version(_, _)).
diff_endpoint(span(_)).
diff_endpoint(candidate(_)).

diff_grammar_complete :-
    findall(E, diff_endpoint(E), Es),
    length(Es, 9),
    diff_endpoint(remote('origin', 'main')),
    diff_endpoint(symbol_version(symbolRef(name(foo), kind(function)), 2)).

/* ---- item 19: lambda-RLM mapping --------------------------------------- */

lambda_rlm(classification,        intent_features_and_strategy_table).
lambda_rlm(strategy_selection,    strategy_select_3).
lambda_rlm(split,                 context_partition_or_parallel_ready_steps).
lambda_rlm(map,                   context_map_or_parallel_subplans).
lambda_rlm(filter,                closed_context_reducer_filter).
lambda_rlm(reduce,                context_reduce).
lambda_rlm(recursive_solve,       rlm_subplan_with_recursion_policy_routes).
lambda_rlm(leaf_solve,            direct_model_or_tool_step).
lambda_rlm(thresholds,            recursion_policy_guards).
lambda_rlm(cost_bounds,           plan_budget_netting).
lambda_rlm(termination,           spec_verification_and_no_progress_guard).
lambda_rlm(when_not_to_recurse,   deterministic_context_route_preference).

lambda_mapping_complete :-
    findall(C, lambda_rlm(C, _), Cs),
    length(Cs, 12).

/* ---- item 20: implementation slices ------------------------------------ */

slice(s1, 'SPEC language delta + validateSpec + diagnostics').
slice(s2, 'Reconcile plan-graph slice onto current main').
slice(s3, 'plan_seed_from_spec + plan KB persistence').
slice(s4, 'plan_validate_against_spec + typed patches').
slice(s5, 'Project index engine (symbol extraction, locate/read/diff)').
slice(s6, 'Project write engine via durable effect boundary').
slice(s7, 'Validation engine assertion kinds').
slice(s8, 'Expert mapping + expert-scoped context compilation').
slice(s9, 'Intent system + strategy_select').
slice(s10, 'Long-horizon KB + failure knowledge').

slice_depends(s3, s1).
slice_depends(s3, s2).
slice_depends(s4, s2).
slice_depends(s4, s3).
slice_depends(s5, s2).
slice_depends(s6, s5).
slice_depends(s7, s5).
slice_depends(s8, s3).
slice_depends(s8, s5).
slice_depends(s8, s6).
slice_depends(s9, s8).
slice_depends(s10, s3).

slice_cover(t01, s2).
slice_cover(t02, s1).
slice_cover(t03, s1).
slice_cover(t04, s1).
slice_cover(t05, s1).
slice_cover(t06, s3).
slice_cover(t07, s2).
slice_cover(t08, s3).
slice_cover(t09, s3).
slice_cover(t10, s5).
slice_cover(t11, s5).
slice_cover(t12, s5).
slice_cover(t13, s6).
slice_cover(t14, s7).
slice_cover(t15, s8).
slice_cover(t16, s8).
slice_cover(t17, s9).
slice_cover(t18, s9).
slice_cover(t19, s9).
slice_cover(t20, s10).
slice_cover(t21, s10).

slices_complete :-
    findall(S, slice(S, _), Ss),
    length(Ss, 10),
    \+ ( slice(S, _),
         slice_path_(S, S) ).

slice_path_(From, Target) :-
    slice_depends(From, Target).
slice_path_(From, Target) :-
    slice_depends(From, Mid),
    slice_path_(Mid, Target).

slices_cover_all_design_tasks :-
    forall(between(1, 21, N),
           (   pad2_task_(N, Task),
               slice_cover(Task, _)
           ->  true
           ;   throw(check(uncovered_task(Task)))
           )),
    forall(slice_cover(Task, Slice),
           (   slice(Slice, _)
           ->  true
           ;   throw(check(unknown_slice_in_cover(Task, Slice)))
           )).

/* ---- refinement KB state ----------------------------------------------- */

kb_all_done :-
    consult('research/spec-plan-refinement-kb.pl'),
    % t23 is this gate itself; it is marked done after this check passes.
    forall(between(1, 22, N),
           (   pad2_task_(N, Task),
               spec_plan_refinement_kb:kb_task_done(Task)
           ->  true
           ;   throw(check(kb_task_not_done(Task)))
           )).

/* ---- main --------------------------------------------------------------- */

run :-
    nb_setval(spec_plan_failures, 0),
    check('doc exists and covers all 20 refinement items', doc_covers_all_items),
    check('SPEC grammar delta symbols defined', grammar_delta_complete),
    check('example spec shape-valid against grammar', example_spec_shape_ok),
    check('desugaring of forbidden/1',
          desugar(forbidden(delete(file('src/foo.py'))),
                  invariant(forbidden_effect(delete(file('src/foo.py')))))),
    check('diagnostics vocabulary complete', diagnostics_vocabulary_complete),
    check('gate invariants G1..G5 documented', gates_documented),
    check('plan vocabulary has 12 closed ops', plan_vocabulary_complete),
    check('example plan ops all in vocabulary', example_plan_ops_known),
    check('plan op -> capability -> expert consistent', plan_ops_capability_consistent),
    check('symbolRef shapes well-formed', example_symbol_refs_ok),
    check('diff endpoint grammar complete', diff_grammar_complete),
    check('lambda-RLM mapping table complete', lambda_mapping_complete),
    check('implementation slices S1..S10 acyclic', slices_complete),
    check('slices cover all design tasks', slices_cover_all_design_tasks),
    check('refinement KB reports all tasks done', kb_all_done),
    nb_getval(spec_plan_failures, F),
    (   F =:= 0
    ->  format('spec-plan-authority: ALL CHECKS PASSED~n')
    ;   format('spec-plan-authority: ~w CHECK(S) FAILED~n', [F]),
        halt(1)
    ).

:- run.
