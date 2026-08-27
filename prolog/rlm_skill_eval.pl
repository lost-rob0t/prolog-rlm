:- module(rlm_skill_eval,
          [ skill_selection_evaluate/4
          ]).

/** <module> Deterministic prompt-compiler skill selection evaluation

This module measures the existing `rlm_prompt_compiler` selection contract.  It
does not select skills itself, execute skills, grant capabilities, or introduce a
second router.  Corpus expectations are closed declarative data and every case
is compiled by the canonical prompt compiler.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(rlm_prompt_compiler, []).

skill_selection_evaluate(Catalog, Cases0, Options, Outcome) :-
    catch(( require_options(Options),
            normalize_cases(Cases0, Cases),
            eval_cases(Catalog, Cases, Options, CaseResults),
            aggregate_metrics(CaseResults, Metrics),
            stable_fingerprint(CaseResults, Metrics, Fingerprint),
            total_latency(CaseResults, TotalLatency),
            Outcome = ok(skill_selection_report{
                             cases:CaseResults,
                             metrics:Metrics,
                             compile_latency_ms:TotalLatency,
                             fingerprint:Fingerprint
                         })
          ),
          Exception,
          eval_exception(Exception, Outcome)).

require_options(Options) :-
    (   is_list(Options),
        ground(Options)
    ->  true
    ;   throw(skill_eval_fault(invalid_options(Options)))
    ).

normalize_cases(Cases0, Cases) :-
    (   is_list(Cases0)
    ->  true
    ;   throw(skill_eval_fault(invalid_corpus(Cases0)))
    ),
    maplist(normalize_case, Cases0, Cases),
    maplist(case_id, Cases, Ids),
    sort(Ids, UniqueIds),
    length(Ids, Count),
    length(UniqueIds, Count).

normalize_case(Case0, Case) :-
    (   is_dict(Case0),
        get_dict(id, Case0, Id),
        get_dict(input, Case0, Input),
        get_dict(expected, Case0, Expected0),
        get_dict(forbidden, Case0, Forbidden0)
    ->  require_case_id(Id),
        normalize_units(expected, Expected0, Expected),
        normalize_units(forbidden, Forbidden0, Forbidden),
        disjoint_expectations(Id, Expected, Forbidden),
        dict_default(Case0, dimensions, [lexical], Dimensions0),
        normalize_dimensions(Dimensions0, Dimensions),
        require_ground_input(Input),
        Case = selection_case{id:Id,
                              input:Input,
                              expected:Expected,
                              forbidden:Forbidden,
                              dimensions:Dimensions}
    ;   throw(skill_eval_fault(invalid_case(Case0)))
    ).

case_id(Case, Case.id).

require_case_id(Id) :-
    (   atomic(Id), Id \== ''
    ->  true
    ;   throw(skill_eval_fault(invalid_case_id(Id)))
    ).

require_ground_input(Input) :-
    (   ground(Input)
    ->  true
    ;   throw(skill_eval_fault(nonground_case_input))
    ).

normalize_units(Field, Units0, Units) :-
    (   is_list(Units0),
        maplist(valid_skill_unit, Units0)
    ->  sort(Units0, Units)
    ;   throw(skill_eval_fault(invalid_units(Field, Units0)))
    ).

valid_skill_unit(skill(Name)) :- atom(Name), Name \== ''.

normalize_dimensions(Dimensions0, Dimensions) :-
    (   is_list(Dimensions0),
        maplist(valid_dimension, Dimensions0)
    ->  sort(Dimensions0, Dimensions)
    ;   throw(skill_eval_fault(invalid_dimensions(Dimensions0)))
    ).

valid_dimension(lexical).
valid_dimension(explicit_only).
valid_dimension(negation).
valid_dimension(dependency).
valid_dimension(conflict).
valid_dimension(supersession).

disjoint_expectations(Id, Expected, Forbidden) :-
    intersection(Expected, Forbidden, Overlap),
    (   Overlap == []
    ->  true
    ;   throw(skill_eval_fault(contradictory_expectation(Id, Overlap)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

/* -------------------------------------------------------------------------
 * Canonical compiler execution
 * ---------------------------------------------------------------------- */

