:- module(rlm_graph,
          [ rlm_graph_ready/0,
            default_graph_options/1,
            graph_compile/4,
            graph_backend_open/2,
            graph_backend_close/1,
            graph_run/4,
            graph_resume/6,
            graph_checkpoint/3,
            graph_history/3,
            graph_cancellation_token/1,
            graph_cancel/1
          ]).

/** <module> Validated, durable graph orchestration

Graph specifications are declarative.  They contain node/router/subgraph IDs,
never executable model-provided callables.  Trusted host code supplies a
separate registry that resolves those IDs to closures or compiled subgraphs.

Execution is bounded by wall time, total node steps and per-node visits.  State
updates pass through a declared schema and closed reducer vocabulary.  Optional
memory and SWI persistency backends store serializable checkpoints and ordered
execution events for interrupt/resume and history inspection.
*/

:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(ordsets)).
:- use_module(library(time)).
:- use_module(library(uuid)).
:- use_module(rlm_graph_persist).

:- dynamic graph_memory_backend/1.
:- dynamic graph_memory_checkpoint/4.
:- dynamic graph_memory_event/4.
:- dynamic graph_cancel_state/2.
:- dynamic graph_cancel_thread/2.

rlm_graph_ready.

default_graph_options(
    graph_options{max_steps:128,
                  max_visits_per_node:32,
                  time_limit:30.0,
                  backend:none,
                  event_handler:none,
                  cancellation_token:none,
                  run_id:auto}).

/* -------------------------------------------------------------------------
 * Compilation
 * ---------------------------------------------------------------------- */

graph_compile(Spec0, Registry0, Options, Outcome) :-
    catch(graph_compile_(Spec0, Registry0, Options, Outcome),
          Exception,
          graph_compile_exception(Exception, Outcome)).

graph_compile_(Spec0, Registry0, Options, ok(Compiled)) :-
    require_options(Options),
    normalize_graph_spec(Spec0, Spec),
    normalize_registry(Registry0, Registry),
    validate_schema(Spec.schema),
    validate_nodes(Spec.nodes, Registry),
    validate_edges(Spec.nodes, Spec.edges, Registry),
    validate_reachability(Spec.nodes, Spec.edges),
    Compiled = compiled_graph{
                   kind:rlm_graph,
                   id:Spec.id,
                   schema:Spec.schema,
                   nodes:Spec.nodes,
                   edges:Spec.edges,
                   registry:Registry
               }.

normalize_graph_spec(graph(Id0, Schema0, Nodes0, Edges0), Spec) :-
    !,
    normalize_id(Id0, Id),
    normalize_schema(Schema0, Schema),
    normalize_nodes(Nodes0, Nodes),
    normalize_edges(Edges0, Edges),
    Spec = graph_spec{id:Id,
                      schema:Schema,
                      nodes:Nodes,
                      edges:Edges}.
normalize_graph_spec(Spec0, Spec) :-
    is_dict(Spec0),
    !,
    require_dict_key(Spec0, id, Id0),
    require_dict_key(Spec0, schema, Schema0),
    require_dict_key(Spec0, nodes, Nodes0),
    require_dict_key(Spec0, edges, Edges0),
    normalize_id(Id0, Id),
    normalize_schema(Schema0, Schema),
    normalize_nodes(Nodes0, Nodes),
    normalize_edges(Edges0, Edges),
    Spec = graph_spec{id:Id,
                      schema:Schema,
                      nodes:Nodes,
                      edges:Edges}.
normalize_graph_spec(Spec, _) :-
    throw(graph_fault(compile, invalid_graph_spec(Spec))).

normalize_schema(Schema0, Schema) :-
    must_list(Schema0, schema),
    maplist(normalize_field, Schema0, Schema).

normalize_field(field(Key0, Type0, Default, Reducer0),
                state_field{key:Key,
                            type:Type,
                            default:Default,
                            reducer:Reducer}) :-
    !,
    normalize_id(Key0, Key),
    normalize_state_type(Type0, Type),
    normalize_reducer(Reducer0, Reducer),
    require_ground(Default, field_default(Key)),
    validate_state_value(Type, Default, Key).
normalize_field(Field0, Field) :-
    is_dict(Field0),
    !,
    require_dict_key(Field0, key, Key0),
    require_dict_key(Field0, type, Type0),
    require_dict_key(Field0, default, Default),
    require_dict_key(Field0, reducer, Reducer0),
    normalize_field(field(Key0, Type0, Default, Reducer0), Field).
normalize_field(Field, _) :-
    throw(graph_fault(compile, invalid_state_field(Field))).

normalize_state_type(Type0, Type) :-
    normalize_id(Type0, Type),
    memberchk(Type, [any, atom, string, integer, number, boolean, list, dict]),
    !.
normalize_state_type(Type, _) :-
    throw(graph_fault(compile, unsupported_state_type(Type))).

normalize_reducer(Reducer0, Reducer) :-
    normalize_id(Reducer0, Reducer),
    memberchk(Reducer, [replace, append, sum]),
    !.
normalize_reducer(Reducer, _) :-
    throw(graph_fault(compile, unsupported_reducer(Reducer))).

normalize_nodes(Nodes0, Nodes) :-
    must_list(Nodes0, nodes),
    maplist(normalize_node, Nodes0, Nodes).

normalize_node(node(Name0, Handler0),
               graph_node{name:Name, kind:action, ref:Handler}) :-
    !,
    normalize_id(Name0, Name),
    normalize_id(Handler0, Handler),
    reject_reserved_node(Name).
normalize_node(subgraph(Name0, Graph0),
               graph_node{name:Name, kind:subgraph, ref:GraphId}) :-
    !,
    normalize_id(Name0, Name),
    normalize_id(Graph0, GraphId),
    reject_reserved_node(Name).
