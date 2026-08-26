:- begin_tests(rlm_constraint_benchmark).

:- use_module(library(http/json)).
:- use_module('../benchmark/rlm_constraint_problem').

known_solution_json(Json) :-
    constraint_known_solution(Solution),
    with_output_to(string(Json),
                   json_write_dict(current_output, Solution, [width(0)])).

mutate_task_slot(Input, Task, Slot, Output) :-
    Rows0 = Input.assignments,
    maplist(mutate_row_slot(Task, Slot), Rows0, Rows),
    put_dict(assignments, Input, Rows, Output).

mutate_row_slot(Task, Slot, Row0, Row) :-
    Row0.task == Task,
    !,
    put_dict(slot, Row0, Slot, Row).
mutate_row_slot(_, _, Row, Row).

drop_task(Input, Task, Output) :-
    include(not_task(Task), Input.assignments, Rows),
    put_dict(assignments, Input, Rows, Output).

not_task(Task, Row) :- Row.task \== Task.

test(fixture_has_exactly_one_solution) :-
    constraint_solution_count(Count),
    assertion(Count =:= 1).

test(known_solution_passes_trusted_verifier) :-
    constraint_known_solution(Solution),
    constraint_verify_assignment(Solution, ok(Report)),
    assertion(Report.status == passed),
    assertion(Report.violations == []).

test(known_solution_json_passes_parser_and_verifier) :-
    known_solution_json(Json),
    constraint_verify_text(Json, ok(Report)),
    assertion(Report.status == passed).

test(single_field_mutation_is_rejected_with_constraint_ids) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 8, Mutated),
    constraint_verify_assignment(Mutated, ok(Report)),
    assertion(Report.status == rejected),
    assertion(member(slots_all_distinct, Report.violations)),
    assertion(member(s1_alpha_beta_sum_9, Report.violations)).

test(incomplete_assignment_fails_shape_validation) :-
    constraint_known_solution(Solution),
    drop_task(Solution, kappa, Incomplete),
    constraint_verify_assignment(Incomplete, error(Error)),
    assertion(Error.phase == normalize).

test(duplicate_domain_value_is_not_accepted) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 6, Mutated),
    constraint_verify_assignment(Mutated, ok(Report)),
    assertion(Report.status == rejected),
    assertion(member(slots_all_distinct, Report.violations)).

test(malformed_output_fails_safely) :-
    constraint_verify_text("definitely not json", error(Error)),
    assertion(Error.phase == parse).

test(prose_wrapped_json_is_normalized_but_correctness_is_still_verified) :-
    known_solution_json(Json),
    format(string(Wrapped), "answer follows: ~s end", [Json]),
    constraint_verify_text(Wrapped, ok(Report)),
    assertion(Report.status == passed).

test(benchmark_status_comes_from_verification_not_magic_token) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 8, Mutated),
    with_output_to(string(Json),
                   json_write_dict(current_output, Mutated, [width(0)])),
    string_concat("LIVE_DEEP_OK ", Json, Text),
    constraint_verify_text(Text, Verification),
    constraint_verification_status(Verification, Status, Quality, Details),
    assertion(Status == fail),
    assertion(Quality =:= 0.0),
    assertion(Details.verification_status == rejected).

test(guidance_is_depth_aware_and_problem_specific_downstream_text) :-
    constraint_guidance(2, Guidance),
    assertion(sub_string(Guidance, _, _, _, "depth 2")),
    assertion(sub_string(Guidance, _, _, _, "slot system first")).

:- end_tests(rlm_constraint_benchmark).
