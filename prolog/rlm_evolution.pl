:- module(rlm_evolution,
          [ evolution_candidate_validate/3,
            evolution_mutate/5,
            evolution_crossover/6,
            evolution_select/4,
            evolution_evaluator_register/2,
            evolution_evaluator_unregister/1,
            evolution_evaluate_async/5,
            evolution_evaluate/5
          ]).

/** <module> Generic configuration-space evolution

Candidates and operators are closed data. Latency-bearing evaluation composes
with the existing bounded Future runtime. Evaluators are trusted, code-owned
registrations selected by a closed evaluator id; candidate/model data never
becomes a callable or a second scheduler.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(rlm_async).

:- dynamic evolution_evaluator/2.

:- meta_predicate evolution_evaluator_register(+, 3).

evolution_candidate_validate(Candidate, Constraints, Outcome) :-
    ( valid_candidate_shape(Candidate), valid_constraints(Constraints)
    -> validate_genes(Candidate.genes, Constraints.schema, GeneOutcome),
       candidate_validation_outcome(GeneOutcome, Candidate, Outcome)
    ;  Outcome = error(evolution_error{reason:invalid_candidate,
                                       message:"candidate and constraints must be closed dict data"})
    ).

valid_candidate_shape(C) :-
    is_dict(C, candidate), ground(C), get_dict(id, C, _), get_dict(genes, C, G), is_dict(G).
valid_constraints(C) :-
    is_dict(C, constraints), ground(C), get_dict(schema, C, S), is_dict(S).

validate_genes(Genes, Schema, Outcome) :-
    dict_pairs(Genes, _, GenePairs),
    dict_pairs(Schema, _, SchemaPairs),
    pairs_keys(GenePairs, GeneKeys), pairs_keys(SchemaPairs, SchemaKeys),
    subtract(GeneKeys, SchemaKeys, Unknown),
    ( Unknown = [Key|_]
    -> Outcome = error(evolution_error{reason:unknown_gene,gene:Key})
    ; invalid_gene_value(GenePairs, Schema, Key, Value)
    -> Outcome = error(evolution_error{reason:invalid_gene_value,gene:Key,value:Value})
    ; Outcome = ok
    ).

invalid_gene_value(Pairs, Schema, Key, Value) :-
    member(Key-Value, Pairs), get_dict(Key, Schema, Allowed), \+ memberchk(Value, Allowed), !.

candidate_validation_outcome(ok, Candidate, ok(Candidate)).
candidate_validation_outcome(error(E), _, error(E)).

evolution_mutate(Parent, Operator, Constraints, Outcome, Lineage) :-
    evolution_candidate_validate(Parent, Constraints, ParentResult),
    mutate_after_parent(ParentResult, Parent, Operator, Constraints, Outcome, Lineage).

mutate_after_parent(error(E), _, _, _, error(E), none) :- !.
mutate_after_parent(ok(_), Parent, set(Key, Value), Constraints, Outcome, Lineage) :-
    !,
    ( get_dict(Key, Constraints.schema, Allowed), memberchk(Value, Allowed)
    -> put_dict(Key, Parent.genes, Value, Genes),
       derived_candidate(mutation, [Parent.id], set(Key,Value), Genes, Child, Lineage),
       evolution_candidate_validate(Child, Constraints, Valid),
       mutation_validation(Valid, Child, Outcome, Lineage)
    ; Outcome = error(evolution_error{reason:invalid_gene_value,gene:Key,value:Value}), Lineage = none
    ).
mutate_after_parent(ok(_), _, Operator, _, error(evolution_error{reason:unknown_operator,operator:Operator}), none).

mutation_validation(ok(_), Child, Child, _).
mutation_validation(error(E), _, error(E), _).

evolution_crossover(Left, Right, Operators, Constraints, Outcome, Lineage) :-
    evolution_candidate_validate(Left, Constraints, LV),
    evolution_candidate_validate(Right, Constraints, RV),
    crossover_validated(LV, RV, Left, Right, Operators, Constraints, Outcome, Lineage).

crossover_validated(error(E), _, _, _, _, _, error(E), none) :- !.
crossover_validated(_, error(E), _, _, _, _, error(E), none) :- !.
crossover_validated(ok(_), ok(_), Left, Right, Operators, Constraints, Outcome, Lineage) :-
    ( crossover_genes(Operators, Left.genes, Right.genes, _{}, Genes)
    -> derived_candidate(crossover, [Left.id,Right.id], Operators, Genes, Child, Lineage0),
       evolution_candidate_validate(Child, Constraints, Valid),
       ( Valid = ok(_) -> Outcome = Child, Lineage = Lineage0
       ; Valid = error(E), Outcome = error(E), Lineage = none )
    ; Outcome = error(evolution_error{reason:unknown_operator,operator:Operators}), Lineage = none
    ).

crossover_genes([], _, _, Genes, Genes).
crossover_genes([take(Key,left)|Rest], L, R, Acc, Genes) :-
    get_dict(Key, L, V), put_dict(Key, Acc, V, Next), crossover_genes(Rest, L, R, Next, Genes).
crossover_genes([take(Key,right)|Rest], L, R, Acc, Genes) :-
    get_dict(Key, R, V), put_dict(Key, Acc, V, Next), crossover_genes(Rest, L, R, Next, Genes).

derived_candidate(Kind, Parents, Operator, Genes, Child, Lineage) :-
    fingerprint(candidate{genes:Genes,kind:Kind,parents:Parents,operator:Operator}, Fingerprint),
    atom_concat(evo_, Fingerprint, Id),
    Child = candidate{id:Id, genes:Genes},
    Lineage = lineage{parents:Parents,operator:Operator,fingerprint:Fingerprint}.

fingerprint(Term, Hash) :-
    term_string(Term, Canonical, [quoted(true),numbervars(true)]),
    crypto_data_hash(Canonical, Hash, [algorithm(sha256)]).

evolution_select(Fitness, Policy, Selected, Evidence) :-
    Objectives = Policy.objectives,
    findall(Id,
            ( member(F, Fitness), Id = F.candidate,
              \+ ( member(Other, Fitness), Other.candidate \== Id,
                   dominates(Other.objectives, F.objectives, Objectives) )
            ),
            Ids0),
    sort(Ids0, Selected),
    Evidence = selection_evidence{policy:pareto,objectives:Objectives,selected:Selected}.

dominates(A, B, Objectives) :-
    maplist(not_worse(A,B), Objectives),
    member(Objective, Objectives), strictly_better(A,B,Objective), !.

not_worse(A, B, objective(Key,max)) :- get_dict(Key,A,AV), get_dict(Key,B,BV), AV >= BV.
not_worse(A, B, objective(Key,min)) :- get_dict(Key,A,AV), get_dict(Key,B,BV), AV =< BV.
strictly_better(A, B, objective(Key,max)) :- get_dict(Key,A,AV), get_dict(Key,B,BV), AV > BV.
strictly_better(A, B, objective(Key,min)) :- get_dict(Key,A,AV), get_dict(Key,B,BV), AV < BV.

/* Evaluator integration -------------------------------------------------- */

