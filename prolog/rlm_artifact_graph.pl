:- module(rlm_artifact_graph,
          [ rlm_artifact_graph_ready/0,
            artifact_graph_schema_field/1,
            graph_artifact_publish/7,
            graph_artifact_context/5
          ]).

/** <module> Durable artifact integration for graph state/checkpoints */

:- use_module(rlm_artifact).

rlm_artifact_graph_ready.

artifact_graph_schema_field(field(artifact_refs, list, [], append)).

graph_artifact_publish(Store,
                       Context,
                       Key,
                       Kind,
                       Value,
                       Provenance0,
                       Outcome) :-
    catch(graph_artifact_publish_(Store,
                                  Context,
                                  Key,
                                  Kind,
                                  Value,
                                  Provenance0,
                                  Outcome),
          Exception,
          graph_artifact_exception(publish, Exception, Outcome)).

graph_artifact_publish_(Store, Context, Key, Kind, Value, Provenance0,
                        Outcome) :-
    require_graph_context(Context),
    require_dict(Provenance0, provenance),
    graph_namespace(Context, Namespace),
    graph_producer(Context, Producer),
    put_dict(Producer, Provenance0, Provenance),
    artifact_put(Store,
                 Namespace,
                 Key,
                 Kind,
                 Value,
                 Provenance,
                 PutOutcome),
    graph_publish_outcome(PutOutcome, Outcome).

graph_publish_outcome(error(Error), error(Error)) :- !.
graph_publish_outcome(ok(Artifact),
                      ok(graph_artifact{
                             artifact:Artifact,
                             patch:_{artifact_refs:[Artifact.ref]}
                         })).

graph_artifact_context(Store, Context, State, Options, Outcome) :-
    catch(graph_artifact_context_(Store,
                                  Context,
                                  State,
                                  Options,
                                  Outcome),
          Exception,
          graph_artifact_exception(context, Exception, Outcome)).

graph_artifact_context_(Store, Context, State, Options, Outcome) :-
    require_graph_context(Context),
    require_dict(State, graph_state),
    require_options(Options),
    (   get_dict(artifact_refs, State, Refs)
    ->  true
    ;   Refs = []
    ),
    graph_consumer(Context, Consumer),
    artifact_context_refs(Store,
                          Refs,
                          [consumer(Consumer)|Options],
                          Outcome).

graph_namespace(Context, [graph, GraphId, RunId]) :-
    id_name(Context.graph_id, GraphId),
    id_name(Context.run_id, RunId).

graph_producer(Context,
               _{producer_type:graph,
                 run_id:Context.run_id,
                 graph_id:Context.graph_id,
                 node:Context.node,
                 step:Context.step}).

graph_consumer(Context,
               _{consumer_type:graph,
                 run_id:Context.run_id,
                 graph_id:Context.graph_id,
                 node:Context.node,
                 step:Context.step}).

require_graph_context(Context) :-
    require_dict(Context, graph_context),
    forall(member(Key, [run_id, graph_id, node, step]),
           ( get_dict(Key, Context, _)
           -> true
           ;  throw(graph_artifact_fault(missing_context_key(Key))) )).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :-
    throw(graph_artifact_fault(expected_dict(Name, Value))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :-
    throw(graph_artifact_fault(invalid_options(Options))).

id_name(Value, Value) :- atom(Value), Value \== '', !.
id_name(Value, Name) :- string(Value), Value \== "", !, atom_string(Name, Value).
id_name(Value, Name) :- number(Value), !, term_to_atom(Value, Name).
id_name(Value, Name) :-
    ground(Value),
    !,
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    atom_string(Name, Text).
id_name(Value, _) :-
    throw(graph_artifact_fault(invalid_identifier(Value))).

graph_artifact_exception(_, graph_artifact_fault(Detail), error(Error)) :-
    !,
    Error = artifact_error{phase:graph_integration,
                           kind:invalid_graph_artifact_request,
                           detail:Detail,
                           message:"graph artifact integration request is invalid"}.
graph_artifact_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = artifact_error{phase:graph_integration,
                           kind:exception,
                           operation:Operation,
                           exception:Safe,
                           message:"graph artifact integration raised an exception"}.
