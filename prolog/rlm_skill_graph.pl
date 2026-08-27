:- module(rlm_skill_graph,
          [ rlm_skill_graph_ready/0,
            skill_catalog_graph/2
          ]).

/** <module> Read-only normalized skill catalog graph

Projects the already-normalized `rlm_skill` catalog metadata into a bounded,
inspectable dependency graph.  This module never reads skill bodies/resources,
selects prompt units, grants capability/authority, or executes metadata.
*/

:- use_module(library(crypto)).
:- use_module(library(lists)).
:- use_module(rlm_skill, [skill_catalog_skills/2]).

rlm_skill_graph_ready.

skill_catalog_graph(Catalog, Outcome) :-
    catch(( skill_catalog_skills(Catalog, Skills),
            skill_graph(Skills, Graph),
            Outcome = ok(Graph)
          ),
          Exception,
          skill_graph_exception(Exception, Outcome)),
    !.

skill_graph(Skills, Graph) :-
    validate_skills(Skills),
    maplist(skill_graph_node, Skills, Nodes0),
    sort(Nodes0, Nodes),
    graph_edges(Skills, Edges),
    validate_graph(Skills, Edges),
    graph_diagnostics(Skills, Diagnostics0),
    sort(Diagnostics0, Diagnostics),
    graph_fingerprint(Nodes, Edges, Diagnostics, Fingerprint),
    Graph = skill_graph{
                nodes:Nodes,
                edges:Edges,
                diagnostics:Diagnostics,
                fingerprint:Fingerprint
            }.

validate_skills([]).
validate_skills([Skill|Skills]) :-
    require_skill_record(Skill),
    validate_skills(Skills).

require_skill_record(Skill) :-
    is_dict(Skill, skill),
    atom(Skill.name),
    atom(Skill.category),
    atom(Skill.invocation),
    ground(Skill.source),
    ground(Skill.root),
    ground(Skill.relative_directory),
    ground(Skill.fingerprint),
    is_list(Skill.requires),
    is_list(Skill.suggests),
    is_list(Skill.conflicts),
    is_list(Skill.supersedes),
    ground(Skill.requires),
    ground(Skill.suggests),
    ground(Skill.conflicts),
    ground(Skill.supersedes),
    !.
require_skill_record(Skill) :-
    throw(skill_graph_fault(invalid_normalized_skill(Skill))).

skill_graph_node(Skill,
                 skill_graph_node{
                     unit:skill(Skill.name),
                     category:Skill.category,
                     invocation:Skill.invocation,
                     source:Skill.source,
                     root:Skill.root,
                     relative_directory:Skill.relative_directory,
                     fingerprint:Skill.fingerprint
                 }).

graph_edges(Skills, Edges) :-
    findall(Edge,
            ( member(Skill, Skills),
              skill_relation_edge(Skill, Edge)
            ),
            Edges0),
    sort(Edges0, Edges).

skill_relation_edge(Skill, Edge) :-
    member(Target, Skill.requires),
    directed_edge(requires, Skill.name, Target, Edge).
skill_relation_edge(Skill, Edge) :-
    member(Target, Skill.suggests),
    directed_edge(suggests, Skill.name, Target, Edge).
skill_relation_edge(Skill, Edge) :-
    member(Target, Skill.supersedes),
    directed_edge(supersedes, Skill.name, Target, Edge).
skill_relation_edge(Skill,
                    skill_graph_edge{kind:conflicts, from:From, to:To}) :-
    member(Target, Skill.conflicts),
    canonical_pair(skill(Skill.name), Target, From, To).

directed_edge(Kind, Name, Target,
              skill_graph_edge{kind:Kind, from:skill(Name), to:Target}).

canonical_pair(A, B, A, B) :-
    A @=< B,
    !.
canonical_pair(A, B, B, A).

validate_graph(Skills, Edges) :-
    skill_names(Skills, Names),
    validate_self_relations(Skills),
    validate_relation_contradictions(Skills),
    validate_hard_skill_dependencies(Skills, Names),
    validate_relation_cycles(requires, Edges),
    validate_relation_cycles(supersedes, Edges).

skill_names(Skills, Names) :-
    findall(Name, (member(Skill, Skills), Name = Skill.name), Names0),
    sort(Names0, Names).

validate_self_relations([]).
validate_self_relations([Skill|Skills]) :-
    Self = skill(Skill.name),
    reject_self_relation(requires, Skill.name, Self, Skill.requires),
    reject_self_relation(conflicts, Skill.name, Self, Skill.conflicts),
    reject_self_relation(supersedes, Skill.name, Self, Skill.supersedes),
    validate_self_relations(Skills).

reject_self_relation(Kind, Name, Self, Targets) :-
    (   memberchk(Self, Targets)
    ->  throw(skill_graph_fault(self_relation(Kind, skill(Name))))
    ;   true
    ).

