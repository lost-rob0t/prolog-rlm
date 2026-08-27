:- encoding(utf8).

:- module(rlm_constraint_verify,
          [ constraint_verify_text_via_spec/2
          ]).

/** <module> Frozen-Spec verification adapter for the live CSP benchmark

The benchmark-local CLP(FD) oracle remains the trusted semantic evaluator, but
acceptance is routed through the production rlm_spec/rlm_verify contract. Model
output is parsed as closed JSON data and supplied as an observation; it never
becomes executable Prolog.
*/

:- use_module(library(http/json)).
:- use_module('../prolog/rlm_spec').
:- use_module('../prolog/rlm_verify').
:- use_module('rlm_constraint_problem').

constraint_verify_text_via_spec(Text0, Outcome) :-
    catch(( parse_assignment(Text0, Assignment),
            constraint_verify_assignment(Assignment, OracleOutcome),
            require_oracle_report(OracleOutcome, OracleReport),
            constraint_registry(Registry),
            constraint_frozen_spec(Registry, Frozen),
            benchmark_observation(Frozen, Assignment, Observation),
            spec_verify(Frozen, [Observation], Registry, VerifyOutcome),
            require_spec_report(VerifyOutcome, SpecReport),
            combine_reports(Frozen, OracleReport, SpecReport, Outcome)
          ),
          Exception,
          pipeline_exception(Exception, Outcome)).

constraint_registry([
    assertion_provider(constraint_solution,
                       1,
                       rlm_constraint_verify:validate_constraint_args,
                       rlm_constraint_verify:evaluate_constraint_solution,
                       none,
                       _{ verifier:_{id:constraint_oracle,version:1},
                           collector:_{id:none,version:1},
                          evidence_policy:_{ required_evidence:true,
                                             source_classes:[benchmark_result],
                                             trust_classes:[observed],
                                             freshness:current
                                           },
                          latency:pure,
                          description:"trusted CLP(FD) benchmark solution oracle"
                        })
]).

validate_constraint_args(Args) :-
    is_dict(Args),
    dict_keys(Args, Keys),
    Keys == [fixture],
    Args.fixture == relay_allocation_v1.

evaluate_constraint_solution(Assertion, Observation, Status) :-
    Assertion.args.fixture == relay_allocation_v1,
    constraint_verify_assignment(Observation.value, OracleOutcome),
    (   OracleOutcome = ok(Report),
        Report.status == passed
    ->  Status = passed
    ;   Status = failed
    ).

constraint_frozen_spec(Registry, Frozen) :-
    Input = _{ schema_version:1,
               subject:_{benchmark:relay_allocation_v1},
               requirements:[
                   _{ id:solution,
                      assertion:assertion(constraint_solution,
                                          _{fixture:relay_allocation_v1}),
                      severity:required,
                      provenance:_{source:live_constraint_benchmark}
                    }
               ],
               output_contract:_{kind:constraint_assignment},
               provenance:_{source:benchmark_harness}
             },
    spec_normalize(Input, ok(Normalized)),
    spec_validate(Normalized, Registry, ok(Validated)),
    spec_freeze(Validated,
                [series(live_constraint_benchmark),version(1)],
                ok(Frozen)).

benchmark_observation(Frozen, Assignment, Observation) :-
    Frozen.requirements = [Requirement],
    Observation = _{ requirement_id:Requirement.id,
                     assertion:Requirement.assertion,
                     status:passed,
                     value:Assignment,
                     evidence_refs:[model_assignment],
                     source_class:benchmark_result,
                     trust_class:observed,
                     provenance:_{source:live_model_output},
                     verifier:Requirement.verifier,
                     collector:Requirement.collector,
                     snapshot:none,
                     freshness:current,
                     coherence:none,
                     state_ref:none
                   }.

combine_reports(Frozen, OracleReport, SpecReport, ok(Report)) :-
    OracleStatus = OracleReport.status,
    SpecStatus = SpecReport.status,
    consistent_status(OracleStatus, SpecStatus),
    SpecReport.requirements = [RequirementResult],
    Report = constraint_verification{
                 status:SpecStatus,
                 complete:OracleReport.complete,
                 unique_fixture:OracleReport.unique_fixture,
                 violations:OracleReport.violations,
                 oracle_status:OracleStatus,
                 requirement_status:RequirementResult.status,
                 spec_ref:Frozen.ref
             }.

consistent_status(passed, passed) :- !.
consistent_status(rejected, rejected) :- !.
consistent_status(Oracle, Spec) :-
    throw(constraint_verify_pipeline(status_mismatch(Oracle, Spec))).

require_oracle_report(ok(Report), Report) :- !.
require_oracle_report(error(Error), _) :-
    throw(constraint_verify_pipeline(oracle_error(Error))).

require_spec_report(ok(Report), Report) :- !.
require_spec_report(error(Error), _) :-
    throw(constraint_verify_pipeline(spec_verify_error(Error))).

parse_assignment(Text0, Assignment) :-
    text_string(Text0, Text),
    extract_json_object(Text, Json),
    atom_string(Atom, Json),
    atom_json_dict(Atom, Assignment, [value_string_as(atom)]).

extract_json_object(Text0, Json) :-
    normalize_space(string(Text), Text0),
    sub_string(Text, Start, _, _, "{"),
    string_length(Text, Length),
    reverse_between(0, Length, End),
    sub_string(Text, End, 1, _, "}"),
    End >= Start,
    !,
    JsonLength is End-Start+1,
    sub_string(Text, Start, JsonLength, _, Json).
extract_json_object(_, _) :-
    throw(constraint_verify_pipeline(no_json_object)).

reverse_between(Low, High, Value) :-
    between(Low, High, Offset),
    Value is High-Offset.

text_string(Value, Value) :- string(Value), !.
text_string(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_string(Value, _) :-
    throw(constraint_verify_pipeline(not_text(Value))).

pipeline_exception(Exception,
                   error(constraint_verification_error{
                             phase:spec_verify,
                             detail:Safe
                         })) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