normalize_node(Node0, Node) :-
    is_dict(Node0),
    !,
    require_dict_key(Node0, name, Name0),
    require_dict_key(Node0, kind, Kind0),
    require_dict_key(Node0, ref, Ref0),
    normalize_id(Kind0, Kind),
    (   Kind == action
    ->  normalize_node(node(Name0, Ref0), Node)
    ;   Kind == subgraph
    ->  normalize_node(subgraph(Name0, Ref0), Node)
    ;   throw(graph_fault(compile, unsupported_node_kind(Kind)))
    ).
normalize_node(Node, _) :-
    throw(graph_fault(compile, invalid_node(Node))).

normalize_edges(Edges0, Edges) :-
    must_list(Edges0, edges),
    maplist(normalize_edge, Edges0, Edges).

normalize_edge(edge(From0, To0), graph_edge{kind:fixed, from:From, to:To}) :-
    !,
    normalize_endpoint(From0, From),
    normalize_endpoint(To0, To).
normalize_edge(conditional(From0, Router0, Routes0),
               graph_edge{kind:conditional,
                          from:From,
                          router:Router,
                          routes:Routes}) :-
    !,
    normalize_endpoint(From0, From),
    normalize_id(Router0, Router),
    must_list(Routes0, routes),
    maplist(normalize_route, Routes0, Routes).
normalize_edge(Edge0, Edge) :-
    is_dict(Edge0),
    !,
    require_dict_key(Edge0, kind, Kind0),
    normalize_id(Kind0, Kind),
    (   Kind == fixed
    ->  require_dict_key(Edge0, from, From0),
        require_dict_key(Edge0, to, To0),
        normalize_edge(edge(From0, To0), Edge)
    ;   Kind == conditional
    ->  require_dict_key(Edge0, from, From0),
        require_dict_key(Edge0, router, Router0),
        require_dict_key(Edge0, routes, Routes0),
        normalize_edge(conditional(From0, Router0, Routes0), Edge)
    ;   throw(graph_fault(compile, unsupported_edge_kind(Kind)))
    ).
normalize_edge(Edge, _) :-
    throw(graph_fault(compile, invalid_edge(Edge))).

normalize_route(route(Key0, Target0), route{key:Key, target:Target}) :-
    !,
    normalize_id(Key0, Key),
    normalize_endpoint(Target0, Target).
normalize_route(Key0-Target0, Route) :-
    !,
    normalize_route(route(Key0, Target0), Route).
normalize_route(Route0, Route) :-
    is_dict(Route0),
    !,
    require_dict_key(Route0, key, Key0),
    require_dict_key(Route0, target, Target0),
    normalize_route(route(Key0, Target0), Route).
normalize_route(Route, _) :-
    throw(graph_fault(compile, invalid_route(Route))).

normalize_registry(Registry0, Registry) :-
    must_list(Registry0, registry),
    maplist(normalize_registry_entry, Registry0, Registry).

normalize_registry_entry(handler(Id0, Closure),
                         registry_entry{kind:handler,
                                        id:Id,
                                        value:Closure}) :-
    !,
    normalize_id(Id0, Id),
    require_callable(Closure, handler(Id)).
normalize_registry_entry(router(Id0, Closure),
                         registry_entry{kind:router,
                                        id:Id,
                                        value:Closure}) :-
    !,
    normalize_id(Id0, Id),
    require_callable(Closure, router(Id)).
normalize_registry_entry(subgraph(Id0, Compiled),
                         registry_entry{kind:subgraph,
                                        id:Id,
                                        value:Compiled}) :-
    !,
    normalize_id(Id0, Id),
    require_compiled_graph(Compiled).
normalize_registry_entry(Entry, _) :-
    throw(graph_fault(compile, invalid_registry_entry(Entry))).

validate_schema(Schema) :-
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

validate_edges(Nodes, Edges, Registry) :-
    node_names(Nodes, Names),
    findall(E, (member(E, Edges), E.from == start), StartEdges),
    length(StartEdges, StartCount),
    (   StartCount =:= 1
    ->  true
    ;   throw(graph_fault(compile, start_edge_count(StartCount)))
    ),
    (   member(EEnd, Edges), EEnd.from == end
    ->  throw(graph_fault(compile, outgoing_end_edge(EEnd)))
    ;   true
    ),
    maplist(validate_edge(Names, Registry), Edges),
    findall(From, (member(E, Edges), From = E.from), Froms),
    require_unique(Froms, outgoing_edge),
    forall(member(Name, Names),
           (   member(E, Edges), E.from == Name
           ->  true
           ;   throw(graph_fault(compile, missing_outgoing_edge(Name)))
           )).

validate_edge(Names, _, graph_edge{kind:fixed, from:From, to:To}) :-
    !,
    validate_from(From, Names),
    validate_target(To, Names).
validate_edge(Names, Registry,
              graph_edge{kind:conditional,
                         from:From,
                         router:Router,
                         routes:Routes}) :-
    validate_from(From, Names),
    (   From == start
    ->  throw(graph_fault(compile, conditional_start_edge))
    ;   true
    ),
    require_registry(Registry, router, Router, _),
    (   Routes == []
    ->  throw(graph_fault(compile, empty_routes(From)))
    ;   true
    ),
    findall(Key,
            ( member(Route, Routes),
              get_dict(key, Route, Key)
            ),
            Keys),
    require_unique(Keys, route_key(From)),
    forall(( member(Route, Routes),
             get_dict(target, Route, Target)
           ),
           validate_target(Target, Names)).

