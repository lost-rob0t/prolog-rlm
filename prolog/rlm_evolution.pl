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
