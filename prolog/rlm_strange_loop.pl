:- module(rlm_strange_loop,
          [ rlm_strange_loop_ready/0,
            default_strange_loop_options/1,
            strange_loop_snapshot/4,
            strange_loop_snapshot_validate/1,
            strange_loop_fingerprint/2,
            strange_loop_apply_patch/3,
            strange_loop_reflect/3,
            strange_loop_step/4,
            strange_loop_run/4
          ]).

/** <module> Declarative strange-loop KB evolution

A strange loop operates on an inert, revisioned KB snapshot. Candidate changes
are closed data patches; this library never consults generated Prolog, asserts
generated clauses, or turns model/project data into a callable.

Trusted host hooks evaluate, propose and verify candidates. The hook identities
are fixed for one run and are not part of the mutable KB. This keeps recursive
self-improvement at the declarative knowledge/strategy layer: the system may
improve facts, symbolic rules and metadata, but cannot rewrite its evaluator,
verification policy, capability ceiling or trusted handlers by smuggling code
through the KB.
*/

:- use_module(library(crypto)).
:- use_module(library(lists), [member/2, memberchk/2]).
:- use_module(library(pairs), [pairs_keys/2, pairs_values/2]).

rlm_strange_loop_ready.

default_strange_loop_options(
    strange_loop_options{max_iterations:8,
                         max_candidates:16,
                         min_improvement:0.0}).

/* Snapshots ----------------------------------------------------------- */

strange_loop_snapshot(Facts0, Rules0, Meta0, Snapshot) :-
    normalize_snapshot(
        kb_snapshot{generation:0,
                    facts:Facts0,
                    rules:Rules0,
                    meta:Meta0},
        Snapshot).

strange_loop_snapshot_validate(Snapshot0) :-
    normalize_snapshot(Snapshot0, _).

normalize_snapshot(Snapshot0, Snapshot) :-
    require_dict(kb_snapshot, Snapshot0),
    reject_unknown_keys(kb_snapshot,
                        Snapshot0,
                        [generation, facts, rules, meta]),
    require_key(kb_snapshot, Snapshot0, generation, Generation),
    require_key(kb_snapshot, Snapshot0, facts, Facts0),
    require_key(kb_snapshot, Snapshot0, rules, Rules0),
    require_key(kb_snapshot, Snapshot0, meta, Meta0),
    require_nonnegative_integer(generation, Generation),
    normalize_facts(Facts0, Facts),
    normalize_rules(Rules0, Rules),
    normalize_meta(Meta0, Meta),
    Snapshot = kb_snapshot{generation:Generation,
                           facts:Facts,
                           rules:Rules,
                           meta:Meta}.

normalize_facts(Facts0, Facts) :-
    is_list(Facts0),
    forall(member(Fact, Facts0), require_safe_data(fact, Fact)),
    sort(Facts0, Facts),
    !.
normalize_facts(Facts, _) :-
    throw(strange_loop_fault(invalid_facts(Facts))).

