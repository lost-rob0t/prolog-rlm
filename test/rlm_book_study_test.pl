:- begin_tests(rlm_book_study).

:- use_module('../examples/prolog_rlm_study').

test(recursive_study_plan_runs_on_real_typed_runtime) :-
    study_run('prolog-rlm', ok(Result)),
    assertion(Result.value.accepted == true),
    assertion(Result.value.missing == []),
    assertion(Result.value.topic == 'prolog-rlm'),
    assertion(Result.checkpoints == [verified]),
    findall(Operation,
            ( member(Transition, Result.transitions),
              Operation = Transition.operation
            ),
            Operations),
    assertion(Operations == [
        tool(study_retrieve),
        tool(study_normalize),
        tool(study_verify),
        final,
        rlm,
        checkpoint,
        final
    ]),
    assertion(Result.budget_remaining.steps =:= 0),
    assertion(Result.budget_remaining.model_calls =:= 0),
    assertion(Result.budget_remaining.tool_calls =:= 0),
    assertion(Result.budget_remaining.context_ops =:= 0).

test(missing_verifier_capability_is_rejected_before_execution) :-
    study_capability_failure(error(Error)),
    assertion(Error.phase == validate),
    assertion(Error.kind == capability_denied),
    assertion(Error.capability == tool(study_verify)).

test(recursive_plan_over_depth_limit_is_rejected_statically) :-
    study_depth_failure(error(Error)),
    assertion(Error.phase == validate),
    assertion(Error.kind == budget_exceeded),
    assertion(Error.budget == depth),
    assertion(Error.estimated =:= 2),
    assertion(Error.limit =:= 1).

:- end_tests(rlm_book_study).
