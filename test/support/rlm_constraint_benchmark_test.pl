:- begin_tests(rlm_constraint_benchmark).

:- use_module(library(http/json)).
:- use_module('../../prolog/rlm_plan').
:- use_module('../../prolog/rlm_skill').
:- use_module('../../benchmark/rlm_constraint_problem').
:- use_module('../../benchmark/rlm_constraint_verify').
:- use_module('../../benchmark/rlm_live_deep_experiment').

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

core_skill_content(Name, Content) :-
    skill_default_catalog(ok(Catalog)),
    skill_catalog_skill(Catalog, Name, Skill),
    skill_prompt_unit(Skill,
                      [ activation(always),
                        mandatory_context(true),
                        provider_visible(true)
                      ],
                      ok(Unit)),
    Content = Unit.content.

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

test(known_solution_passes_production_spec_verify_path) :-
    known_solution_json(Json),
    constraint_verify_text_via_spec(Json, ok(Report)),
    assertion(Report.status == passed),
    assertion(Report.oracle_status == passed),
    assertion(Report.requirement_status == passed),
    assertion(Report.violations == []),
    assertion(Report.spec_ref.series == live_constraint_benchmark).

test(single_field_mutation_is_rejected_with_constraint_ids) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 8, Mutated),
    constraint_verify_assignment(Mutated, ok(Report)),
    assertion(Report.status == rejected),
    assertion(member(slots_all_distinct, Report.violations)),
    assertion(member(s1_alpha_beta_sum_9, Report.violations)).

test(mutated_solution_is_rejected_by_spec_verify_path) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 8, Mutated),
    with_output_to(string(Json),
                   json_write_dict(current_output, Mutated, [width(0)])),
    constraint_verify_text_via_spec(Json, ok(Report)),
    assertion(Report.status == rejected),
    assertion(Report.oracle_status == rejected),
    assertion(Report.requirement_status == failed),
    assertion(member(slots_all_distinct, Report.violations)).

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
    assertion(Error.phase == parse),
    constraint_verify_text_via_spec("definitely not json", error(PipelineError)),
    assertion(PipelineError.phase == spec_verify).

test(prose_wrapped_json_is_normalized_but_correctness_is_still_verified) :-
    known_solution_json(Json),
    format(string(Wrapped), "answer follows: ~s end", [Json]),
    constraint_verify_text_via_spec(Wrapped, ok(Report)),
    assertion(Report.status == passed).

test(benchmark_status_comes_from_verification_not_magic_token) :-
    constraint_known_solution(Solution),
    mutate_task_slot(Solution, alpha, 8, Mutated),
    with_output_to(string(Json),
                   json_write_dict(current_output, Mutated, [width(0)])),
    string_concat("LIVE_DEEP_OK ", Json, Text),
    constraint_verify_text_via_spec(Text, Verification),
    constraint_verification_status(Verification, Status, Quality, Details),
    assertion(Status == fail),
    assertion(Quality =:= 0.0),
    assertion(Details.verification_status == rejected).

test(documented_direct_model_contract_parses_as_typed_plan) :-
    Json = "{\"steps\":[{\"op\":\"model\",\"provider\":\"openrouter\",\"prompt\":{\"ref\":\"input\",\"name\":\"query\"},\"options\":{},\"bind\":\"answer\"},{\"op\":\"final\",\"value\":{\"ref\":\"var\",\"name\":\"answer\"}}]}",
    plan_parse(Json, ok(Plan)),
    assertion(Plan == plan([model(openrouter, input(query), _{}, answer),
                            final(var(answer))])).

test(core_operate_skill_exposes_root_typed_plan_contract) :-
    core_skill_content('rlm-operate', Content),
    assertion(sub_string(Content, _, _, _, "{\"steps\":[...]}")),
    assertion(sub_string(Content, _, _, _, "{\"ref\":\"input\",\"name\":\"query\"}")),
    assertion(sub_string(Content, _, _, _, "{\"op\":\"final\"")),
    assertion(\+ sub_string(Content, _, _, _, "slot system first")),
    assertion(\+ sub_string(Content, _, _, _, "\"slot\":7")).

test(core_recurse_skill_exposes_nested_plan_steps_contract) :-
    core_skill_content('rlm-recurse', Content),
    assertion(sub_string(Content, _, _, _, "{\"op\":\"rlm\",\"plan\":{\"steps\":[...]},\"bind\":\"child\"}")),
    assertion(sub_string(Content, _, _, _, "{\"ref\":\"input\",\"name\":\"query\"}")),
    assertion(\+ sub_string(Content, _, _, _, "\"slot\":7")).

test(core_minimal_lane_adds_no_benchmark_specific_planner_instruction) :-
    benchmark_lane_instruction(core_minimal, 2, Options),
    assertion(Options == []).

test(guided_lane_is_explicitly_downstream_owned) :-
    benchmark_lane_instruction(harness_guided, 2, Options),
    assertion(Options = [planner_instruction(Guidance)]),
    assertion(sub_string(Guidance, _, _, _, "depth 2")),
    assertion(sub_string(Guidance, _, _, _, "slot system first")),
    assertion(\+ sub_string(Guidance, _, _, _, "{\"steps\":[...]}")),
    assertion(\+ sub_string(Guidance, _, _, _, "\"slot\":7")).

:- end_tests(rlm_constraint_benchmark).