eval_cases(_, [], _, []).
eval_cases(Catalog, [Case|Cases], Options, [Result|Results]) :-
    eval_case(Catalog, Case, Options, Result),
    eval_cases(Catalog, Cases, Options, Results).

eval_case(Catalog, Case, Options, Result) :-
    compile_options(Options, CompileOptions),
    statistics(cputime, Start),
    rlm_prompt_compiler:prompt_compile(Catalog,
                                       Case.input,
                                       CompileOptions,
                                       CompileOutcome),
    statistics(cputime, End),
    LatencyMs is max(0, round((End-Start)*1000)),
    require_compile_outcome(Case.id, CompileOutcome, Compiled),
    skill_units(Compiled.selected_units, Selected),
    expectation_counts(Case.expected,
                       Case.forbidden,
                       Selected,
                       TP, FP, TN, FN),
    expected_explanations(Compiled,
                          Case.expected,
                          Case.forbidden,
                          Explanations),
    selected_token_cost(Compiled, TokenCost),
    case_pass(TP, FP, FN, Case.expected, Pass),
    Result = selection_case_result{
                 id:Case.id,
                 dimensions:Case.dimensions,
                 expected:Case.expected,
                 forbidden:Case.forbidden,
                 selected:Selected,
                 true_positive:TP,
                 false_positive:FP,
                 true_negative:TN,
                 false_negative:FN,
                 pass:Pass,
                 selected_provider_tokens:TokenCost,
                 compile_latency_ms:LatencyMs,
                 compiler_fingerprint:Compiled.fingerprint,
                 explanations:Explanations
             }.

compile_options(Options, CompileOptions) :-
    option(compile_options(CallerOptions), Options, []),
    (   is_list(CallerOptions),
        ground(CallerOptions)
    ->  true
    ;   throw(skill_eval_fault(invalid_compile_options(CallerOptions)))
    ),
    (   member(policy(_), CallerOptions)
    ->  CompileOptions = CallerOptions
    ;   default_policy(Policy),
        CompileOptions = [policy(Policy)|CallerOptions]
    ).

default_policy(context_policy{
                   max_context_tokens:8192,
                   provider_context_tokens:8192,
                   reserve_output_tokens:0,
                   safety_margin_tokens:0,
                   min_recent_turns:0,
                   overflow:deny
               }).

require_compile_outcome(_, ok(Compiled), Compiled) :- !.
require_compile_outcome(Id, error(Error), _) :-
    throw(skill_eval_fault(compile_failed(Id, Error))).

skill_units(Units0, Skills) :-
    findall(skill(Name), member(skill(Name), Units0), Skills0),
    sort(Skills0, Skills).

expectation_counts(Expected, Forbidden, Selected, TP, FP, TN, FN) :-
    include(unit_selected(Selected), Expected, ExpectedSelected),
    include(unit_selected(Selected), Forbidden, ForbiddenSelected),
    length(ExpectedSelected, TP),
    length(ForbiddenSelected, FP),
    length(Expected, ExpectedCount),
    length(Forbidden, ForbiddenCount),
    FN is ExpectedCount-TP,
    TN is ForbiddenCount-FP.

unit_selected(Selected, Unit) :- memberchk(Unit, Selected).

case_pass(TP, 0, 0, Expected, true) :-
    length(Expected, TP),
    !.
case_pass(_, _, _, _, false).

expected_explanations(Compiled, Expected, Forbidden, Explanations) :-
    append(Expected, Forbidden, Units0),
    sort(Units0, Units),
    maplist(unit_explanation(Compiled), Units, Explanations).

unit_explanation(Compiled, Unit,
                 selection_explanation{unit:Unit, outcome:Outcome}) :-
    rlm_prompt_compiler:prompt_explain(Compiled, Unit, Outcome).

selected_token_cost(Compiled, Tokens) :-
    (   is_dict(Compiled.context_pack),
        get_dict(selected, Compiled.context_pack, Selected)
    ->  findall(TokenCount,
                ( member(Selection, Selected),
                  get_dict(value, Selection, Value),
                  is_dict(Value),
                  get_dict(unit, Value, skill(_)),
                  get_dict(tokens, Selection, TokenCount)
                ),
                Counts),
        sum_list(Counts, Tokens)
    ;   Tokens = 0
    ).

