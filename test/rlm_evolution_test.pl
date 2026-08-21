:- begin_tests(rlm_evolution).

:- use_module('../prolog/rlm_evolution').
:- use_module('../prolog/rlm_async').

constraints(constraints{schema:_{prompt:[p1,p2], loop:[direct,delegate]}}).

candidate(Id, Prompt, Loop, candidate{id:Id, genes:_{prompt:Prompt, loop:Loop}}).

evaluator_ok(Candidate, Context, Outcome) :-
    Outcome = evaluation{candidate:Candidate.id,
                         objectives:_{score:Context.score},
                         evidence:[fixture],
                         usage:usage{tokens:0}}.

evaluator_throw(_, _, _) :-
    throw(error(evaluator_boom, _)).

test(valid_candidate) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_candidate_validate(A, C, ok(Validated)),
    assertion(Validated == A).

test(reject_unknown_gene) :-
    constraints(C),
    Bad = candidate{id:a, genes:_{prompt:p1, loop:direct, shell:true}},
    evolution_candidate_validate(Bad, C, error(Error)),
    assertion(Error.reason == unknown_gene).

test(reject_value_outside_closed_schema) :-
    constraints(C), candidate(a, p1, ambient_shell, Bad),
    evolution_candidate_validate(Bad, C, error(Error)),
    assertion(Error.reason == invalid_gene_value).

test(mutation_is_closed_and_records_lineage) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_mutate(A, set(loop, delegate), C, Child, Lineage),
    assertion(Child.genes.loop == delegate),
    assertion(Lineage.parents == [a]),
    assertion(Lineage.operator == set(loop,delegate)),
    assertion(Lineage.fingerprint \== '').

test(mutation_rejects_unregistered_callable) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_mutate(A, call(writeln, owned), C, Outcome, Lineage),
    assertion(Outcome = error(Error)),
    assertion(Error.reason == unknown_operator),
    assertion(Lineage == none).

test(crossover_selects_only_named_parent_gene) :-
    constraints(C),
    candidate(a, p1, direct, A), candidate(b, p2, delegate, B),
    evolution_crossover(A, B, [take(prompt,right),take(loop,left)], C, Child, Lineage),
    assertion(Child.genes == _{prompt:p2, loop:direct}),
    assertion(Lineage.parents == [a,b]).

test(pareto_selection_preserves_non_dominated_front) :-
    Fitness = [ fitness{candidate:a, objectives:_{correctness:1.0,cost:10}},
                fitness{candidate:b, objectives:_{correctness:0.9,cost:5}},
                fitness{candidate:c, objectives:_{correctness:0.8,cost:12}} ],
    Policy = selection{objectives:[objective(correctness,max),objective(cost,min)]},
    evolution_select(Fitness, Policy, Selected, Evidence),
    assertion(Selected == [a,b]),
    assertion(Evidence.policy == pareto).

test(pareto_tie_is_deterministic) :-
    Fitness = [ fitness{candidate:b, objectives:_{score:1}},
                fitness{candidate:a, objectives:_{score:1}} ],
    Policy = selection{objectives:[objective(score,max)]},
    evolution_select(Fitness, Policy, Selected, _),
    assertion(Selected == [a,b]).

test(async_evaluator_uses_existing_future_runtime,
     [ setup(evolution_evaluator_register(fixture_ok, rlm_evolution_test:evaluator_ok)),
       cleanup(evolution_evaluator_unregister(fixture_ok))
     ]) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_evaluate_async(A, C, fixture_ok, _{score:0.75}, Future),
    rlm_future_metadata(Future, Metadata),
    assertion(Metadata.operation == evolution_evaluate),
    assertion(Metadata.candidate == a),
    rlm_future_await(Future, Outcome),
    assertion(Outcome.status == passed),
    assertion(Outcome.candidate == a),
    assertion(Outcome.objectives.score =:= 0.75),
    assertion(Outcome.evaluator == fixture_ok).

test(sync_evaluator_awaits_same_async_path,
     [ setup(evolution_evaluator_register(fixture_ok, rlm_evolution_test:evaluator_ok)),
       cleanup(evolution_evaluator_unregister(fixture_ok))
     ]) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_evaluate(A, C, fixture_ok, _{score:1.0}, Outcome),
    assertion(Outcome.status == passed),
    assertion(Outcome.objectives.score =:= 1.0).

test(unknown_evaluator_fails_without_future) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_evaluate_async(A, C, missing, _{}, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.reason == unknown_evaluator).

test(invalid_candidate_never_reaches_evaluator,
     [ setup(evolution_evaluator_register(fixture_ok, rlm_evolution_test:evaluator_ok)),
       cleanup(evolution_evaluator_unregister(fixture_ok))
     ]) :-
    constraints(C),
    Bad = candidate{id:a, genes:_{prompt:p1, loop:ambient_shell}},
    evolution_evaluate_async(Bad, C, fixture_ok, _{score:1}, Outcome),
    assertion(Outcome = error(Error)),
    assertion(Error.reason == invalid_gene_value).

test(evaluator_exception_is_structured_failure,
     [ setup(evolution_evaluator_register(fixture_throw, rlm_evolution_test:evaluator_throw)),
       cleanup(evolution_evaluator_unregister(fixture_throw))
     ]) :-
    constraints(C), candidate(a, p1, direct, A),
    evolution_evaluate_async(A, C, fixture_throw, _{}, Future),
    rlm_future_await(Future, Outcome),
    assertion(Outcome.status == error),
    assertion(Outcome.reason = evaluator_exception(_)).

test(registry_rejects_non_ground_evaluator_id,
     [throws(error(instantiation_error,_))]) :-
    evolution_evaluator_register(_, rlm_evolution_test:evaluator_ok).

:- end_tests(rlm_evolution).
