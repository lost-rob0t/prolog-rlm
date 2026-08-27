:- begin_tests(rlm_skill_eval).

:- use_module('../prolog/rlm_prompt_compiler').
:- use_module('../prolog/rlm_skill_eval').

:- meta_predicate with_eval_catalog(1).

with_eval_catalog(Goal) :-
    setup_call_cleanup(prompt_catalog_create(Catalog),
                       call(Goal, Catalog),
                       prompt_catalog_destroy(Catalog)).

skill_spec(Name, Triggers, Aliases, Requires, Conflicts, Supersedes, Priority,
           Spec) :-
    format(string(Content), "Operate skill ~w from trusted fixture evidence.",
           [Name]),
    Spec = prompt_unit{unit:skill(Name),
                       name:Name,
                       kind:skill,
                       category:operator,
                       description:Content,
                       available:true,
                       aliases:Aliases,
                       triggers:Triggers,
                       requires:Requires,
                       suggests:[],
                       conflicts:Conflicts,
                       supersedes:Supersedes,
                       requires_capability:none,
                       priority:Priority,
                       provider_visible:true,
                       mandatory_context:true,
                       schema:none,
                       content:Content,
                       representations:[],
                       provenance:test}.

register_skill(Catalog, Spec) :-
    prompt_catalog_register(Catalog, Spec, ok(_)).

fixture_catalog(Catalog) :-
    skill_spec(review,
               [trigger(keyword(review), 80)],
               ["github"], [], [], [], 100, Review),
    skill_spec(facts,
               [], [], [], [], [], 100, Facts),
    skill_spec(deploy,
               [trigger(keyword(deploy), 80)],
               [], [skill(facts)], [], [], 100, Deploy),
    skill_spec(alpha,
               [trigger(keyword(resolve), 80)],
               [], [], [skill(beta)], [], 200, Alpha),
    skill_spec(beta,
               [trigger(keyword(resolve), 80)],
               [], [], [skill(alpha)], [], 100, Beta),
    skill_spec(new_api,
               [trigger(keyword(api), 80)],
               [], [], [], [skill(old_api)], 200, NewApi),
    skill_spec(old_api,
               [trigger(keyword(api), 80)],
               [], [], [], [], 100, OldApi),
    maplist(register_skill(Catalog),
            [Review, Facts, Deploy, Alpha, Beta, NewApi, OldApi]).

fixture_cases([
    selection_case{id:lexical_review,
                   input:"review this change",
                   expected:[skill(review)],
                   forbidden:[skill(deploy)],
                   dimensions:[lexical]},
    selection_case{id:explicit_facts,
                   input:prompt_input{text:"unrelated",
                                      selected:[skill(facts)]},
                   expected:[skill(facts)],
                   forbidden:[skill(review)],
                   dimensions:[explicit_only]},
    selection_case{id:negated_review,
                   input:"review this without github",
                   expected:[],
                   forbidden:[skill(review)],
                   dimensions:[negation]},
    selection_case{id:dependency_closure,
                   input:"deploy now",
                   expected:[skill(deploy), skill(facts)],
                   forbidden:[skill(review)],
                   dimensions:[dependency]},
    selection_case{id:conflict_resolution,
                   input:"resolve this",
                   expected:[skill(alpha)],
                   forbidden:[skill(beta)],
                   dimensions:[conflict]},
    selection_case{id:supersession_resolution,
                   input:"api migration",
                   expected:[skill(new_api)],
                   forbidden:[skill(old_api)],
                   dimensions:[supersession]}
]).

test(deterministic_corpus_scores_selection_and_dimensions) :-
    with_eval_catalog(score_fixture).