validate_from(start, _) :- !.
validate_from(From, Names) :-
    (   memberchk(From, Names)
    ->  true
    ;   throw(graph_fault(compile, unknown_edge_source(From)))
    ).

validate_target(end, _) :- !.
validate_target(Target, Names) :-
    (   memberchk(Target, Names)
    ->  true
    ;   throw(graph_fault(compile, unknown_edge_target(Target)))
    ).

validate_reachability(Nodes, Edges) :-
    start_target(Edges, First),
    reachable_nodes([First], Edges, [], Reachable0),
    sort(Reachable0, Reachable),
    node_names(Nodes, Names0),
    sort(Names0, Names),
    ord_subtract(Names, Reachable, Unreachable),
    (   Unreachable == []
    ->  true
    ;   throw(graph_fault(compile, unreachable_nodes(Unreachable)))
    ),
    forall(member(Name, Names),
           (   path_to_end(Name, Edges, [])
           ->  true
           ;   throw(graph_fault(compile, no_path_to_end(Name)))
           )).

reachable_nodes([], _, Seen, Seen).
reachable_nodes([end|Queue], Edges, Seen, Reachable) :-
    !,
    reachable_nodes(Queue, Edges, Seen, Reachable).
reachable_nodes([Node|Queue], Edges, Seen, Reachable) :-
    (   memberchk(Node, Seen)
    ->  reachable_nodes(Queue, Edges, Seen, Reachable)
    ;   edge_targets(Node, Edges, Targets),
        append(Queue, Targets, Next),
        reachable_nodes(Next, Edges, [Node|Seen], Reachable)
    ).

path_to_end(end, _, _) :- !.
path_to_end(Node, _, Seen) :-
    memberchk(Node, Seen),
    !,
    fail.
path_to_end(Node, Edges, Seen) :-
    edge_targets(Node, Edges, Targets),
    member(Target, Targets),
    path_to_end(Target, Edges, [Node|Seen]),
    !.

/* -------------------------------------------------------------------------
 * Backend-neutral checkpoint storage
 * ---------------------------------------------------------------------- */

graph_backend_open(memory, graph_backend(memory, Id)) :-
    !,
    with_mutex(rlm_graph_memory,
               ( gensym(graph_memory_, Id),
                 assertz(graph_memory_backend(Id))
               )).
graph_backend_open(persist(File), graph_backend(persist, File)) :-
    !,
    require_text(File, persist_file),
    graph_persist_open(File).
graph_backend_open(Backend, _) :-
    throw(error(domain_error(graph_backend, Backend),
                context(rlm_graph:graph_backend_open/2,
                        'expected memory or persist(File)'))).

graph_backend_close(graph_backend(memory, Id)) :-
    !,
    with_mutex(rlm_graph_memory,
               ( retractall(graph_memory_checkpoint(Id, _, _, _)),
                 retractall(graph_memory_event(Id, _, _, _)),
                 retractall(graph_memory_backend(Id))
               )).
graph_backend_close(graph_backend(persist, _)) :-
    !,
    graph_persist_close.
graph_backend_close(none) :- !.
graph_backend_close(Backend) :-
    throw(error(domain_error(graph_backend, Backend),
                context(rlm_graph:graph_backend_close/1,
                        'unknown graph backend'))).

graph_checkpoint(Backend, RunId, Snapshot) :-
    backend_get_checkpoint(Backend, RunId, _, Snapshot).

graph_history(Backend, RunId, Events) :-
    backend_history(Backend, RunId, Events).

backend_put_checkpoint(none, _, _, _) :- !.
backend_put_checkpoint(graph_backend(memory, Id), RunId, GraphId, Snapshot) :-
    !,
    require_memory_backend(Id),
    with_mutex(rlm_graph_memory,
               ( retractall(graph_memory_checkpoint(Id, RunId, _, _)),
                 assertz(graph_memory_checkpoint(Id,
                                                 RunId,
                                                 GraphId,
                                                 Snapshot))
               )).
backend_put_checkpoint(graph_backend(persist, _), RunId, GraphId, Snapshot) :-
    !,
    graph_persist_put_checkpoint(RunId, GraphId, Snapshot).
backend_put_checkpoint(Backend, _, _, _) :-
    throw(graph_fault(checkpoint, unknown_backend(Backend))).

backend_get_checkpoint(graph_backend(memory, Id), RunId, GraphId, Snapshot) :-
    !,
    require_memory_backend(Id),
    graph_memory_checkpoint(Id, RunId, GraphId, Snapshot).
backend_get_checkpoint(graph_backend(persist, _), RunId, GraphId, Snapshot) :-
    !,
    graph_persist_get_checkpoint(RunId, GraphId, Snapshot).
backend_get_checkpoint(none, _, _, _) :-
    !,
    fail.
backend_get_checkpoint(Backend, _, _, _) :-
    throw(graph_fault(checkpoint, unknown_backend(Backend))).

backend_append_event(none, _, _, _) :- !.
backend_append_event(graph_backend(memory, Id), RunId, Sequence, Event) :-
    !,
    require_memory_backend(Id),
    with_mutex(rlm_graph_memory,
               assertz(graph_memory_event(Id, RunId, Sequence, Event))).
backend_append_event(graph_backend(persist, _), RunId, Sequence, Event) :-
    !,
    graph_persist_append_event(RunId, Sequence, Event).
backend_append_event(Backend, _, _, _) :-
    throw(graph_fault(checkpoint, unknown_backend(Backend))).

backend_history(graph_backend(memory, Id), RunId, Events) :-
    !,
    require_memory_backend(Id),
    findall(Sequence-Event,
            graph_memory_event(Id, RunId, Sequence, Event),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).