%% evolution_evaluator_register(+Id, :Evaluator) is det.
%
% Trusted host/library registration. Evaluator is called as
% call(Evaluator, Candidate, Context, RawOutcome). The callable is retained only
% in the trusted registry; candidates and contexts can select Id but can never
% supply executable terms.
evolution_evaluator_register(Id, Evaluator) :-
    must_be(atom, Id),
    must_be(callable, Evaluator),
    with_mutex(rlm_evolution_evaluators,
               register_evaluator_locked(Id, Evaluator)).

register_evaluator_locked(Id, Evaluator) :-
    retractall(evolution_evaluator(Id, _)),
    assertz(evolution_evaluator(Id, Evaluator)).

evolution_evaluator_unregister(Id) :-
    must_be(atom, Id),
    with_mutex(rlm_evolution_evaluators,
               retractall(evolution_evaluator(Id, _))).

%% evolution_evaluate_async(+Candidate,+Constraints,+EvaluatorId,+Context,-FutureOrError) is det.
%
% Validate before admission, resolve only a trusted code-owned evaluator id,
% then submit one canonical evaluation operation to rlm_async. Cancellation,
% bounded worker/backlog semantics, parent Future lineage and cleanup therefore
% remain owned by the existing runtime.
evolution_evaluate_async(Candidate, Constraints, EvaluatorId, Context, Result) :-
    evolution_candidate_validate(Candidate, Constraints, Validation),
    evaluate_validated_async(Validation, Candidate, EvaluatorId, Context, Result).

evaluate_validated_async(error(E), _, _, _, error(E)) :- !.
evaluate_validated_async(ok(_), Candidate, EvaluatorId, Context, Result) :-
    ( atom(EvaluatorId), evolution_evaluator(EvaluatorId, Evaluator)
    -> Metadata = async_metadata{operation:evolution_evaluate,
                                 candidate:Candidate.id,
                                 evaluator:EvaluatorId},
       rlm_async_submit(run_evaluator(EvaluatorId, Evaluator, Candidate, Context),
                        Metadata,
                        Result)
    ; Result = error(evolution_error{reason:unknown_evaluator,evaluator:EvaluatorId})
    ).

%% evolution_evaluate(+Candidate,+Constraints,+EvaluatorId,+Context,-Outcome) is det.
%
% Synchronous convenience facade over the exact async operation.
evolution_evaluate(Candidate, Constraints, EvaluatorId, Context, Outcome) :-
    evolution_evaluate_async(Candidate, Constraints, EvaluatorId, Context, Submitted),
    ( Submitted = rlm_future(_)
    -> rlm_future_await(Submitted, Outcome)
    ; Outcome = Submitted
    ).

run_evaluator(EvaluatorId, Evaluator, Candidate, Context, Outcome) :-
    catch(call(Evaluator, Candidate, Context, Raw),
          Exception,
          Raw = evaluator_exception(Exception)),
    normalize_evaluation(EvaluatorId, Candidate, Raw, Outcome).

normalize_evaluation(EvaluatorId, Candidate, evaluator_exception(Exception), Outcome) :-
    !,
    Outcome = evaluation_result{status:error,
                                candidate:Candidate.id,
                                evaluator:EvaluatorId,
                                reason:evaluator_exception(Exception)}.
normalize_evaluation(EvaluatorId, Candidate, Raw, Outcome) :-
    ( is_dict(Raw, evaluation),
      get_dict(objectives, Raw, Objectives), is_dict(Objectives), ground(Objectives),
      get_dict(evidence, Raw, Evidence), ground(Evidence),
      get_dict(usage, Raw, Usage), ground(Usage)
    -> Outcome = evaluation_result{status:passed,
                                   candidate:Candidate.id,
                                   evaluator:EvaluatorId,
                                   objectives:Objectives,
                                   evidence:Evidence,
                                   usage:Usage}
    ; Outcome = evaluation_result{status:error,
                                  candidate:Candidate.id,
                                  evaluator:EvaluatorId,
                                  reason:invalid_evaluator_outcome}
    ).