normalize_rules(Rules0, Rules) :-
    is_list(Rules0),
    maplist(normalize_rule, Rules0, Rules1),
    findall(Id, (member(Rule, Rules1), Id=Rule.id), Ids),
    sort(Ids, Unique),
    length(Ids, Count),
    length(Unique, Count),
    !,
    findall(Id-Rule,
            ( member(Rule, Rules1),
              Id = Rule.id
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Rules).
normalize_rules(Rules, _) :-
    throw(strange_loop_fault(invalid_or_duplicate_rules(Rules))).

normalize_rule(Rule0, Rule) :-
    require_dict(kb_rule, Rule0),
    reject_unknown_keys(kb_rule,
                        Rule0,
                        [id, head, body, provenance]),
    require_key(kb_rule, Rule0, id, Id),
    require_key(kb_rule, Rule0, head, Head),
    require_key(kb_rule, Rule0, body, Body),
    require_key(kb_rule, Rule0, provenance, Provenance),
    require_nonempty_atom(rule_id, Id),
    require_safe_data(rule_head, Head),
    require_safe_data(rule_body, Body),
    require_safe_data(rule_provenance, Provenance),
    Rule = kb_rule{id:Id,
                   head:Head,
                   body:Body,
                   provenance:Provenance}.

normalize_meta(Meta0, Meta) :-
    require_dict(kb_meta, Meta0),
    require_safe_data(kb_meta, Meta0),
    dict_pairs(Meta0, _, Pairs),
    dict_create(Meta, kb_meta, Pairs).

strange_loop_fingerprint(Snapshot0, Fingerprint) :-
    normalize_snapshot(Snapshot0, Snapshot),
    Material = kb_material{facts:Snapshot.facts,
                           rules:Snapshot.rules,
                           meta:Snapshot.meta},
    term_string(Material,
                Text,
                [quoted(true), numbervars(true), ignore_ops(true)]),
    crypto_data_hash(Text,
                     Hash,
                     [algorithm(sha256), encoding(utf8)]),
    atom_concat('sha256:', Hash, Fingerprint).

/* Closed patch vocabulary -------------------------------------------- */

strange_loop_apply_patch(Snapshot0, Patch0, Snapshot) :-
    normalize_snapshot(Snapshot0, Parent),
    require_patch(Patch0),
    foldl(apply_patch_op, Patch0, Parent, Mutated0),
    Generation is Parent.generation+1,
    put_dict(generation, Mutated0, Generation, Mutated),
    normalize_snapshot(Mutated, Snapshot).

require_patch(Patch) :-
    is_list(Patch),
    Patch \== [],
    forall(member(Op, Patch), valid_patch_op(Op)),
    !.
require_patch(Patch) :-
    throw(strange_loop_fault(invalid_patch(Patch))).

valid_patch_op(add_fact(Fact)) :-
    require_safe_data(fact, Fact).
valid_patch_op(remove_fact(Fact)) :-
    require_safe_data(fact, Fact).
valid_patch_op(add_rule(Rule)) :-
    normalize_rule(Rule, _).
valid_patch_op(remove_rule(Id)) :-
    require_nonempty_atom(rule_id, Id).
valid_patch_op(replace_rule(Id, Rule)) :-
    require_nonempty_atom(rule_id, Id),
    normalize_rule(Rule, Normalized),
    (   Normalized.id == Id
    ->  true
    ;   throw(strange_loop_fault(replacement_rule_id_mismatch(Id,
                                                              Normalized.id)))
    ).
valid_patch_op(put_meta(Key, Value)) :-
    require_nonempty_atom(meta_key, Key),
    require_safe_data(meta_value, Value).
valid_patch_op(remove_meta(Key)) :-
    require_nonempty_atom(meta_key, Key).
valid_patch_op(Op) :-
    throw(strange_loop_fault(unknown_patch_operation(Op))).

apply_patch_op(add_fact(Fact), Snapshot0, Snapshot) :-
    (   memberchk(Fact, Snapshot0.facts)
    ->  throw(strange_loop_fault(duplicate_fact(Fact)))
    ;   sort([Fact|Snapshot0.facts], Facts),
        put_dict(facts, Snapshot0, Facts, Snapshot)
    ).
apply_patch_op(remove_fact(Fact), Snapshot0, Snapshot) :-
    (   select(Fact, Snapshot0.facts, Facts)
    ->  put_dict(facts, Snapshot0, Facts, Snapshot)
    ;   throw(strange_loop_fault(missing_fact(Fact)))
    ).
apply_patch_op(add_rule(Rule0), Snapshot0, Snapshot) :-
    normalize_rule(Rule0, Rule),
    (   rule_by_id(Snapshot0.rules, Rule.id, _)
    ->  throw(strange_loop_fault(duplicate_rule_id(Rule.id)))
    ;   normalize_rules([Rule|Snapshot0.rules], Rules),
        put_dict(rules, Snapshot0, Rules, Snapshot)
    ).
apply_patch_op(remove_rule(Id), Snapshot0, Snapshot) :-
    (   select_rule(Id, Snapshot0.rules, Rules)
    ->  put_dict(rules, Snapshot0, Rules, Snapshot)
    ;   throw(strange_loop_fault(missing_rule(Id)))
    ).
apply_patch_op(replace_rule(Id, Rule0), Snapshot0, Snapshot) :-
    normalize_rule(Rule0, Rule),
    (   Rule.id == Id
    ->  true
    ;   throw(strange_loop_fault(replacement_rule_id_mismatch(Id, Rule.id)))
    ),
    (   replace_rule_by_id(Id, Rule, Snapshot0.rules, Rules0)
    ->  normalize_rules(Rules0, Rules),
        put_dict(rules, Snapshot0, Rules, Snapshot)
    ;   throw(strange_loop_fault(missing_rule(Id)))
    ).
apply_patch_op(put_meta(Key, Value), Snapshot0, Snapshot) :-
    put_dict(Key, Snapshot0.meta, Value, Meta),
    put_dict(meta, Snapshot0, Meta, Snapshot).
apply_patch_op(remove_meta(Key), Snapshot0, Snapshot) :-
    (   del_dict(Key, Snapshot0.meta, _, Meta)
    ->  put_dict(meta, Snapshot0, Meta, Snapshot)
    ;   throw(strange_loop_fault(missing_meta_key(Key)))
    ).

rule_by_id([Rule|_], Id, Rule) :-
    Rule.id == Id,
    !.
rule_by_id([_|Rest], Id, Rule) :-
    rule_by_id(Rest, Id, Rule).

select_rule(Id, [Rule|Rest], Rest) :-
    Rule.id == Id,
    !.
select_rule(Id, [Rule|Rest], [Rule|Tail]) :-
    select_rule(Id, Rest, Tail).

replace_rule_by_id(Id, Replacement, [Rule|Rest],
                   [Replacement|Rest]) :-
    Rule.id == Id,
    !.
replace_rule_by_id(Id, Replacement, [Rule|Rest],
                   [Rule|Tail]) :-
    replace_rule_by_id(Id, Replacement, Rest, Tail).

/* Reflection ---------------------------------------------------------- */

strange_loop_reflect(Snapshot0, Evaluation0, Reflection) :-
    normalize_snapshot(Snapshot0, Snapshot),
    normalize_evaluation(Evaluation0, Evaluation),
    strange_loop_fingerprint(Snapshot, Fingerprint),
    Reflection = kb_reflection{
                     generation:Snapshot.generation,
                     fingerprint:Fingerprint,
                     score:Evaluation.score,
                     evidence:Evaluation.evidence,
                     invariants:Evaluation.invariants,
                     metrics:Evaluation.metrics
                 }.

normalize_evaluation(Evaluation0, Evaluation) :-
    require_dict(kb_evaluation, Evaluation0),
    reject_unknown_keys(kb_evaluation,
                        Evaluation0,
                        [score, evidence, invariants, metrics]),
    require_key(kb_evaluation, Evaluation0, score, Score),
    dict_get_default(Evaluation0, evidence, [], Evidence),
    dict_get_default(Evaluation0, invariants, [], Invariants),
    dict_get_default(Evaluation0, metrics, kb_metrics{}, Metrics),
    require_number(score, Score),
    require_safe_list(evidence, Evidence),
    require_safe_list(invariants, Invariants),
    require_safe_data(metrics, Metrics),
    Evaluation = kb_evaluation{score:Score,
                               evidence:Evidence,
                               invariants:Invariants,
                               metrics:Metrics}.

/* One RSI step -------------------------------------------------------- */

strange_loop_step(Snapshot0, Hooks0, Options0, Outcome) :-
    catch(strange_loop_step_(Snapshot0, Hooks0, Options0, Outcome),
          Exception,
          strange_loop_exception(Exception, Outcome)).

strange_loop_step_(Snapshot0, Hooks0, Options0, Outcome) :-
    normalize_snapshot(Snapshot0, Snapshot),
    normalize_hooks(Hooks0, Hooks),
    normalize_options(Options0, Options),
    hook_evaluate(Hooks.evaluate, Snapshot, ParentEval),
    strange_loop_reflect(Snapshot, ParentEval, Reflection),
    hook_propose(Hooks.propose,
                 Snapshot,
                 Reflection,
                 Options.max_candidates,
                 Candidates),
    evaluate_candidates(Candidates,
                        Snapshot,
                        ParentEval,
                        Hooks,
                        Options,
                        Evaluated),
    select_improvement(Evaluated,
                       ParentEval.score,
                       Options.min_improvement,
                       Selection),
    step_selection_outcome(Selection,
                           Snapshot,
                           ParentEval,
                           Reflection,
                           Outcome).

evaluate_candidates([], _, _, _, _, []).
evaluate_candidates([Candidate|Rest],
                    Parent,
                    ParentEval,
                    Hooks,
                    Options,
                    [Evaluated|Tail]) :-
    evaluate_candidate(Candidate,
                       Parent,
                       ParentEval,
                       Hooks,
                       Options,
                       Evaluated),
    evaluate_candidates(Rest,
                        Parent,
                        ParentEval,
                        Hooks,
                        Options,
                        Tail).

evaluate_candidate(Candidate,
                   Parent,
                   ParentEval,
                   Hooks,
                   _Options,
                   Evaluated) :-
    (   catch(strange_loop_apply_patch(Parent,
                                       Candidate.patch,
                                       CandidateSnapshot),
              Exception,
              CandidateError = Exception)
    ->  true
    ;   CandidateError = patch_failed
    ),
    (   var(CandidateError)
    ->  hook_evaluate(Hooks.evaluate,
                      CandidateSnapshot,
                      CandidateEval),
        hook_verify(Hooks.verify,
                    ParentEval,
                    Candidate,
                    CandidateSnapshot,
                    CandidateEval,
                    Verification),
        Improvement is CandidateEval.score-ParentEval.score,
        Evaluated = kb_candidate_evaluation{
                        id:Candidate.id,
                        strategy:Candidate.strategy,
                        rationale:Candidate.rationale,
                        patch:Candidate.patch,
                        snapshot:CandidateSnapshot,
                        score:CandidateEval.score,
                        improvement:Improvement,
                        evaluation:CandidateEval,
                        verification:Verification
                    }
    ;   safe_exception(CandidateError, Safe),
        Evaluated = kb_candidate_evaluation{
                        id:Candidate.id,
                        strategy:Candidate.strategy,
                        rationale:Candidate.rationale,
                        patch:Candidate.patch,
                        status:invalid,
                        error:Safe,
                        improvement: -1.0Inf,
                        verification:rejected(invalid_patch)
                    }
    ).

select_improvement(Evaluated, ParentScore, Minimum, Selection) :-
    findall(Key-Candidate,
            ( member(Candidate, Evaluated),
              candidate_accepted(Candidate),
              Candidate.score >= ParentScore+Minimum,
              NegScore is -Candidate.score,
              Key = NegScore-Candidate.id
            ),
            Pairs0),
    keysort(Pairs0, Pairs),
    (   Pairs = [_-Winner|_]
    ->  Selection = selected(Winner)
    ;   Selection = none(Evaluated)
    ).

candidate_accepted(Candidate) :-
    get_dict(verification, Candidate, Verification),
    (   Verification = accepted
    ;   Verification = accepted(_)
    ).

step_selection_outcome(selected(Winner),
                       Parent,
                       ParentEval,
                       Reflection,
                       strange_loop_step{
                           status:improved,
                           parent_generation:Parent.generation,
                           parent_score:ParentEval.score,
                           candidate_id:Winner.id,
                           strategy:Winner.strategy,
                           score:Winner.score,
                           improvement:Winner.improvement,
                           snapshot:Winner.snapshot,
                           evaluation:Winner.evaluation,
                           verification:Winner.verification,
                           reflection:Reflection,
                           lineage:kb_lineage{
                                       from_generation:Parent.generation,
                                       to_generation:Winner.snapshot.generation,
                                       candidate_id:Winner.id,
                                       strategy:Winner.strategy,
                                       parent_score:ParentEval.score,
                                       child_score:Winner.score
                                   }
                       }) :-
    !.
step_selection_outcome(none(Evaluated),
                       Parent,
                       ParentEval,
                       Reflection,
                       strange_loop_step{
                           status:stable,
                           reason:no_verified_improvement,
                           parent_generation:Parent.generation,
                           parent_score:ParentEval.score,
                           candidates:Evaluated,
                           snapshot:Parent,
                           evaluation:ParentEval,
                           reflection:Reflection
                       }).

/* Bounded run --------------------------------------------------------- */

strange_loop_run(Snapshot0, Hooks0, Options0, Outcome) :-
    catch(strange_loop_run_(Snapshot0, Hooks0, Options0, Outcome),
          Exception,
          strange_loop_exception(Exception, Outcome)).

strange_loop_run_(Snapshot0, Hooks0, Options0, Outcome) :-
    normalize_snapshot(Snapshot0, Snapshot),
    normalize_hooks(Hooks0, Hooks),
    normalize_options(Options0, Options),
    strange_loop_fingerprint(Snapshot, InitialFingerprint),
    run_loop(0,
             Options.max_iterations,
             [InitialFingerprint],
             [],
             Snapshot,
             Hooks,
             Options,
             Outcome).

run_loop(Iteration,
         MaxIterations,
         _Seen,
         Lineage,
         Snapshot,
         Hooks,
         _Options,
         Outcome) :-
    Iteration >= MaxIterations,
    !,
    hook_evaluate(Hooks.evaluate, Snapshot, Evaluation),
    reverse(Lineage, Ordered),
    Outcome = strange_loop_result{
                  status:bounded,
                  reason:max_iterations,
                  iterations:Iteration,
                  snapshot:Snapshot,
                  evaluation:Evaluation,
                  lineage:Ordered
              }.
run_loop(Iteration,
         MaxIterations,
         Seen,
         Lineage,
         Snapshot,
         Hooks,
         Options,
         Outcome) :-
    strange_loop_step_(Snapshot, Hooks, Options, Step),
    (   Step.status == stable
    ->  reverse(Lineage, Ordered),
        Outcome = strange_loop_result{
                      status:stable,
                      reason:Step.reason,
                      iterations:Iteration,
                      snapshot:Snapshot,
                      evaluation:Step.evaluation,
                      reflection:Step.reflection,
                      lineage:Ordered
                  }
    ;   Next = Step.snapshot,
        strange_loop_fingerprint(Next, Fingerprint),
        (   memberchk(Fingerprint, Seen)
        ->  reverse([Step.lineage|Lineage], Ordered),
            Outcome = strange_loop_result{
                          status:bounded,
                          reason:semantic_cycle,
                          iterations:Iteration,
                          snapshot:Snapshot,
                          candidate_snapshot:Next,
                          lineage:Ordered
                      }
        ;   NextIteration is Iteration+1,
            run_loop(NextIteration,
                     MaxIterations,
                     [Fingerprint|Seen],
                     [Step.lineage|Lineage],
                     Next,
                     Hooks,
                     Options,
                     Outcome)
        )
    ).

/* Trusted hooks ------------------------------------------------------- */

normalize_hooks(Hooks0, Hooks) :-
    require_dict(strange_loop_hooks, Hooks0),
    reject_unknown_keys(strange_loop_hooks,
                        Hooks0,
                        [evaluate, propose, verify]),
    require_key(strange_loop_hooks, Hooks0, evaluate, Evaluate),
    require_key(strange_loop_hooks, Hooks0, propose, Propose),
    require_key(strange_loop_hooks, Hooks0, verify, Verify),
    require_callable(evaluate, Evaluate),
    require_callable(propose, Propose),
    require_callable(verify, Verify),
    Hooks = strange_loop_hooks{evaluate:Evaluate,
                               propose:Propose,
                               verify:Verify}.

hook_evaluate(Handler, Snapshot, Evaluation) :-
    catch(( call(Handler, Snapshot, Raw)
          ->  normalize_evaluation(Raw, Evaluation)
          ;   throw(strange_loop_fault(evaluator_failed))
          ),
          Exception,
          rethrow_hook(evaluate, Exception)).

hook_propose(Handler,
             Snapshot,
             Reflection,
             MaxCandidates,
             Candidates) :-
    catch(( call(Handler, Snapshot, Reflection, Raw)
          ->  normalize_candidates(Raw, MaxCandidates, Candidates)
          ;   throw(strange_loop_fault(proposer_failed))
          ),
          Exception,
          rethrow_hook(propose, Exception)).

hook_verify(Handler,
            ParentEval,
            Candidate,
            CandidateSnapshot,
            CandidateEval,
            Verification) :-
    catch(( call(Handler,
                 ParentEval,
                 Candidate,
                 CandidateSnapshot,
                 CandidateEval,
                 Raw)
          ->  normalize_verification(Raw, Verification)
          ;   throw(strange_loop_fault(verifier_failed))
          ),
          Exception,
          rethrow_hook(verify, Exception)).

rethrow_hook(_, strange_loop_fault(Fault)) :-
    !,
    throw(strange_loop_fault(Fault)).
rethrow_hook(Stage, Exception) :-
    safe_exception(Exception, Safe),
    throw(strange_loop_fault(hook_error(Stage, Safe))).

normalize_candidates(Candidates0, MaxCandidates, Candidates) :-
    is_list(Candidates0),
    length(Candidates0, Count),
    Count =< MaxCandidates,
    maplist(normalize_candidate, Candidates0, Candidates),
    findall(Id, (member(Candidate, Candidates), Id=Candidate.id), Ids),
    sort(Ids, Unique),
    length(Ids, N),
    length(Unique, N),
    !.
normalize_candidates(Candidates, _) :-
    throw(strange_loop_fault(invalid_candidates(Candidates))).

normalize_candidate(Candidate0, Candidate) :-
    require_dict(kb_candidate, Candidate0),
    reject_unknown_keys(kb_candidate,
                        Candidate0,
                        [id, strategy, patch, rationale]),
    require_key(kb_candidate, Candidate0, id, Id),
    require_key(kb_candidate, Candidate0, patch, Patch),
    dict_get_default(Candidate0, strategy, unspecified, Strategy),
    dict_get_default(Candidate0, rationale, none, Rationale),
    require_nonempty_atom(candidate_id, Id),
    require_nonempty_atom(strategy, Strategy),
    require_patch(Patch),
    require_safe_data(rationale, Rationale),
    Candidate = kb_candidate{id:Id,
                             strategy:Strategy,
                             patch:Patch,
                             rationale:Rationale}.

normalize_verification(accepted, accepted) :- !.
normalize_verification(accepted(Evidence), accepted(Evidence)) :-
    require_safe_data(verification_evidence, Evidence),
    !.
normalize_verification(rejected(Reason), rejected(Reason)) :-
    require_safe_data(rejection_reason, Reason),
    !.
normalize_verification(Value, _) :-
    throw(strange_loop_fault(invalid_verification(Value))).

/* Options ------------------------------------------------------------- */

normalize_options([], Options) :-
    !,
    default_strange_loop_options(Options).
normalize_options(Options0, Options) :-
    is_dict(Options0),
    !,
    default_strange_loop_options(Default),
    reject_unknown_keys(strange_loop_options,
                        Options0,
                        [max_iterations, max_candidates, min_improvement]),
    dict_get_default(Options0,
                     max_iterations,
                     Default.max_iterations,
                     MaxIterations),
    dict_get_default(Options0,
                     max_candidates,
                     Default.max_candidates,
                     MaxCandidates),
    dict_get_default(Options0,
                     min_improvement,
                     Default.min_improvement,
                     MinImprovement),
    require_positive_integer(max_iterations, MaxIterations),
    require_positive_integer(max_candidates, MaxCandidates),
    require_number(min_improvement, MinImprovement),
    MinImprovement >= 0,
    Options = strange_loop_options{
                  max_iterations:MaxIterations,
                  max_candidates:MaxCandidates,
                  min_improvement:MinImprovement
              }.
normalize_options(Options0, Options) :-
    is_list(Options0),
    !,
    default_strange_loop_options(Default),
    list_option(max_iterations,
                Options0,
                Default.max_iterations,
                MaxIterations),
    list_option(max_candidates,
                Options0,
                Default.max_candidates,
                MaxCandidates),
    list_option(min_improvement,
                Options0,
                Default.min_improvement,
                MinImprovement),
    require_positive_integer(max_iterations, MaxIterations),
    require_positive_integer(max_candidates, MaxCandidates),
    require_number(min_improvement, MinImprovement),
    MinImprovement >= 0,
    Options = strange_loop_options{
                  max_iterations:MaxIterations,
                  max_candidates:MaxCandidates,
                  min_improvement:MinImprovement
              }.
normalize_options(Options, _) :-
    throw(strange_loop_fault(invalid_options(Options))).

list_option(Name, Options, Default, Value) :-
    functor(Term, Name, 1),
    (   memberchk(Term, Options)
    ->  arg(1, Term, Value)
    ;   Value = Default
    ).

/* Shared validation --------------------------------------------------- */

require_dict(_, Value) :-
    is_dict(Value),
    !.
require_dict(Label, Value) :-
    throw(strange_loop_fault(expected_dict(Label, Value))).

require_key(Label, Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(strange_loop_fault(missing_key(Label, Key)))
    ).

dict_get_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   Value = Default
    ).