backend_history(graph_backend(persist, _), RunId, Events) :-
    !,
    graph_persist_history(RunId, Events).
backend_history(none, _, []) :- !.
backend_history(Backend, _, _) :-
    throw(graph_fault(checkpoint, unknown_backend(Backend))).

require_memory_backend(Id) :-
    (   graph_memory_backend(Id)
    ->  true
    ;   throw(graph_fault(checkpoint, closed_memory_backend(Id)))
    ).

/* -------------------------------------------------------------------------
 * Cancellation
 * ---------------------------------------------------------------------- */

graph_cancellation_token(Token) :-
    uuid(Id, [version(4)]),
    atom_concat(graph_cancel_, Id, Token),
    with_mutex(rlm_graph_cancel,
               ( retractall(graph_cancel_state(Token, _)),
                 assertz(graph_cancel_state(Token, active))
               )).

graph_cancel(Token) :-
    with_mutex(rlm_graph_cancel,
               ( retractall(graph_cancel_state(Token, _)),
                 assertz(graph_cancel_state(Token, cancelled)),
                 findall(Thread,
                         graph_cancel_thread(Token, Thread),
                         Threads)
               )),
    forall(member(Thread, Threads),
           catch(thread_signal(Thread,
                               throw(graph_cancelled(Token))),
                 _,
                 true)).

check_graph_cancelled(none) :- !.
check_graph_cancelled(Token) :-
    (   graph_cancel_state(Token, cancelled)
    ->  throw(graph_cancelled(Token))
    ;   true
    ).

register_graph_thread(none) :- !.
register_graph_thread(Token) :-
    thread_self(Thread),
    with_mutex(rlm_graph_cancel,
               assertz(graph_cancel_thread(Token, Thread))).

unregister_graph_thread(none) :- !.
unregister_graph_thread(Token) :-
    thread_self(Thread),
    with_mutex(rlm_graph_cancel,
               (   retract(graph_cancel_thread(Token, Thread))
               ->  true
               ;   true
               )).

/* -------------------------------------------------------------------------
 * Execution and resume
 * ---------------------------------------------------------------------- */

graph_run(Compiled, InitialState0, Options, Outcome) :-
    catch(graph_run_guarded(Compiled, InitialState0, Options, Outcome),
          Exception,
          graph_execution_exception(Exception, Outcome)).

graph_run_guarded(Compiled, InitialState0, Options, Outcome) :-
    require_compiled_graph(Compiled),
    graph_options(Options, Config, Token, OwnToken),
    setup_call_cleanup(
        register_graph_thread(Token),
        call_with_time_limit(Config.time_limit,
                             graph_start_execution(Compiled,
                                                   InitialState0,
                                                   Config,
                                                   Token,
                                                   Outcome)),
        cleanup_graph_run(Token, OwnToken)).

graph_start_execution(Compiled, InitialState0, Config, Token, Outcome) :-
    check_graph_cancelled(Token),
    initialize_state(Compiled.schema, InitialState0, State),
    run_id(Config.run_id, RunId),
    start_target(Compiled.edges, First),
    Snapshot0 = graph_snapshot{
                    run_id:RunId,
                    graph_id:Compiled.id,
                    status:running,
                    current:First,
                    state:State,
                    steps:0,
                    visits:visits{},
                    event_sequence:0
                },
    emit_event(Config,
               Snapshot0,
               run_started,
               _{current:First, state:State},
               Snapshot1),
    checkpoint_snapshot(Config.backend, Compiled.id, Snapshot1),
    execute_loop(Compiled,
                 Config,
                 Token,
                 none,
                 Snapshot1,
                 Outcome).

graph_resume(Compiled, Backend, RunId, Resume0, Options, Outcome) :-
    catch(graph_resume_guarded(Compiled,
                               Backend,
                               RunId,
                               Resume0,
                               Options,
                               Outcome),
          Exception,
          graph_execution_exception(Exception, Outcome)).

graph_resume_guarded(Compiled, Backend, RunId, Resume0, Options, Outcome) :-
    require_compiled_graph(Compiled),
    backend_get_checkpoint(Backend, RunId, GraphId, Snapshot0),
    (   GraphId == Compiled.id
    ->  true
    ;   throw(graph_fault(resume,
                          graph_id_mismatch(GraphId, Compiled.id)))
    ),
    require_paused_snapshot(Snapshot0),
    graph_options([backend(Backend)|Options], Config, Token, OwnToken),
    normalize_resume(Resume0, ResumeValue, ResumePatch),
    apply_state_patch(Compiled.schema,
                      Snapshot0.state,
                      ResumePatch,
                      State),
    put_dict(_{status:running, state:State}, Snapshot0, Snapshot1),
    setup_call_cleanup(
        register_graph_thread(Token),
        call_with_time_limit(Config.time_limit,
                             graph_resume_execution(Compiled,
                                                    Config,
                                                    Token,
                                                    ResumeValue,
                                                    Snapshot1,
                                                    Outcome)),
        cleanup_graph_run(Token, OwnToken)).

graph_resume_execution(Compiled, Config, Token, ResumeValue, Snapshot0,
                       Outcome) :-
    check_graph_cancelled(Token),
    emit_event(Config,
               Snapshot0,
               resumed,
               _{current:Snapshot0.current,
                 resume:ResumeValue,
                 state:Snapshot0.state},
               Snapshot1),
    checkpoint_snapshot(Config.backend, Compiled.id, Snapshot1),
    execute_loop(Compiled,
                 Config,
                 Token,
                 ResumeValue,
                 Snapshot1,
                 Outcome).

