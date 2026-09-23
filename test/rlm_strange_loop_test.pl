:- begin_tests(rlm_strange_loop).

:- use_module('../prolog/rlm_strange_loop').

score_rules(Snapshot,
            kb_evaluation{score:Score,
                          evidence:[rule_count(Score)],
                          invariants:[provider_free],
                          metrics:kb_metrics{rules:Score}}) :-
    length(Snapshot.rules, Score).

propose_one_rule(Snapshot, _Reflection, Candidates) :-
    (   member(Rule, Snapshot.rules),
        Rule.id == learned_rule
    ->  Candidates = []
    ;   Candidates = [
            kb_candidate{
                id:add_learned_rule,
                strategy:add_verified_rule,
                rationale:improve_fixture_score,
                patch:[
                    add_rule(
                        kb_rule{
                            id:learned_rule,
                            head:preferred(expert_a),
                            body:[evidence(stable)],
                            provenance:strange_loop_fixture
                        })
                ]
            }
        ]
    ).

verify_improvement(ParentEval,
                   _Candidate,
                   _Snapshot,
                   CandidateEval,
                   Verdict) :-
    (   CandidateEval.score > ParentEval.score
    ->  Verdict = accepted([score_improved])
    ;   Verdict = rejected(no_improvement)
    ).

toggle_eval(Snapshot,
            kb_evaluation{score:1,
                          evidence:[facts(Snapshot.facts)],
                          invariants:[provider_free],
                          metrics:kb_metrics{}}).

toggle_propose(Snapshot, _Reflection, [Candidate]) :-
    (   memberchk(toggle, Snapshot.facts)
    ->  Candidate = kb_candidate{
                       id:remove_toggle,
                       strategy:toggle,
                       rationale:cycle_fixture,
                       patch:[remove_fact(toggle)]
                   }
    ;   Candidate = kb_candidate{
                       id:add_toggle,
                       strategy:toggle,
                       rationale:cycle_fixture,
                       patch:[add_fact(toggle)]
                   }
    ).

accept_all(_ParentEval,
           _Candidate,
           _Snapshot,
           _CandidateEval,
           accepted).

hooks(strange_loop_hooks{
          evaluate:plunit_rlm_strange_loop:score_rules,
          propose:plunit_rlm_strange_loop:propose_one_rule,
          verify:plunit_rlm_strange_loop:verify_improvement
      }).

toggle_hooks(strange_loop_hooks{
                 evaluate:plunit_rlm_strange_loop:toggle_eval,
                 propose:plunit_rlm_strange_loop:toggle_propose,
                 verify:plunit_rlm_strange_loop:accept_all
             }).

empty_snapshot(Snapshot) :-
    strange_loop_snapshot([], [], kb_meta{owner:test}, Snapshot).

test(snapshot_and_patch_are_revisioned_inert_data) :-
    empty_snapshot(S0),
    strange_loop_apply_patch(
        S0,
        [ add_fact(observed(alpha)),
          add_rule(kb_rule{
                       id:r1,
                       head:select(alpha),
                       body:[observed(alpha)],
                       provenance:test
                   }),
          put_meta(strategy_version, 1)
        ],
        S1),
    assertion(S1.generation =:= 1),
    assertion(memberchk(observed(alpha), S1.facts)),
    assertion(S1.meta.strategy_version =:= 1),
    S1.rules = [Rule],
    assertion(Rule.id == r1).

test(closed_patch_vocabulary_rejects_executable_mutation,
     [throws(strange_loop_fault(unknown_patch_operation(_)))]) :-
    empty_snapshot(S0),
    strange_loop_apply_patch(S0,
                             [assertz(evil(rule))],
                             _).

test(one_step_promotes_only_verified_improvement) :-
    empty_snapshot(S0),
    hooks(Hooks),
    strange_loop_step(S0,
                      Hooks,
                      _{max_iterations:4,
                        max_candidates:4,
                        min_improvement:0.5},
                      Step),
    assertion(Step.status == improved),
    assertion(Step.snapshot.generation =:= 1),
    assertion(Step.score =:= 1),
    assertion(Step.improvement =:= 1).

test(run_reaches_stable_fixed_point) :-
    empty_snapshot(S0),
    hooks(Hooks),
    strange_loop_run(S0,
                     Hooks,
                     _{max_iterations:4,
                       max_candidates:4,
                       min_improvement:0.5},
                     Result),
    assertion(Result.status == stable),
    assertion(Result.snapshot.generation =:= 1),
    assertion(Result.evaluation.score =:= 1),
    Result.lineage = [Lineage],
    assertion(Lineage.candidate_id == add_learned_rule).

test(semantic_cycle_is_bounded_even_as_generation_changes) :-
    empty_snapshot(S0),
    toggle_hooks(Hooks),
    strange_loop_run(S0,
                     Hooks,
                     _{max_iterations:8,
                       max_candidates:2,
                       min_improvement:0.0},
                     Result),
    assertion(Result.status == bounded),
    assertion(Result.reason == semantic_cycle),
    assertion(Result.lineage \== []).

test(fingerprint_ignores_revision_generation) :-
    empty_snapshot(S0),
    put_dict(generation, S0, 99, S99),
    strange_loop_fingerprint(S0, A),
    strange_loop_fingerprint(S99, B),
    assertion(A == B).

:- end_tests(rlm_strange_loop).
