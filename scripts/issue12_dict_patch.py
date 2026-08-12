from pathlib import Path

path = Path('prolog/rlm_graph.pl')
text = path.read_text()

replacements = [
('''validate_schema(Schema) :-
    findall(Key, member(state_field{key:Key}, Schema), Keys),
    require_unique(Keys, state_field).

validate_nodes(Nodes, Registry) :-
    findall(Name, member(graph_node{name:Name}, Nodes), Names),
    require_unique(Names, node),
    maplist(validate_node_registry(Registry), Nodes).

validate_node_registry(Registry, graph_node{kind:action, ref:Ref}) :-
    !,
    require_registry(Registry, handler, Ref, _).
validate_node_registry(Registry, graph_node{kind:subgraph, ref:Ref}) :-
    require_registry(Registry, subgraph, Ref, _).
''', '''validate_schema(Schema) :-
    findall(Key,
            ( member(Field, Schema),
              get_dict(key, Field, Key)
            ),
            Keys),
    require_unique(Keys, state_field).

validate_nodes(Nodes, Registry) :-
    findall(Name,
            ( member(Node, Nodes),
              get_dict(name, Node, Name)
            ),
            Names),
    require_unique(Names, node),
    maplist(validate_node_registry(Registry), Nodes).

validate_node_registry(Registry, Node) :-
    get_dict(kind, Node, action),
    !,
    get_dict(ref, Node, Ref),
    require_registry(Registry, handler, Ref, _).
validate_node_registry(Registry, Node) :-
    get_dict(kind, Node, subgraph),
    get_dict(ref, Node, Ref),
    require_registry(Registry, subgraph, Ref, _).
'''),
('''    findall(Key, member(route{key:Key}, Routes), Keys),
    require_unique(Keys, route_key(From)),
    forall(member(route{target:Target}, Routes),
           validate_target(Target, Names)).
''', '''    findall(Key,
            ( member(Route, Routes),
              get_dict(key, Route, Key)
            ),
            Keys),
    require_unique(Keys, route_key(From)),
    forall(( member(Route, Routes),
             get_dict(target, Route, Target)
           ),
           validate_target(Target, Names)).
'''),
('''execute_node(graph_node{kind:action, ref:Ref},
             Compiled, _, Token, State, Context, Outcome) :-
    !,
    require_registry(Compiled.registry, handler, Ref, Handler),
''', '''execute_node(Node,
             Compiled, _, Token, State, Context, Outcome) :-
    get_dict(kind, Node, action),
    !,
    get_dict(ref, Node, Ref),
    require_registry(Compiled.registry, handler, Ref, Handler),
'''),
('''execute_node(graph_node{kind:subgraph, ref:Ref},
             Compiled, Config, Token, State, Context, Outcome) :-
    require_registry(Compiled.registry, subgraph, Ref, Subgraph),
''', '''execute_node(Node,
             Compiled, Config, Token, State, Context, Outcome) :-
    get_dict(kind, Node, subgraph),
    get_dict(ref, Node, Ref),
    require_registry(Compiled.registry, subgraph, Ref, Subgraph),
'''),
('''select_edge_target(graph_edge{kind:fixed, to:Target}, _, _, _, _, ok(Target)) :-
    !.
select_edge_target(graph_edge{kind:conditional,
                              router:Router,
                              routes:Routes},
                   Registry, _, Token, State, Outcome) :-
    require_registry(Registry, router, Router, Handler),
''', '''select_edge_target(Edge, _, _, _, _, ok(Target)) :-
    get_dict(kind, Edge, fixed),
    !,
    get_dict(to, Edge, Target).
select_edge_target(Edge, Registry, _, Token, State, Outcome) :-
    get_dict(kind, Edge, conditional),
    get_dict(router, Edge, Router),
    get_dict(routes, Edge, Routes),
    require_registry(Registry, router, Router, Handler),
'''),
('''schema_defaults(Schema, State) :-
    findall(Key-Default,
            member(state_field{key:Key, default:Default}, Schema),
            Pairs),
    dict_pairs(State, graph_state, Pairs).
''', '''schema_defaults(Schema, State) :-
    findall(Key-Default,
            ( member(Field, Schema),
              get_dict(key, Field, Key),
              get_dict(default, Field, Default)
            ),
            Pairs),
    dict_pairs(State, graph_state, Pairs).
'''),
('''edge_targets_(graph_edge{kind:fixed, to:Target}, [Target]) :- !.
edge_targets_(graph_edge{kind:conditional, routes:Routes}, Targets) :-
    findall(Target, member(route{target:Target}, Routes), Targets).

node_names(Nodes, Names) :-
    findall(Name, member(graph_node{name:Name}, Nodes), Names).
''', '''edge_targets_(Edge, [Target]) :-
    get_dict(kind, Edge, fixed),
    !,
    get_dict(to, Edge, Target).
edge_targets_(Edge, Targets) :-
    get_dict(kind, Edge, conditional),
    get_dict(routes, Edge, Routes),
    findall(Target,
            ( member(Route, Routes),
              get_dict(target, Route, Target)
            ),
            Targets).

node_names(Nodes, Names) :-
    findall(Name,
            ( member(Node, Nodes),
              get_dict(name, Node, Name)
            ),
            Names).
'''),
('''start_target(Edges, Target) :-
    member(Edge, Edges),
    Edge.from == start,
    !,
    Edge = graph_edge{kind:fixed, to:Target}.
''', '''start_target(Edges, Target) :-
    member(Edge, Edges),
    Edge.from == start,
    get_dict(kind, Edge, fixed),
    !,
    get_dict(to, Edge, Target).
''')
]

for old, new in replacements:
    if text.count(old) != 1:
        raise SystemExit(f'expected exactly one match: {old[:80]!r}')
    text = text.replace(old, new, 1)

path.write_text(text)
print('issue12 dict hardening applied')