execute_loop(Compiled, Config, _Token, _, Snapshot0, Outcome) :-
    Snapshot0.current == end,
    !,
    put_dict(status, Snapshot0, completed, Completed0),
    emit_event(Config,
               Completed0,
               run_completed,
               _{state:Completed0.state, steps:Completed0.steps},
               Completed),
    checkpoint_snapshot(Config.backend, Compiled.id, Completed),
    result_from_snapshot(Config.backend, Completed, Outcome).
execute_loop(Compiled, Config, Token, ResumeValue, Snapshot0, Outcome) :-
    check_graph_cancelled(Token),
    check_step_budget(Config, Snapshot0),
    visit_node(Config,
               Snapshot0.current,
               Snapshot0.visits,
               Visits),
    Step is Snapshot0.steps+1,
    put_dict(_{steps:Step, visits:Visits}, Snapshot0, Snapshot1),
    Current = Snapshot1.current,
    emit_event(Config,
               Snapshot1,
               node_started,
               _{node:Current, step:Step},
               Snapshot2),
    execute_current_node(Compiled,
                         Config,
                         Token,
                         ResumeValue,
                         Snapshot2,
                         NodeOutcome),
    after_node_execution(NodeOutcome,
                         Compiled,
                         Config,
                         Token,
                         Snapshot2,
                         Outcome).

after_node_execution(error(Error), _, _, _, _, error(Error)) :- !.
after_node_execution(ok(node_result{patch:Patch,
                                    interrupt:Interrupt}),
                     Compiled,
                     Config,
                     Token,
                     Snapshot0,
                     Outcome) :-
    apply_state_patch(Compiled.schema,
                      Snapshot0.state,
                      Patch,
                      State),
    put_dict(state, Snapshot0, State, Snapshot1),
    emit_event(Config,
               Snapshot1,
               node_completed,
               _{node:Snapshot0.current, patch:Patch, state:State},
               Snapshot2),
    select_next(Compiled,
                Config,
                Token,
                Snapshot0.current,
                State,
                NextOutcome),
    after_route_selection(NextOutcome,
                          Interrupt,
                          Compiled,
                          Config,
                          Token,
                          Snapshot2,
                          Outcome).

after_route_selection(error(Error), _, _, _, _, _, error(Error)) :- !.
after_route_selection(ok(Next), Interrupt, Compiled, Config, Token, Snapshot0,
                      Outcome) :-
    emit_event(Config,
               Snapshot0,
               edge_selected,
               _{from:Snapshot0.current, to:Next},
               Snapshot1),
    put_dict(current, Snapshot1, Next, Snapshot2),
    (   Interrupt == none
    ->  checkpoint_snapshot(Config.backend, Compiled.id, Snapshot2),
        execute_loop(Compiled,
                     Config,
                     Token,
                     none,
                     Snapshot2,
                     Outcome)
    ;   Interrupt = interrupt(Reason),
        put_dict(status, Snapshot2, paused(Reason), Paused0),
        emit_event(Config,
                   Paused0,
                   interrupted,
                   _{reason:Reason, next:Next, state:Paused0.state},
                   Paused),
        checkpoint_snapshot(Config.backend, Compiled.id, Paused),
        result_from_snapshot(Config.backend, Paused, Outcome)
    ).

execute_current_node(Compiled, Config, Token, ResumeValue, Snapshot, Outcome) :-
    node_by_name(Compiled.nodes, Snapshot.current, Node),
    Context = graph_context{
                  run_id:Snapshot.run_id,
                  graph_id:Compiled.id,
                  node:Snapshot.current,
                  step:Snapshot.steps,
                  cancellation_token:Token,
                  resume:ResumeValue
              },
    execute_node(Node,
                 Compiled,
                 Config,
                 Token,
                 Snapshot.state,
                 Context,
                 Outcome).

execute_node(Node,
             Compiled, _, Token, State, Context, Outcome) :-
    get_dict(kind, Node, action),
    !,
    get_dict(ref, Node, Ref),
    require_registry(Compiled.registry, handler, Ref, Handler),
    check_graph_cancelled(Token),
    catch(( call(Handler, State, Context, Raw)
          -> normalize_node_result(Raw, Outcome)
          ;  Outcome = error(graph_error{phase:execute,
                                         kind:node_failed,
                                         node:Context.node,
                                         message:"graph node handler failed"})
          ),
          graph_cancelled(CancelToken),
          throw(graph_cancelled(CancelToken))),
    check_graph_cancelled(Token).
execute_node(Node,
             Compiled, Config, Token, State, Context, Outcome) :-
    get_dict(kind, Node, subgraph),
    get_dict(ref, Node, Ref),
    require_registry(Compiled.registry, subgraph, Ref, Subgraph),
    RemainingSteps is max(1, Config.max_steps-Context.step),
    SubOptions = [max_steps(RemainingSteps),
                  max_visits_per_node(Config.max_visits_per_node),
                  time_limit(Config.time_limit),
                  backend(none),
                  cancellation_token(Token)],
    graph_run(Subgraph, State, SubOptions, SubOutcome),
    subgraph_node_result(SubOutcome,
                         Compiled.schema,
                         State,
                         Ref,
                         Outcome).

subgraph_node_result(error(Error), _, _, Ref, error(GraphError)) :-
    !,
    GraphError = graph_error{phase:execute,
                             kind:subgraph_failed,
                             subgraph:Ref,
                             cause:Error,
                             message:"subgraph execution failed"}.
subgraph_node_result(ok(Result), Schema, ParentState, Ref, Outcome) :-
    (   Result.status == completed
    ->  state_delta(Schema, ParentState, Result.state, Patch),
        Outcome = ok(node_result{patch:Patch, interrupt:none})
    ;   Outcome = error(graph_error{phase:execute,
                                    kind:subgraph_interrupted,
                                    subgraph:Ref,
                                    status:Result.status,
                                    message:"inline subgraph cannot pause independently"})
    ).

