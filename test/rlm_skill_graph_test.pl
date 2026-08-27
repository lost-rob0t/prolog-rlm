:- begin_tests(rlm_skill_graph).

:- use_module('../prolog/rlm_skill_graph').

skill_fixture(Name, Skill) :-
    skill_fixture(Name, [], [], [], [], Skill).

skill_fixture(Name, Requires, Suggests, Conflicts, Supersedes,
              skill{
                  name:Name,
                  description:"graph fixture",
                  invocation:automatic,
                  source:test,
                  root:'/definitely/not/read',
                  directory:'/definitely/not/read',
                  relative_directory:Name,
                  category:test,
                  instruction_file:'/definitely/not/read/SKILL.md',
                  instruction_sha256:unused,
                  resources:[],
                  aliases:[],
                  triggers:[],
                  requires:Requires,
                  suggests:Suggests,
                  conflicts:Conflicts,
                  supersedes:Supersedes,
                  requires_capability:none,
                  priority:100,
                  fingerprint:Name,
                  estimated_tokens:1
              }).

catalog(Skills,
        skill_catalog{
            roots:[],
            skills:Skills,
            fingerprint:test_catalog
        }).

test(standard_skill_projects_to_isolated_inert_node) :-
    skill_fixture(alpha, Skill),
    catalog([Skill], Catalog),
    skill_catalog_graph(Catalog, ok(Graph)),
    assertion(Graph.edges == []),
    assertion(Graph.diagnostics == []),
    Graph.nodes = [Node],
    assertion(Node.unit == skill(alpha)),
    assertion(Node.category == test),
    assertion(Node.invocation == automatic),
    assertion(Node.source == test),
    assertion(atomic(Graph.fingerprint)),
    assertion(\+ get_dict(content, Node, _)),
    assertion(\+ get_dict(instruction_file, Node, _)).

test(graph_derives_typed_edges_without_loading_bodies) :-
    skill_fixture(alpha,
                  [skill(beta), tool(git_diff)],
                  [skill(missing_soft)],
                  [skill(gamma)],
                  [resource(old_rules)],
                  Alpha),
    skill_fixture(beta, Beta),
    skill_fixture(gamma, Gamma),
    catalog([Gamma, Alpha, Beta], Catalog),
    skill_catalog_graph(Catalog, ok(Graph)),
    assertion(memberchk(skill_graph_edge{kind:requires,
                                         from:skill(alpha),
                                         to:skill(beta)},
                        Graph.edges)),
    assertion(memberchk(skill_graph_edge{kind:requires,
                                         from:skill(alpha),
                                         to:tool(git_diff)},
                        Graph.edges)),
    assertion(memberchk(skill_graph_edge{kind:conflicts,
                                         from:skill(alpha),
                                         to:skill(gamma)},
                        Graph.edges)),
    assertion(memberchk(skill_graph_diagnostic{kind:unresolved_target,
                                               relation:suggests,
                                               from:skill(alpha),
                                               target:skill(missing_soft)},
                        Graph.diagnostics)),
    assertion(memberchk(skill_graph_diagnostic{kind:external_target,
                                               relation:requires,
                                               from:skill(alpha),
                                               target:tool(git_diff)},
                        Graph.diagnostics)),
    assertion(memberchk(skill_graph_diagnostic{kind:external_target,
                                               relation:supersedes,
                                               from:skill(alpha),
                                               target:resource(old_rules)},
                        Graph.diagnostics)).

test(conflict_semantics_are_canonical_and_symmetric) :-
    skill_fixture(alpha, [], [], [skill(beta)], [], Alpha),
    skill_fixture(beta, [], [], [skill(alpha)], [], Beta),
    catalog([Beta, Alpha], Catalog),
    skill_catalog_graph(Catalog, ok(Graph)),
    findall(Edge,
            ( member(Edge, Graph.edges),
              Edge.kind == conflicts
            ),
            Conflicts),
    assertion(Conflicts ==
              [skill_graph_edge{kind:conflicts,
                                from:skill(alpha),
                                to:skill(beta)}]).

test(self_requirement_is_structurally_rejected) :-
    skill_fixture(alpha, [skill(alpha)], [], [], [], Alpha),
    catalog([Alpha], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.phase == graph),
    assertion(Error.detail == self_relation(requires, skill(alpha))).

test(hard_skill_requirement_cycle_is_structurally_rejected) :-
    skill_fixture(alpha, [skill(beta)], [], [], [], Alpha),
    skill_fixture(beta, [skill(gamma)], [], [], [], Beta),
    skill_fixture(gamma, [skill(alpha)], [], [], [], Gamma),
    catalog([Gamma, Beta, Alpha], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.detail == cycle(requires,
                                    [alpha,beta,gamma,alpha])).

test(supersession_cycle_is_structurally_rejected) :-
    skill_fixture(alpha, [], [], [], [skill(beta)], Alpha),
    skill_fixture(beta, [], [], [], [skill(alpha)], Beta),
    catalog([Alpha, Beta], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.detail == cycle(supersedes,
                                    [alpha,beta,alpha])).

test(requires_conflicts_contradiction_is_rejected) :-
    skill_fixture(alpha,
                  [skill(beta)],
                  [],
                  [skill(beta)],
                  [],
                  Alpha),
    skill_fixture(beta, Beta),
    catalog([Alpha, Beta], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.detail ==
              contradiction(requires_conflicts,
                            skill(alpha),
                            [skill(beta)])).

test(requires_supersedes_contradiction_is_rejected) :-
    skill_fixture(alpha,
                  [skill(beta)],
                  [],
                  [],
                  [skill(beta)],
                  Alpha),
    skill_fixture(beta, Beta),
    catalog([Alpha, Beta], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.detail ==
              contradiction(requires_supersedes,
                            skill(alpha),
                            [skill(beta)])).

test(unresolved_hard_skill_requirement_is_rejected) :-
    skill_fixture(alpha, [skill(missing)], [], [], [], Alpha),
    catalog([Alpha], Catalog),
    skill_catalog_graph(Catalog, error(Error)),
    assertion(Error.detail ==
              unresolved_required_skill(skill(alpha), skill(missing))).

test(graph_projection_is_deterministic_across_catalog_order) :-
    skill_fixture(alpha, [], [skill(beta)], [], [], Alpha),
    skill_fixture(beta, Beta),
    catalog([Alpha, Beta], CatalogAB),
    catalog([Beta, Alpha], CatalogBA),
    skill_catalog_graph(CatalogAB, ok(GraphAB)),
    skill_catalog_graph(CatalogBA, ok(GraphBA)),
    assertion(GraphAB == GraphBA).

test(graph_output_is_ground_closed_metadata) :-
    skill_fixture(alpha, [], [], [], [], Alpha),
    catalog([Alpha], Catalog),
    skill_catalog_graph(Catalog, ok(Graph)),
    assertion(ground(Graph)),
    assertion(\+ sub_term(call(_), Graph)).

:- end_tests(rlm_skill_graph).