reject_unknown_keys(Label, Dict, Allowed) :-
    dict_pairs(Dict, _, Pairs),
    pairs_keys(Pairs, Keys),
    (   member(Key, Keys),
        \+ memberchk(Key, Allowed)
    ->  throw(strange_loop_fault(unknown_key(Label, Key)))
    ;   true
    ).

require_nonempty_atom(_, Value) :-
    atom(Value),
    Value \== '',
    !.
require_nonempty_atom(Label, Value) :-
    throw(strange_loop_fault(invalid_atom(Label, Value))).

require_nonnegative_integer(_, Value) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Label, Value) :-
    throw(strange_loop_fault(invalid_nonnegative_integer(Label, Value))).

require_positive_integer(_, Value) :-
    integer(Value),
    Value > 0,
    !.
require_positive_integer(Label, Value) :-
    throw(strange_loop_fault(invalid_positive_integer(Label, Value))).

require_number(_, Value) :-
    number(Value),
    !.
require_number(Label, Value) :-
    throw(strange_loop_fault(invalid_number(Label, Value))).

require_callable(_, Value) :-
    callable(Value),
    !.
require_callable(Label, Value) :-
    throw(strange_loop_fault(invalid_callable(Label, Value))).

require_safe_list(_, Values) :-
    is_list(Values),
    forall(member(Value, Values), safe_data(Value)),
    !.