normalize_node_result(update(Patch0), Outcome) :-
    !,
    normalize_patch(Patch0, Patch),
    Outcome = ok(node_result{patch:Patch, interrupt:none}).
normalize_node_result(interrupt(Reason, Patch0), Outcome) :-
    !,
    require_ground(Reason, interrupt_reason),
    normalize_patch(Patch0, Patch),
    Outcome = ok(node_result{patch:Patch, interrupt:interrupt(Reason)}).
normalize_node_result(Patch0, Outcome) :-
    is_dict(Patch0),
    !,
    normalize_patch(Patch0, Patch),
    Outcome = ok(node_result{patch:Patch, interrupt:none}).
normalize_node_result(Result,
                      error(graph_error{phase:execute,
                                        kind:invalid_node_result,
                                        result:Result,
                                        message:"node must return update(Patch), interrupt(Reason,Patch), or a dict patch"})).

select_next(Compiled, Config, Token, From, State, Outcome) :-
    edge_from(Compiled.edges, From, Edge),
    select_edge_target(Edge,
                       Compiled.registry,
                       Config,
                       Token,
                       State,
                       Outcome).

select_edge_target(Edge, _, _, _, _, ok(Target)) :-
    get_dict(kind, Edge, fixed),
    !,
    get_dict(to, Edge, Target).
select_edge_target(Edge, Registry, _, Token, State, Outcome) :-
    get_dict(kind, Edge, conditional),
    get_dict(router, Edge, Router),
    get_dict(routes, Edge, Routes),
    require_registry(Registry, router, Router, Handler),
    check_graph_cancelled(Token),
    catch(( call(Handler, State, Route0)
          -> normalize_id(Route0, Route),
             route_target(Routes, Route, Outcome)
          ;  Outcome = error(graph_error{phase:route,
                                         kind:router_failed,
                                         router:Router,
                                         message:"graph router failed"})
          ),
          graph_cancelled(CancelToken),
          throw(graph_cancelled(CancelToken))),
    check_graph_cancelled(Token).

route_target(Routes, Route, ok(Target)) :-
    member(route{key:Route, target:Target}, Routes),
    !.
route_target(_, Route,
             error(graph_error{phase:route,
                               kind:unknown_route,
                               route:Route,
                               message:"router selected an undeclared route"})).

/* -------------------------------------------------------------------------
 * State schema and reducers
 * ---------------------------------------------------------------------- */

initialize_state(Schema, Initial0, State) :-
    normalize_patch(Initial0, Initial),
    schema_defaults(Schema, Defaults),
    apply_state_patch(Schema, Defaults, Initial, State).

schema_defaults(Schema, State) :-
    findall(Key-Default,
            ( member(Field, Schema),
              get_dict(key, Field, Key),
              get_dict(default, Field, Default)
            ),
            Pairs),
    dict_pairs(State, graph_state, Pairs).

apply_state_patch(Schema, State0, Patch0, State) :-
    normalize_patch(Patch0, Patch),
    dict_pairs(Patch, _, Pairs),
    foldl(apply_state_pair(Schema), Pairs, State0, State).

apply_state_pair(Schema, Key-Value, State0, State) :-
    schema_field(Schema, Key, Field),
    get_dict(Key, State0, Existing),
    reduce_state(Field.reducer, Existing, Value, Reduced),
    validate_state_value(Field.type, Reduced, Key),
    put_dict(Key, State0, Reduced, State).

schema_field(Schema, Key, Field) :-
    member(Field, Schema),
    Field.key == Key,
    !.
schema_field(_, Key, _) :-
    throw(graph_fault(state, unknown_state_field(Key))).

reduce_state(replace, _, Value, Value).
reduce_state(append, Existing, Value, Reduced) :-
    (   is_list(Existing), is_list(Value)
    ->  append(Existing, Value, Reduced)
    ;   throw(graph_fault(state, append_requires_lists(Existing, Value)))
    ).
reduce_state(sum, Existing, Value, Reduced) :-
    (   number(Existing), number(Value)
    ->  Reduced is Existing+Value
    ;   throw(graph_fault(state, sum_requires_numbers(Existing, Value)))
    ).

state_delta(Schema, Parent, Child, Patch) :-
    findall(Key-Delta,
            ( member(Field, Schema),
              Key = Field.key,
              get_dict(Key, Parent, Before),
              get_dict(Key, Child, After),
              Before \== After,
              reducer_delta(Field.reducer, Before, After, Delta)
            ),
            Pairs),
    dict_pairs(Patch, graph_patch, Pairs).

reducer_delta(replace, _, After, After).
reducer_delta(sum, Before, After, Delta) :-
    Delta is After-Before.
reducer_delta(append, Before, After, Delta) :-
    (   append(Before, Delta, After)
    ->  true
    ;   throw(graph_fault(execute,
                          subgraph_append_not_monotonic(Before, After)))
    ).

validate_state_value(any, Value, _) :-
    ground(Value),
    !.
validate_state_value(atom, Value, _) :- atom(Value), !.
validate_state_value(string, Value, _) :- string(Value), !.
validate_state_value(integer, Value, _) :- integer(Value), !.
validate_state_value(number, Value, _) :- number(Value), !.
validate_state_value(boolean, Value, _) :- memberchk(Value, [true,false]), !.
validate_state_value(list, Value, _) :- is_list(Value), ground(Value), !.
validate_state_value(dict, Value, _) :- is_dict(Value), ground(Value), !.
validate_state_value(Type, Value, Key) :-
    throw(graph_fault(state, invalid_state_value(Key, Type, Value))).

