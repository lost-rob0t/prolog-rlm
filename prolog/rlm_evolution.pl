:- module(rlm_evolution,
          [ evolution_candidate_validate/3,
            evolution_mutate/5,
            evolution_crossover/6,
            evolution_select/4
          ]).

/** <module> Pure generic configuration-space evolution

Candidates and operators are closed data. The kernel deliberately contains no
scheduler, provider, authority, effect, product, or arbitrary meta-call path.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(rlm_closed_data, []).

evolution_candidate_validate(Candidate0, Constraints0, Outcome) :-
    ( canonical_candidate(Candidate0, Candidate),
      canonical_constraints(Constraints0, Constraints)
    -> validate_genes(Candidate.genes, Constraints.schema, GeneOutcome),
       candidate_validation_outcome(GeneOutcome, Candidate, Outcome)
    ;  Outcome = error(evolution_error{reason:invalid_candidate,
                                       message:"candidate and constraints must be closed dict data"})
    ).

canonical_candidate(Candidate0, Candidate) :-
    catch(rlm_closed_data:closed_data_normalize(Candidate0, Candidate),
          rlm_closed_data_fault(_),
          fail),
    is_dict(Candidate, candidate),
    get_dict(id, Candidate, _),
    get_dict(genes, Candidate, Genes),
    is_dict(Genes),
    ground(Candidate).

canonical_constraints(Constraints0, Constraints) :-
    catch(rlm_closed_data:closed_data_normalize(Constraints0, Constraints),
          rlm_closed_data_fault(_),
          fail),
    is_dict(Constraints, constraints),
    get_dict(schema, Constraints, Schema),
    is_dict(Schema),
    ground(Constraints).

validate_genes(Genes, Schema, Outcome) :-
    dict_pairs(Genes, _, GenePairs),
    dict_pairs(Schema, _, SchemaPairs),
    pairs_keys(GenePairs, GeneKeys),
    pairs_keys(SchemaPairs, SchemaKeys),
    subtract(GeneKeys, SchemaKeys, Unknown),
    ( Unknown = [Key|_]
    -> Outcome = error(evolution_error{reason:unknown_gene,gene:Key})
    ; invalid_gene_value(GenePairs, Schema, Key, Value)
    -> Outcome = error(evolution_error{reason:invalid_gene_value,gene:Key,value:Value})
    ; Outcome = ok
    ).

invalid_gene_value(Pairs, Schema, Key, Value) :-
    member(Key-Value, Pairs),
    get_dict(Key, Schema, Allowed),
    \+ memberchk(Value, Allowed),
    !.

candidate_validation_outcome(ok, Candidate, ok(Candidate)).
candidate_validation_outcome(error(E), _, error(E)).

evolution_mutate(Parent0, Operator, Constraints0, Outcome, Lineage) :-
    evolution_candidate_validate(Parent0, Constraints0, ParentResult),
    mutate_after_parent(ParentResult,
                        Operator,
                        Constraints0,
                        Outcome,
                        Lineage).

mutate_after_parent(error(E), _, _, error(E), none) :- !.
mutate_after_parent(ok(Parent), set(Key, Value), Constraints0,
                    Outcome, Lineage) :-
    !,
    canonical_constraints(Constraints0, Constraints),
    ( get_dict(Key, Constraints.schema, Allowed), memberchk(Value, Allowed)
    -> put_dict(Key, Parent.genes, Value, Genes),
       derived_candidate(mutation,
                         [Parent.id],
                         set(Key,Value),
                         Genes,
                         Child0,
                         Lineage0),
       evolution_candidate_validate(Child0, Constraints, Valid),
       mutation_validation(Valid, Outcome, Lineage0, Lineage)
    ; Outcome = error(evolution_error{reason:invalid_gene_value,
                                      gene:Key,
                                      value:Value}),
      Lineage = none
    ).
mutate_after_parent(ok(_), Operator, _,
                    error(evolution_error{reason:unknown_operator,
                                          operator:Operator}),
                    none).

mutation_validation(ok(Child), Child, Lineage, Lineage).
mutation_validation(error(E), error(E), _, none).

evolution_crossover(Left0, Right0, Operators, Constraints0, Outcome, Lineage) :-
    evolution_candidate_validate(Left0, Constraints0, LV),
    evolution_candidate_validate(Right0, Constraints0, RV),
    crossover_validated(LV,
                        RV,
                        Operators,
                        Constraints0,
                        Outcome,
                        Lineage).

crossover_validated(error(E), _, _, _, error(E), none) :- !.
crossover_validated(_, error(E), _, _, error(E), none) :- !.
crossover_validated(ok(Left), ok(Right), Operators, Constraints0,
                    Outcome, Lineage) :-
    canonical_constraints(Constraints0, Constraints),
    ( crossover_genes(Operators,
                      Left.genes,
                      Right.genes,
                      rlm_anonymous_dict{},
                      Genes)
    -> derived_candidate(crossover,
                         [Left.id,Right.id],
                         Operators,
                         Genes,
                         Child0,
                         Lineage0),
       evolution_candidate_validate(Child0, Constraints, Valid),
       ( Valid = ok(Child)
       -> Outcome = Child,
          Lineage = Lineage0
       ;  Valid = error(E),
          Outcome = error(E),
          Lineage = none
       )
    ; Outcome = error(evolution_error{reason:unknown_operator,
                                      operator:Operators}),
      Lineage = none
    ).

crossover_genes([], _, _, Genes, Genes).
crossover_genes([take(Key,left)|Rest], L, R, Acc, Genes) :-
    get_dict(Key, L, V),
    put_dict(Key, Acc, V, Next),
    crossover_genes(Rest, L, R, Next, Genes).
crossover_genes([take(Key,right)|Rest], L, R, Acc, Genes) :-
    get_dict(Key, R, V),
    put_dict(Key, Acc, V, Next),
    crossover_genes(Rest, L, R, Next, Genes).

derived_candidate(Kind, Parents, Operator, Genes, Child, Lineage) :-
    fingerprint(candidate{genes:Genes,
                          kind:Kind,
                          parents:Parents,
                          operator:Operator},
                Fingerprint),
    atom_concat(evo_, Fingerprint, Id),
    Child = candidate{id:Id, genes:Genes},
    Lineage = lineage{parents:Parents,
                      operator:Operator,
                      fingerprint:Fingerprint}.

fingerprint(Term0, Hash) :-
    rlm_closed_data:closed_data_normalize(Term0, Term),
    term_string(Term,
                Canonical,
                [quoted(true),numbervars(true),ignore_ops(true)]),
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
    Evidence = selection_evidence{policy:pareto,
                                  objectives:Objectives,
                                  selected:Selected}.

dominates(A, B, Objectives) :-
    maplist(not_worse(A,B), Objectives),
    member(Objective, Objectives),
    strictly_better(A,B,Objective),
    !.

not_worse(A, B, objective(Key,max)) :-
    get_dict(Key,A,AV), get_dict(Key,B,BV), AV >= BV.
not_worse(A, B, objective(Key,min)) :-
    get_dict(Key,A,AV), get_dict(Key,B,BV), AV =< BV.
strictly_better(A, B, objective(Key,max)) :-
    get_dict(Key,A,AV), get_dict(Key,B,BV), AV > BV.
strictly_better(A, B, objective(Key,min)) :-
    get_dict(Key,A,AV), get_dict(Key,B,BV), AV < BV.