validate_relation_contradictions([]).
validate_relation_contradictions([Skill|Skills]) :-
    relation_overlap(Skill.requires, Skill.conflicts, RequiresConflicts),
    reject_overlap(requires_conflicts, Skill.name, RequiresConflicts),
    relation_overlap(Skill.requires, Skill.supersedes, RequiresSupersedes),
    reject_overlap(requires_supersedes, Skill.name, RequiresSupersedes),
    validate_relation_contradictions(Skills).

relation_overlap(A, B, Overlap) :-
    intersection(A, B, Values0),
    sort(Values0, Overlap).

reject_overlap(_, _, []) :- !.
reject_overlap(Kind, Name, Targets) :-
    throw(skill_graph_fault(contradiction(Kind, skill(Name), Targets))).

validate_hard_skill_dependencies([], _).
validate_hard_skill_dependencies([Skill|Skills], Names) :-
    forall(member(Target, Skill.requires),
           validate_hard_target(Skill.name, Target, Names)),
    validate_hard_skill_dependencies(Skills, Names).

validate_hard_target(From, skill(Target), Names) :-
    !,
    (   memberchk(Target, Names)
    ->  true
    ;   throw(skill_graph_fault(
                  unresolved_required_skill(skill(From), skill(Target))))
    ).
validate_hard_target(_, _, _).

validate_relation_cycles(Kind, Edges) :-
    relation_skill_pairs(Kind, Edges, Pairs),
    (   directed_cycle(Pairs, Cycle)
    ->  throw(skill_graph_fault(cycle(Kind, Cycle)))
    ;   true
    ).

relation_skill_pairs(Kind, Edges, Pairs) :-
    findall(From-To,
            ( member(Edge, Edges),
              Edge.kind == Kind,
              Edge.from = skill(From),
              Edge.to = skill(To)
            ),
            Pairs0),
    sort(Pairs0, Pairs).

directed_cycle(Pairs, Cycle) :-
    findall(Vertex,
            ( member(A-B, Pairs),
              ( Vertex = A ; Vertex = B )
            ),
            Vertices0),
    sort(Vertices0, Vertices),
    member(Start, Vertices),
    cycle_path(Start, Start, Pairs, [Start], ReverseCycle),
    reverse(ReverseCycle, Cycle),
    !.

cycle_path(Start, Current, Edges, Visited, [Start|Visited]) :-
    memberchk(Current-Start, Edges),
    !.
cycle_path(Start, Current, Edges, Visited, Cycle) :-
    member(Current-Next, Edges),
    Next \== Start,
    \+ memberchk(Next, Visited),
    cycle_path(Start, Next, Edges, [Next|Visited], Cycle).

graph_diagnostics(Skills, Diagnostics) :-
    skill_names(Skills, Names),
    findall(Diagnostic,
            ( member(Skill, Skills),
              diagnostic_relation(Skill, Kind, Target),
              unresolved_diagnostic(Names,
                                    Kind,
                                    Skill.name,
                                    Target,
                                    Diagnostic)
            ),
            Diagnostics).

diagnostic_relation(Skill, suggests, Target) :-
    member(Target, Skill.suggests).
diagnostic_relation(Skill, conflicts, Target) :-
    member(Target, Skill.conflicts).
diagnostic_relation(Skill, supersedes, Target) :-
    member(Target, Skill.supersedes).
diagnostic_relation(Skill, requires, Target) :-
    member(Target, Skill.requires),
    Target \= skill(_).

unresolved_diagnostic(Names, _, _, skill(Target), _) :-
    memberchk(Target, Names),
    !,
    fail.
unresolved_diagnostic(_, Kind, From, skill(Target),
                      skill_graph_diagnostic{
                          kind:unresolved_target,
                          relation:Kind,
                          from:skill(From),
                          target:skill(Target)
                      }).
unresolved_diagnostic(_, Kind, From, Target,
                      skill_graph_diagnostic{
                          kind:external_target,
                          relation:Kind,
                          from:skill(From),
                          target:Target
                      }).

graph_fingerprint(Nodes, Edges, Diagnostics, Fingerprint) :-
    Material = skill_graph_material(Nodes, Edges, Diagnostics),
    term_string(Material,
                Text,
                [ quoted(true),
                  numbervars(true),
                  ignore_ops(true)
                ]),
    crypto_data_hash(Text,
                     Hash,
                     [ algorithm(sha256),
                       encoding(utf8)
                     ]),
    atom_concat(skill_graph_, Hash, Fingerprint).

skill_graph_exception(skill_graph_fault(Detail),
                      error(skill_graph_error{
                                phase:graph,
                                kind:skill_graph_fault,
                                detail:Detail,
                                message:"skill graph rejected"
                            })) :-
    !.
skill_graph_exception(Exception,
                      error(skill_graph_error{
                                phase:graph,
                                kind:exception,
                                exception:Safe,
                                message:"skill graph failed"
                            })) :-
    catch(term_string(Exception,
                      Safe,
                      [ quoted(true),
                        numbervars(true),
                        max_depth(8)
                      ]),
          _,
          Safe = "<unprintable exception>").