normalize_patch(Patch0, Patch) :-
    is_dict(Patch0),
    !,
    dict_pairs(Patch0, _, Pairs0),
    maplist(normalize_patch_pair, Pairs0, Pairs),
    dict_pairs(Patch, graph_patch, Pairs).
normalize_patch(Patch, _) :-
    throw(graph_fault(state, expected_state_patch_dict(Patch))).

normalize_patch_pair(Key-Value, Key-Value) :-
    atom(Key),
    ground(Value),
    !.
normalize_patch_pair(Key-Value, _) :-
    throw(graph_fault(state, invalid_state_patch_pair(Key, Value))).

/* -------------------------------------------------------------------------
 * Events, checkpoints and result materialization
 * ---------------------------------------------------------------------- */

emit_event(Config, Snapshot0, Type, Fields, Snapshot) :-
    Sequence is Snapshot0.event_sequence+1,
    Event = graph_event{sequence:Sequence,
                        type:Type,
                        run_id:Snapshot0.run_id,
                        graph_id:Snapshot0.graph_id,
                        fields:Fields},
    backend_append_event(Config.backend,
                         Snapshot0.run_id,
                         Sequence,
                         Event),
    call_event_handler(Config.event_handler, Event),
    put_dict(event_sequence, Snapshot0, Sequence, Snapshot).

call_event_handler(none, _) :- !.
call_event_handler(Handler, Event) :-
    catch(( call(Handler, Event)
          -> true
          ;  throw(graph_fault(stream, event_handler_failed))
          ),
          Exception,
          throw(graph_fault(stream, event_handler_exception(Exception)))).

checkpoint_snapshot(Backend, GraphId, Snapshot) :-
    require_ground(Snapshot, checkpoint_snapshot),
    backend_put_checkpoint(Backend, Snapshot.run_id, GraphId, Snapshot).

result_from_snapshot(Backend, Snapshot, ok(Result)) :-
    backend_history(Backend, Snapshot.run_id, History),
    Result = graph_result{run_id:Snapshot.run_id,
                          graph_id:Snapshot.graph_id,
                          status:Snapshot.status,
                          current:Snapshot.current,
                          state:Snapshot.state,
                          steps:Snapshot.steps,
                          visits:Snapshot.visits,
                          event_sequence:Snapshot.event_sequence,
                          history:History}.

/* -------------------------------------------------------------------------
 * Runtime configuration and limits
 * ---------------------------------------------------------------------- */

graph_options(Options, Config, Token, OwnToken) :-
    require_options(Options),
    default_graph_options(Default),
    option(max_steps(MaxSteps), Options, Default.max_steps),
    option(max_visits_per_node(MaxVisits),
           Options,
           Default.max_visits_per_node),
    option(time_limit(TimeLimit), Options, Default.time_limit),
    option(backend(Backend), Options, Default.backend),
    option(event_handler(EventHandler), Options, Default.event_handler),
    option(cancellation_token(Token0),
           Options,
           Default.cancellation_token),
    option(run_id(RunId0), Options, Default.run_id),
    require_positive_integer(MaxSteps, max_steps),
    require_positive_integer(MaxVisits, max_visits_per_node),
    require_positive_number(TimeLimit, time_limit),
    validate_backend(Backend),
    require_event_handler(EventHandler),
    normalize_run_id_option(RunId0, RunId),
    cancellation_config(Token0, Token, OwnToken),
    Config = graph_options{max_steps:MaxSteps,
                           max_visits_per_node:MaxVisits,
                           time_limit:TimeLimit,
                           backend:Backend,
                           event_handler:EventHandler,
                           run_id:RunId}.

cancellation_config(none, Token, true) :-
    !,
    graph_cancellation_token(Token).
cancellation_config(Token, Token, false) :-
    atom(Token),
    !,
    with_mutex(rlm_graph_cancel,
               (   graph_cancel_state(Token, _)
               ->  true
               ;   assertz(graph_cancel_state(Token, active))
               )).
cancellation_config(Token, _, _) :-
    throw(graph_fault(config, invalid_cancellation_token(Token))).

cleanup_graph_run(Token, OwnToken) :-
    unregister_graph_thread(Token),
    (   OwnToken == true
    ->  with_mutex(rlm_graph_cancel,
                   ( retractall(graph_cancel_state(Token, _)),
                     retractall(graph_cancel_thread(Token, _))
                   ))
    ;   true
    ).

check_step_budget(Config, Snapshot) :-
    (   Snapshot.steps < Config.max_steps
    ->  true
    ;   throw(graph_fault(execute,
                          step_budget_exhausted(Config.max_steps)))
    ).

visit_node(Config, Node, Visits0, Visits) :-
    (   get_dict(Node, Visits0, Existing)
    ->  Count is Existing+1
    ;   Count = 1
    ),
    (   Count =< Config.max_visits_per_node
    ->  put_dict(Node, Visits0, Count, Visits)
    ;   throw(graph_fault(execute,
                          node_visit_budget_exhausted(Node,
                                                      Config.max_visits_per_node)))
    ).

run_id(auto, RunId) :-
    !,
    uuid(UUID, [version(4)]),
    atom_concat(graph_run_, UUID, RunId).
run_id(RunId, RunId).

normalize_run_id_option(auto, auto) :- !.
normalize_run_id_option(Id0, Id) :- normalize_id(Id0, Id).

normalize_resume(resume(Value, Patch0), Value, Patch) :-
    !,
    require_ground(Value, resume_value),
    normalize_patch(Patch0, Patch).
