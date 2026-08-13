:- module(rlm_artifact_agent,
          [ rlm_artifact_agent_ready/0,
            agent_artifact_publish/8,
            agent_artifact_refs/3,
            agent_artifact_context/5
          ]).

/** <module> Durable artifact integration for supervised agents */

:- use_module(library(option)).
:- use_module(rlm_artifact).
:- use_module(rlm_agent,
              [ agent_send/5,
                agent_status/3
              ]).

rlm_artifact_agent_ready.

agent_artifact_publish(Runtime,
                       Agent,
                       Store,
                       Key,
                       Kind,
                       Value,
                       Provenance0,
                       Outcome) :-
    catch(agent_artifact_publish_(Runtime,
                                  Agent,
                                  Store,
                                  Key,
                                  Kind,
                                  Value,
                                  Provenance0,
                                  Outcome),
          Exception,
          agent_artifact_exception(publish, Exception, Outcome)).

agent_artifact_publish_(agent_runtime(RuntimeId),
                        agent(AgentId),
                        Store,
                        Key,
                        Kind,
                        Value,
                        Provenance0,
                        Outcome) :-
    !,
    require_dict(Provenance0, provenance),
    id_name(RuntimeId, RuntimeName),
    id_name(AgentId, AgentName),
    Namespace = [agent, RuntimeName, AgentName],
    Producer = _{producer_type:agent,
                 runtime_id:RuntimeId,
                 agent_id:AgentId},
    put_dict(Producer, Provenance0, Provenance),
    artifact_put(Store,
                 Namespace,
                 Key,
                 Kind,
                 Value,
                 Provenance,
                 PutOutcome),
    attach_agent_ref(PutOutcome,
                     agent_runtime(RuntimeId),
                     agent(AgentId),
                     RuntimeId,
                     Outcome).
agent_artifact_publish_(Runtime, Agent, _, _, _, _, _, _) :-
    throw(agent_artifact_fault(invalid_handles(Runtime, Agent))).

attach_agent_ref(error(Error), _, _, _, error(Error)) :- !.
attach_agent_ref(ok(Artifact), Runtime, Agent, RuntimeId, Outcome) :-
    Ref = Artifact.ref,
    agent_send(Runtime,
               Agent,
               checkpoint(RuntimeId, artifact(Ref)),
               [],
               SendOutcome),
    (   SendOutcome = ok(Send)
    ->  Outcome = ok(agent_artifact{
                         artifact:Artifact,
                         attachment:Send,
                         checkpoint:artifact(Ref)
                     })
    ;   SendOutcome = error(Error),
        Outcome = error(artifact_error{
                            phase:agent_integration,
                            kind:attachment_failed,
                            artifact:Ref,
                            cause:Error,
                            message:"artifact persisted but agent checkpoint attachment failed"})
    ).

agent_artifact_refs(Runtime, Agent, Outcome) :-
    catch(agent_artifact_refs_(Runtime, Agent, Outcome),
          Exception,
          agent_artifact_exception(refs, Exception, Outcome)).

agent_artifact_refs_(Runtime, Agent, Outcome) :-
    agent_status(Runtime, Agent, StatusOutcome),
    (   StatusOutcome = ok(Status)
    ->  findall(Ref,
                member(artifact(Ref), Status.checkpoints),
                Refs0),
        sort(Refs0, Refs),
        Outcome = ok(Refs)
    ;   StatusOutcome = error(Error),
        Outcome = error(Error)
    ).

agent_artifact_context(Runtime, Agent, Store, Options, Outcome) :-
    catch(agent_artifact_context_(Runtime,
                                  Agent,
                                  Store,
                                  Options,
                                  Outcome),
          Exception,
          agent_artifact_exception(context, Exception, Outcome)).

agent_artifact_context_(agent_runtime(RuntimeId),
                        agent(AgentId),
                        Store,
                        Options,
                        Outcome) :-
    !,
    require_options(Options),
    agent_artifact_refs(agent_runtime(RuntimeId),
                        agent(AgentId),
                        RefsOutcome),
    (   RefsOutcome = ok(Refs)
    ->  option(call_id(CallId), Options, none),
        Consumer = _{consumer_type:agent,
                     runtime_id:RuntimeId,
                     agent_id:AgentId,
                     call_id:CallId},
        artifact_context_refs(Store,
                              Refs,
                              [consumer(Consumer)|Options],
                              Outcome)
    ;   RefsOutcome = error(Error),
        Outcome = error(Error)
    ).
agent_artifact_context_(Runtime, Agent, _, _, _) :-
    throw(agent_artifact_fault(invalid_handles(Runtime, Agent))).

require_dict(Value, _) :- is_dict(Value), !.
require_dict(Value, Name) :-
    throw(agent_artifact_fault(expected_dict(Name, Value))).

require_options(Options) :- is_list(Options), !.
require_options(Options) :-
    throw(agent_artifact_fault(invalid_options(Options))).

id_name(Value, Value) :- atom(Value), Value \== '', !.
id_name(Value, Name) :- string(Value), Value \== "", !, atom_string(Name, Value).
id_name(Value, Name) :- number(Value), !, term_to_atom(Value, Name).
id_name(Value, Name) :-
    ground(Value),
    !,
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    atom_string(Name, Text).
id_name(Value, _) :-
    throw(agent_artifact_fault(invalid_identifier(Value))).

agent_artifact_exception(_, agent_artifact_fault(Detail), error(Error)) :-
    !,
    Error = artifact_error{phase:agent_integration,
                           kind:invalid_agent_artifact_request,
                           detail:Detail,
                           message:"agent artifact integration request is invalid"}.
agent_artifact_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = artifact_error{phase:agent_integration,
                           kind:exception,
                           operation:Operation,
                           exception:Safe,
                           message:"agent artifact integration raised an exception"}.