require_safe_list(Label, Values) :-
    throw(strange_loop_fault(unsafe_list(Label, Values))).

require_safe_data(_, Value) :-
    safe_data(Value),
    !.
require_safe_data(Label, Value) :-
    throw(strange_loop_fault(unsafe_data(Label, Value))).

safe_data(Value) :-
    ground(Value),
    acyclic_term(Value),
    (   atomic(Value)
    ->  true
    ;   is_list(Value)
    ->  forall(member(Item, Value), safe_data(Item))
    ;   is_dict(Value)
    ->  dict_pairs(Value, _, Pairs),
        forall(member(Key-Item, Pairs),
               (atom(Key), safe_data(Item)))
    ;   compound(Value),
        Value =.. [_|Args],
        forall(member(Arg, Args), safe_data(Arg))
    ).

safe_exception(Exception, Safe) :-
    (   safe_data(Exception)
    ->  Safe = Exception
    ;   term_string(Exception, Safe,
                    [quoted(true), max_depth(8)])
    ).

strange_loop_exception(strange_loop_fault(Fault),
                       strange_loop_result{
                           status:error,
                           error:Fault,
                           lineage:[]
                       }) :-
    !.
strange_loop_exception(Exception,
                       strange_loop_result{
                           status:error,
                           error:unexpected(Safe),
                           lineage:[]
                       }) :-
    safe_exception(Exception, Safe).