normalize_resume(Value, Value, graph_patch{}) :-
    require_ground(Value, resume_value).

require_paused_snapshot(Snapshot) :-
    (   Snapshot.status = paused(_)
    ->  true
    ;   throw(graph_fault(resume, run_not_paused(Snapshot.status)))
    ).

validate_backend(none) :- !.
validate_backend(graph_backend(memory, Id)) :-
    !,
    require_memory_backend(Id).
validate_backend(graph_backend(persist, _)) :- !.
validate_backend(Backend) :-
    throw(graph_fault(config, invalid_backend(Backend))).

require_event_handler(none) :- !.
require_event_handler(Handler) :- callable(Handler), !.
require_event_handler(Handler) :-
    throw(graph_fault(config, invalid_event_handler(Handler))).

/* -------------------------------------------------------------------------
 * Graph lookup helpers
 * ---------------------------------------------------------------------- */

start_target(Edges, Target) :-
    member(Edge, Edges),
    Edge.from == start,
    get_dict(kind, Edge, fixed),
    !,
    get_dict(to, Edge, Target).

edge_from(Edges, From, Edge) :-
    member(Edge, Edges),
    Edge.from == From,
    !.

edge_targets(Node, Edges, Targets) :-
    (   edge_from(Edges, Node, Edge)
    ->  edge_targets_(Edge, Targets)
    ;   Targets = []
    ).

edge_targets_(Edge, [Target]) :-
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

node_by_name(Nodes, Name, Node) :-
    member(Node, Nodes),
    Node.name == Name,
    !.
node_by_name(_, Name, _) :-
    throw(graph_fault(execute, unknown_node(Name))).

require_registry(Registry, Kind, Id, Value) :-
    member(Entry, Registry),
    Entry.kind == Kind,
    Entry.id == Id,
    !,
    Value = Entry.value.
require_registry(_, Kind, Id, _) :-
    throw(graph_fault(compile, missing_registry_entry(Kind, Id))).

route_targets(Routes, Targets) :-
    findall(Target, member(route{target:Target}, Routes), Targets).

normalize_endpoint(start, start) :- !.
normalize_endpoint(end, end) :- !.
normalize_endpoint(Value0, Value) :- normalize_id(Value0, Value).

reject_reserved_node(Name) :-
    (   memberchk(Name, [start,end])
    ->  throw(graph_fault(compile, reserved_node_name(Name)))
    ;   true
    ).

/* -------------------------------------------------------------------------
 * Validation / error helpers
 * ---------------------------------------------------------------------- */

graph_compile_exception(graph_fault(Phase, Detail), error(Error)) :-
    !,
    Error = graph_error{phase:Phase,
                        kind:compile_failure,
                        detail:Detail,
                        message:"graph compilation failed"}.
graph_compile_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = graph_error{phase:compile,
                        kind:exception,
                        exception:Safe,
                        message:"graph compilation raised an exception"}.

graph_execution_exception(graph_cancelled(Token), error(Error)) :-
    !,
    Error = graph_error{phase:execute,
                        kind:cancelled,
                        token:Token,
                        message:"graph execution cancelled"}.
graph_execution_exception(time_limit_exceeded, error(Error)) :-
    !,
    Error = graph_error{phase:execute,
                        kind:timeout,
                        message:"graph wall-time limit exceeded"}.
graph_execution_exception(graph_fault(Phase, Detail), error(Error)) :-
    !,
    Error = graph_error{phase:Phase,
                        kind:graph_failure,
                        detail:Detail,
                        message:"graph execution failed"}.
graph_execution_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = graph_error{phase:execute,
                        kind:exception,
                        exception:Safe,
                        message:"graph execution raised an exception"}.

require_compiled_graph(Compiled) :-
    (   is_dict(Compiled),
        get_dict(kind, Compiled, rlm_graph),
        get_dict(id, Compiled, Id),
        atom(Id)
    ->  true
    ;   throw(graph_fault(compile, invalid_compiled_graph(Compiled)))
    ).

require_dict_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(graph_fault(compile, missing_key(Key)))
    ).

normalize_id(Value, Atom) :-
    atom(Value), Value \== '',
    !,
    Atom = Value.
normalize_id(Value, Atom) :-
    string(Value), Value \== "",
    !,
    atom_string(Atom, Value).
normalize_id(Value, _) :-
    throw(graph_fault(compile, invalid_identifier(Value))).

require_unique(Values, Kind) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, UniqueCount),
    (   Count =:= UniqueCount
    ->  true
    ;   throw(graph_fault(compile, duplicate(Kind, Values)))
    ).

must_list(Value, _) :- is_list(Value), !.
must_list(Value, Name) :-
    throw(graph_fault(compile, expected_list(Name, Value))).

require_options(Options) :-
    (   is_list(Options)
    ->  true
    ;   throw(graph_fault(config, invalid_options(Options)))
    ).

require_callable(Value, _) :- callable(Value), !.
require_callable(Value, Name) :-
    throw(graph_fault(compile, invalid_callable(Name, Value))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :-
    throw(graph_fault(state, non_ground(Name, Value))).

require_positive_integer(Value, _) :- integer(Value), Value > 0, !.
require_positive_integer(Value, Name) :-
    throw(graph_fault(config, invalid_positive_integer(Name, Value))).

require_positive_number(Value, _) :- number(Value), Value > 0, !.
require_positive_number(Value, Name) :-
    throw(graph_fault(config, invalid_positive_number(Name, Value))).

require_text(Value, _) :- atom(Value), Value \== '', !.
require_text(Value, _) :- string(Value), Value \== "", !.
require_text(Value, Name) :-
    throw(error(type_error(text, Value),
                context(rlm_graph, Name))).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).