/* -------------------------------------------------------------------------
 * Metrics and stable material identity
 * ---------------------------------------------------------------------- */

aggregate_metrics(Cases, Metrics) :-
    sum_field(Cases, true_positive, TP),
    sum_field(Cases, false_positive, FP),
    sum_field(Cases, true_negative, TN),
    sum_field(Cases, false_negative, FN),
    sum_field(Cases, selected_provider_tokens, Tokens),
    ratio(TP, TP+FP, Precision),
    ratio(TP, TP+FN, Recall),
    ratio(FP, FP+TN, FalsePositiveRate),
    ratio(FN, TP+FN, FalseNegativeRate),
    dimension_metrics(Cases, Dimensions),
    length(Cases, CaseCount),
    Metrics = selection_metrics{
                  cases:CaseCount,
                  true_positive:TP,
                  false_positive:FP,
                  true_negative:TN,
                  false_negative:FN,
                  trigger_precision:Precision,
                  trigger_recall:Recall,
                  false_positive_rate:FalsePositiveRate,
                  false_negative_rate:FalseNegativeRate,
                  selected_provider_tokens:Tokens,
                  dimensions:Dimensions
              }.

sum_field(Cases, Field, Sum) :-
    findall(Value,
            ( member(Case, Cases), get_dict(Field, Case, Value) ),
            Values),
    sum_list(Values, Sum).

ratio(_, 0, 1.0) :- !.
ratio(Numerator, Denominator, Ratio) :-
    Ratio is Numerator/Denominator.

dimension_metrics(Cases, Metrics) :-
    Dimensions = [lexical, explicit_only, negation,
                  dependency, conflict, supersession],
    maplist(dimension_metric(Cases), Dimensions, Metrics).

dimension_metric(Cases, Dimension,
                 dimension_metric{dimension:Dimension,
                                  total:Total,
                                  passed:Passed,
                                  failed:Failed,
                                  correctness:Correctness}) :-
    include(case_has_dimension(Dimension), Cases, Relevant),
    length(Relevant, Total),
    include(case_passed, Relevant, Passing),
    length(Passing, Passed),
    Failed is Total-Passed,
    ratio(Passed, Total, Correctness).

case_has_dimension(Dimension, Case) :-
    memberchk(Dimension, Case.dimensions).

case_passed(Case) :- Case.pass == true.

total_latency(Cases, Total) :-
    sum_field(Cases, compile_latency_ms, Total).

stable_fingerprint(Cases, Metrics, Fingerprint) :-
    maplist(stable_case_material, Cases, StableCases),
    Material = skill_selection_eval_v1{cases:StableCases, metrics:Metrics},
    with_output_to(string(Text),
                   write_term(Material,
                              [ quoted(true),
                                ignore_ops(true),
                                numbervars(true)
                              ])),
    crypto_data_hash(Text, Fingerprint, [algorithm(sha256)]).

stable_case_material(Case,
                     selection_case_material{
                         id:Case.id,
                         dimensions:Case.dimensions,
                         expected:Case.expected,
                         forbidden:Case.forbidden,
                         selected:Case.selected,
                         true_positive:Case.true_positive,
                         false_positive:Case.false_positive,
                         true_negative:Case.true_negative,
                         false_negative:Case.false_negative,
                         pass:Case.pass,
                         selected_provider_tokens:Case.selected_provider_tokens,
                         compiler_fingerprint:Case.compiler_fingerprint,
                         explanations:Case.explanations
                     }).

/* -------------------------------------------------------------------------
 * Structured failures
 * ---------------------------------------------------------------------- */

eval_exception(skill_eval_fault(Fault), error(Error)) :-
    !,
    Error = skill_selection_error{kind:invalid_eval,
                                  detail:Fault,
                                  message:"skill selection evaluation failed"}.
eval_exception(Exception, error(Error)) :-
    Error = skill_selection_error{kind:evaluation_error,
                                  detail:Exception,
                                  message:"skill selection evaluation failed"}.