score_fixture(Catalog) :-
    fixture_catalog(Catalog),
    fixture_cases(Cases),
    skill_selection_evaluate(Catalog, Cases, [], ok(Report)),
    Metrics = Report.metrics,
    assertion(Metrics.cases == 6),
    assertion(Metrics.false_positive == 0),
    assertion(Metrics.false_negative == 0),
    assertion(Metrics.trigger_precision =:= 1.0),
    assertion(Metrics.trigger_recall =:= 1.0),
    assertion(Metrics.false_positive_rate =:= 0.0),
    assertion(Metrics.false_negative_rate =:= 0.0),
    assertion(Metrics.selected_provider_tokens > 0),
    forall(member(Dimension, [lexical, explicit_only, negation,
                              dependency, conflict, supersession]),
           ( member(DimensionMetric, Metrics.dimensions),
             DimensionMetric.dimension == Dimension,
             assertion(DimensionMetric.total == 1),
             assertion(DimensionMetric.correctness =:= 1.0)
           )),
    assertion(ground(Report)),
    assertion(atom(Report.fingerprint)).

test(repeated_runs_preserve_material_fingerprint) :-
    with_eval_catalog(repeat_fixture).

repeat_fixture(Catalog) :-
    fixture_catalog(Catalog),
    fixture_cases(Cases),
    skill_selection_evaluate(Catalog, Cases, [], ok(First)),
    skill_selection_evaluate(Catalog, Cases, [], ok(Second)),
    assertion(First.fingerprint == Second.fingerprint),
    assertion(First.metrics == Second.metrics),
    maplist(case_compiler_fingerprint, First.cases, FirstFingerprints),
    maplist(case_compiler_fingerprint, Second.cases, SecondFingerprints),
    assertion(FirstFingerprints == SecondFingerprints).

case_compiler_fingerprint(Case, Case.compiler_fingerprint).

test(explanations_cover_expected_and_forbidden_units) :-
    with_eval_catalog(explanation_fixture).

explanation_fixture(Catalog) :-
    fixture_catalog(Catalog),
    Cases = [selection_case{id:explain,
                            input:"review this change",
                            expected:[skill(review)],
                            forbidden:[skill(deploy)],
                            dimensions:[lexical]}],
    skill_selection_evaluate(Catalog, Cases, [], ok(Report)),
    Report.cases = [Case],
    member(Review, Case.explanations),
    Review.unit == skill(review),
    Review.outcome = ok(_),
    member(Deploy, Case.explanations),
    Deploy.unit == skill(deploy),
    Deploy.outcome = ok(_).

test(contradictory_expectation_is_structured_failure) :-
    with_eval_catalog(contradictory_fixture).

contradictory_fixture(Catalog) :-
    fixture_catalog(Catalog),
    Cases = [selection_case{id:bad,
                            input:"review",
                            expected:[skill(review)],
                            forbidden:[skill(review)],
                            dimensions:[lexical]}],
    skill_selection_evaluate(Catalog, Cases, [], Outcome),
    Outcome = error(Error),
    assertion(Error.kind == invalid_eval),
    assertion(Error.detail ==
              contradictory_expectation(bad, [skill(review)])).

test(nonground_case_input_is_structured_failure) :-
    with_eval_catalog(nonground_fixture).

nonground_fixture(Catalog) :-
    fixture_catalog(Catalog),
    Cases = [selection_case{id:bad_input,
                            input:prompt_input{text:_Untrusted},
                            expected:[],
                            forbidden:[],
                            dimensions:[lexical]}],
    skill_selection_evaluate(Catalog, Cases, [], Outcome),
    Outcome = error(Error),
    assertion(Error.kind == invalid_eval),
    assertion(Error.detail == nonground_case_input).

test(nonground_eval_options_are_structured_failure) :-
    with_eval_catalog(nonground_options_fixture).

nonground_options_fixture(Catalog) :-
    fixture_catalog(Catalog),
    Cases = [selection_case{id:options,
                            input:"review",
                            expected:[skill(review)],
                            forbidden:[],
                            dimensions:[lexical]}],
    skill_selection_evaluate(Catalog,
                             Cases,
                             [compile_options([candidate_limit(_Limit)])],
                             Outcome),
    Outcome = error(Error),
    assertion(Error.kind == invalid_eval),
    assertion(Error.detail = invalid_options(_)).

:- end_tests(rlm_skill_eval).
