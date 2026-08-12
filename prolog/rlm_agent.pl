:- module(rlm_agent,
          [ rlm_agent_ready/0,
            default_agent_options/1,
            agent_runtime_create/2,
            agent_runtime_destroy/1,
            agent_runtime_status/2,
            agent_spawn/5,
            agent_send/5,
            agent_pump/4,
            agent_status/3,
            agent_children/3,
            agent_cancel/4,
            agent_trace/2,
            agent_plan_handler/5,
            agent_tool_handler/4
          ]).

/** <module> Supervised logical agent runtime

Logical agents keep their mutable state inside SWI-Prolog engines.  Engines are
not permanently attached to operating-system threads; the supervisor drives an
engine only while it is processing one mailbox message.  Blocking host work is
moved onto one bounded thread pool shared by every logical agent in a runtime.

Mailboxes are finite SWI message queues.  A full mailbox therefore produces an
explicit backpressure outcome instead of allowing unbounded message growth.
Capabilities are inherited by subset: a child may drop parent authority but can
never add authority the parent did not have.
*/

:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(option)).
:- use_module(library(thread_pool)).
:- use_module(rlm_tool,
              [ capabilities_normalize/2,
                capabilities_narrow/3
              ]).

:- dynamic agent_runtime_record/3.
:- dynamic agent_record/7.
:- dynamic agent_worker/4.
:- dynamic agent_trace_sequence/2.
:- dynamic agent_trace_event/3.

rlm_agent_ready.

default_agent_options(
    agent_options{max_agents:64,
                  mailbox_size:16,
                  worker_count:2,
                  worker_backlog:8,
                  send_timeout:0.0,
                  trace_limit:256,
                  root_capabilities:[],
                  worker_handler:none}).

/* -------------------------------------------------------------------------
 * Runtime lifecycle
 * ---------------------------------------------------------------------- */

agent_runtime_create(Options, Runtime) :-
    catch(agent_runtime_create_(Options, Runtime),
          Exception,
          throw(error(agent_runtime_create_failed(Exception),
                      context(rlm_agent:agent_runtime_create/2,
                              'failed to create supervised agent runtime')))).

agent_runtime_create_(Options, agent_runtime(Id)) :-
    normalize_runtime_options(Options, Config),
    with_mutex(rlm_agent_registry,
               ( gensym(agent_runtime_, Id),
                 gensym(rlm_agent_pool_, Pool),
                 thread_pool_create(Pool,
                                    Config.worker_count,
                                    [backlog(Config.worker_backlog)]),
                 assertz(agent_runtime_record(Id, Pool, Config)),
                 assertz(agent_trace_sequence(Id, 0))
               )),
    trace_add(Id, runtime_created,
              _{worker_count:Config.worker_count,
                mailbox_size:Config.mailbox_size,
                max_agents:Config.max_agents}).

agent_runtime_destroy(Runtime) :-
    (   runtime_record(Runtime, Id, Pool, _)
    ->  signal_runtime_workers(Id, runtime_destroyed),
        catch(thread_pool_destroy(Pool), _, true),
        destroy_runtime_agents(Id),
        with_mutex(rlm_agent_registry,
                   ( retractall(agent_worker(Id, _, _, _)),
                     retractall(agent_record(Id, _, _, _, _, _, _)),
                     retractall(agent_trace_event(Id, _, _)),
                     retractall(agent_trace_sequence(Id, _)),
                     retractall(agent_runtime_record(Id, _, _))
                   ))
    ;   true
    ).

agent_runtime_status(Runtime, Status) :-
    runtime_record(Runtime, Id, Pool, Config),
    runtime_agent_count(Id, AgentCount),
    pool_property_default(Pool, size, Config.worker_count, PoolSize),
    pool_property_default(Pool, running, 0, Running),
    pool_property_default(Pool, backlog, 0, Backlog),
    Status = agent_runtime_status{runtime:Runtime,
                                  agent_count:AgentCount,
                                  max_agents:Config.max_agents,
                                  worker_pool:Pool,
                                  worker_pool_size:PoolSize,
                                  worker_running:Running,
                                  worker_backlog:Backlog,
                                  mailbox_size:Config.mailbox_size}.

pool_property_default(Pool, Name, Default, Value) :-
    Property =.. [Name, Candidate],
    (   catch(thread_pool_property(Pool, Property), _, fail)
    ->  Value = Candidate
    ;   Value = Default
    ).

normalize_runtime_options(Options, Config) :-
    (   is_list(Options)
    ->  true
    ;   throw(agent_fault(invalid_runtime_options(Options)))
    ),
    default_agent_options(Default),
    option(max_agents(MaxAgents), Options, Default.max_agents),
    option(mailbox_size(MailboxSize), Options, Default.mailbox_size),
    option(worker_count(WorkerCount), Options, Default.worker_count),
    option(worker_backlog(WorkerBacklog), Options, Default.worker_backlog),
    option(send_timeout(SendTimeout), Options, Default.send_timeout),
    option(trace_limit(TraceLimit), Options, Default.trace_limit),
    option(root_capabilities(Root0), Options, Default.root_capabilities),
    option(worker_handler(WorkerHandler), Options, Default.worker_handler),
    require_positive_integer(MaxAgents, max_agents),
    require_positive_integer(MailboxSize, mailbox_size),
    require_positive_integer(WorkerCount, worker_count),
    require_nonnegative_integer(WorkerBacklog, worker_backlog),
    require_nonnegative_number(SendTimeout, send_timeout),
    require_positive_integer(TraceLimit, trace_limit),
    capabilities_normalize(Root0, RootOutcome),
    require_capability_outcome(RootOutcome, RootCapabilities),
    require_worker_handler(WorkerHandler),
    Config = agent_options{max_agents:MaxAgents,
                           mailbox_size:MailboxSize,
                           worker_count:WorkerCount,
                           worker_backlog:WorkerBacklog,
                           send_timeout:SendTimeout,
                           trace_limit:TraceLimit,
                           root_capabilities:RootCapabilities,
                           worker_handler:WorkerHandler}.

require_worker_handler(none) :- !.
require_worker_handler(Handler) :-
    callable(Handler),
    !.
require_worker_handler(Handler) :-
    throw(agent_fault(invalid_worker_handler(Handler))).

/* -------------------------------------------------------------------------
 * Spawn and supervision
 * ---------------------------------------------------------------------- */

agent_spawn(Runtime, Parent, Spec0, RequestedCapabilities, Outcome) :-
    catch(agent_spawn_(Runtime,
                       Parent,
                       Spec0,
                       RequestedCapabilities,
                       Outcome),
          Exception,
          agent_api_exception(spawn, Exception, Outcome)).

agent_spawn_(Runtime, Parent, Spec0, RequestedCapabilities, Outcome) :-
    runtime_record(Runtime, RuntimeId, _, Config),
    normalize_agent_spec(Spec0, Spec),
    parent_authority(RuntimeId, Parent, Config, ParentCapabilities, ParentId),
    capabilities_narrow(ParentCapabilities, RequestedCapabilities, NarrowOutcome),
    spawn_after_narrowing(NarrowOutcome,
                          RuntimeId,
                          ParentId,
                          Spec,
                          Config,
                          Outcome).

spawn_after_narrowing(error(Error), _, _, _, _, error(AgentError)) :-
    !,
    AgentError = agent_error{phase:spawn,
                             kind:capability_denied,
                             cause:Error,
                             message:"child capabilities exceed parent authority"}.
spawn_after_narrowing(ok(Capabilities), RuntimeId, ParentId, Spec, Config,
                      Outcome) :-
    with_mutex(rlm_agent_registry,
               spawn_locked(RuntimeId,
                            ParentId,
                            Spec,
                            Capabilities,
                            Config,
                            Outcome)).

spawn_locked(RuntimeId, _, _, _, Config, error(Error)) :-
    runtime_agent_count(RuntimeId, Count),
    Count >= Config.max_agents,
    !,
    Error = agent_error{phase:spawn,
                        kind:agent_limit_reached,
                        limit:Config.max_agents,
                        message:"logical agent limit reached"}.
spawn_locked(RuntimeId, ParentId, Spec, Capabilities, Config, ok(agent(Id))) :-
    gensym(agent_, Id),
    message_queue_create(Queue, [max_size(Config.mailbox_size)]),
    Initial = agent_state{id:Id,
                          runtime:RuntimeId,
                          parent:ParentId,
                          status:active,
                          pending:[],
                          checkpoints:[],
                          last_result:none,
                          processed:0},
    catch(engine_create(_, agent_state_loop(Initial), Engine),
          Exception,
          ( message_queue_destroy(Queue),
            throw(Exception)
          )),
    assertz(agent_record(RuntimeId,
                         Id,
                         ParentId,
                         Engine,
                         Queue,
                         Capabilities,
                         Spec)),
    trace_add(RuntimeId,
              spawn,
              _{agent:Id,
                parent:ParentId,
                capabilities:Capabilities,
                spec:Spec}),
    notify_parent_spawn(RuntimeId, ParentId, Id, Spec, Capabilities).

parent_authority(_, none, Config, Config.root_capabilities, none) :- !.
parent_authority(RuntimeId, agent(ParentId), _, Capabilities, ParentId) :-
    !,
    (   agent_record(RuntimeId, ParentId, _, _, _, Capabilities, _)
    ->  true
    ;   throw(agent_fault(unknown_parent(agent(ParentId))))
    ).
parent_authority(_, Parent, _, _, _) :-
    throw(agent_fault(invalid_parent(Parent))).

notify_parent_spawn(_, none, _, _, _) :- !.
notify_parent_spawn(RuntimeId, ParentId, ChildId, Spec, Capabilities) :-
    internal_send(RuntimeId,
                  ParentId,
                  spawn(agent(ParentId), agent(ChildId), Spec, Capabilities),
                  _).

normalize_agent_spec(agent_spec(Name), Spec) :-
    !,
    require_name_atom(Name, Normalized),
    Spec = agent_spec{name:Normalized, mode:worker, metadata:_{}}.
normalize_agent_spec(Spec0, Spec) :-
    is_dict(Spec0),
    !,
    (   ground(Spec0)
    ->  true
    ;   throw(agent_fault(non_ground_agent_spec))
    ),
    dict_value_default(name, Spec0, anonymous, Name0),
    dict_value_default(mode, Spec0, worker, Mode0),
    dict_value_default(metadata, Spec0, _{}, Metadata),
    require_name_atom(Name0, Name),
    require_name_atom(Mode0, Mode),
    (   is_dict(Metadata), ground(Metadata)
    ->  true
    ;   throw(agent_fault(invalid_agent_metadata(Metadata)))
    ),
    Spec = agent_spec{name:Name, mode:Mode, metadata:Metadata}.
normalize_agent_spec(Spec, _) :-
    throw(agent_fault(invalid_agent_spec(Spec))).

/* -------------------------------------------------------------------------
 * Mailboxes and engine scheduling
 * ---------------------------------------------------------------------- */

agent_send(Runtime, Agent, Message, Options, Outcome) :-
    catch(agent_send_(Runtime, Agent, Message, Options, Outcome),
          Exception,
          agent_api_exception(send, Exception, Outcome)).

agent_send_(Runtime, agent(AgentId), Message, Options, Outcome) :-
    runtime_record(Runtime, RuntimeId, _, Config),
    agent_queue(RuntimeId, AgentId, Queue),
    validate_mailbox_message(Message),
    send_timeout(Options, Config.send_timeout, Timeout),
    (   thread_send_message(Queue, Message, [timeout(Timeout)])
    ->  trace_add(RuntimeId,
                  mailbox_enqueued,
                  _{agent:AgentId, message:Message}),
        Outcome = ok(agent_send{agent:agent(AgentId), status:queued})
    ;   message_queue_property(Queue, size(Size)),
        Outcome = error(agent_error{phase:send,
                                    kind:mailbox_full,
                                    agent:agent(AgentId),
                                    queue_size:Size,
                                    timeout:Timeout,
                                    message:"bounded mailbox rejected message"}),
        trace_add(RuntimeId,
                  mailbox_backpressure,
                  _{agent:AgentId, queue_size:Size})
    ).
agent_send_(_, Agent, _, _, _) :-
    throw(agent_fault(invalid_agent(Agent))).

agent_pump(Runtime, Agent, Options, Outcome) :-
    catch(agent_pump_(Runtime, Agent, Options, Outcome),
          Exception,
          agent_api_exception(pump, Exception, Outcome)).

agent_pump_(Runtime, agent(AgentId), Options, Outcome) :-
    runtime_record(Runtime, RuntimeId, _, Config),
    agent_handles(RuntimeId, AgentId, Engine, Queue),
    pump_timeout(Options, Timeout),
    (   thread_get_message(Queue, Message, [timeout(Timeout)])
    ->  engine_reply(Engine, deliver(Message), ReplyOutcome),
        pump_reply(ReplyOutcome,
                   RuntimeId,
                   AgentId,
                   Message,
                   Config,
                   Outcome)
    ;   Outcome = ok(agent_pump{agent:agent(AgentId), status:idle})
    ).
agent_pump_(_, Agent, _, _) :-
    throw(agent_fault(invalid_agent(Agent))).

pump_reply(error(Error), RuntimeId, AgentId, _, _, error(AgentError)) :-
    !,
    AgentError = agent_error{phase:pump,
                             kind:engine_failure,
                             agent:agent(AgentId),
                             cause:Error,
                             message:"agent engine failed while processing mailbox message"},
    trace_add(RuntimeId, engine_failure, _{agent:AgentId, cause:Error}).
pump_reply(ok(Reply), RuntimeId, AgentId, Message, Config, Outcome) :-
    is_dict(Reply),
    get_dict(kind, Reply, dispatch),
    !,
    get_dict(call_id, Reply, CallId),
    get_dict(work, Reply, Work),
    schedule_worker(RuntimeId,
                    AgentId,
                    CallId,
                    Work,
                    Config,
                    ScheduleOutcome),
    pump_after_schedule(ScheduleOutcome,
                        RuntimeId,
                        AgentId,
                        CallId,
                        Message,
                        Reply,
                        Outcome).
pump_reply(ok(Reply), RuntimeId, AgentId, Message, _, Outcome) :-
    trace_add(RuntimeId,
              message_processed,
              _{agent:AgentId, message:Message, reply:Reply}),
    notify_parent_from_reply(RuntimeId, AgentId, Reply),
    Outcome = ok(agent_pump{agent:agent(AgentId),
                            status:processed,
                            message:Message,
                            reply:Reply}).

pump_after_schedule(ok(Worker), RuntimeId, AgentId, _, Message, Reply,
                    ok(agent_pump{agent:agent(AgentId),
                                  status:dispatched,
                                  worker:Worker,
                                  message:Message,
                                  reply:Reply})) :-
    trace_add(RuntimeId,
              request_dispatched,
              _{agent:AgentId,
                call_id:Reply.call_id,
                worker:Worker}).
pump_after_schedule(error(Error), RuntimeId, AgentId, CallId, Message, _,
                    error(Error)) :-
    fail_pending_call(RuntimeId, AgentId, CallId, Error),
    trace_add(RuntimeId,
              worker_backpressure,
              _{agent:AgentId, call_id:CallId, cause:Error, message:Message}).

schedule_worker(RuntimeId, AgentId, CallId, Work, Config, Outcome) :-
    agent_runtime_record(RuntimeId, Pool, _),
    (   Config.worker_handler == none
    ->  Outcome = error(agent_error{phase:dispatch,
                                    kind:no_worker_handler,
                                    agent:agent(AgentId),
                                    call_id:CallId,
                                    message:"runtime has no trusted worker handler"})
    ;   catch(( thread_create_in_pool(
                    Pool,
                    rlm_agent:worker_entry(RuntimeId,
                                           AgentId,
                                           CallId,
                                           Work,
                                           Config.worker_handler,
                                           Config.send_timeout),
                    Thread,
                    [detached(true), wait(false)]),
                Created = ok(Thread)
              ),
              Exception,
              worker_create_exception(RuntimeId,
                                      AgentId,
                                      CallId,
                                      Exception,
                                      Created)),
        schedule_created_worker(Created,
                                RuntimeId,
                                AgentId,
                                CallId,
                                Outcome)
    ).

schedule_created_worker(error(Error), _, _, _, error(Error)) :- !.
schedule_created_worker(ok(Thread), RuntimeId, AgentId, CallId,
                        ok(worker(Thread))) :-
    assertz(agent_worker(RuntimeId, AgentId, CallId, Thread)),
    thread_send_message(Thread, rlm_agent_start).

worker_create_exception(_, AgentId, CallId,
                        error(resource_error(threads_in_pool(_)), _),
                        error(Error)) :-
    !,
    Error = agent_error{phase:dispatch,
                        kind:worker_pool_saturated,
                        agent:agent(AgentId),
                        call_id:CallId,
                        message:"bounded worker pool is saturated"}.
worker_create_exception(_, AgentId, CallId, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = agent_error{phase:dispatch,
                        kind:worker_start_failed,
                        agent:agent(AgentId),
                        call_id:CallId,
                        exception:Safe,
                        message:"worker thread could not be started"}.

worker_entry(RuntimeId, AgentId, CallId, Work, Handler, SendTimeout) :-
    setup_call_cleanup(
        true,
        worker_entry_run(RuntimeId,
                         AgentId,
                         CallId,
                         Work,
                         Handler,
                         SendTimeout),
        retractall(agent_worker(RuntimeId, AgentId, CallId, _))).

worker_entry_run(RuntimeId, AgentId, CallId, Work, Handler, SendTimeout) :-
    catch(( thread_get_message(rlm_agent_start),
            worker_call(Handler, Work, Result)
          ),
          Exception,
          worker_exception(Exception, Result)),
    trace_add(RuntimeId,
              worker_completed,
              _{agent:AgentId, call_id:CallId, result:Result}),
    worker_deliver_result(RuntimeId,
                          AgentId,
                          CallId,
                          Result,
                          SendTimeout).

worker_call(Handler, Work, Result) :-
    (   call(Handler, Work, Value)
    ->  Result = ok(Value)
    ;   Result = error(agent_error{phase:worker,
                                   kind:worker_failed,
                                   message:"trusted worker handler failed"})
    ).

worker_exception(agent_worker_cancelled(Reason),
                 error(agent_error{phase:worker,
                                   kind:cancelled,
                                   reason:Reason,
                                   message:"worker cancelled by supervisor"})) :-
    !.
worker_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = agent_error{phase:worker,
                        kind:worker_exception,
                        exception:Safe,
                        message:"trusted worker handler raised an exception"}.

worker_deliver_result(RuntimeId, AgentId, CallId, Result, SendTimeout) :-
    (   agent_queue(RuntimeId, AgentId, Queue)
    ->  (   catch(thread_send_message(Queue,
                                      result(CallId, Result),
                                      [timeout(SendTimeout)]),
                  _,
                  fail)
        ->  trace_add(RuntimeId,
                      worker_result_enqueued,
                      _{agent:AgentId, call_id:CallId})
        ;   force_agent_failure(RuntimeId,
                                AgentId,
                                worker_result_backpressure(CallId))
        )
    ;   true
    ).

fail_pending_call(RuntimeId, AgentId, CallId, Error) :-
    (   agent_engine(RuntimeId, AgentId, Engine)
    ->  engine_reply(Engine, deliver(result(CallId, error(Error))), Reply),
        (   Reply = ok(Value)
        ->  notify_parent_from_reply(RuntimeId, AgentId, Value)
        ;   true
        )
    ;   true
    ).

force_agent_failure(RuntimeId, AgentId, Kind) :-
    (   agent_engine(RuntimeId, AgentId, Engine)
    ->  engine_reply(Engine,
                     deliver(budget_exhausted(RuntimeId, Kind)),
                     Reply),
        trace_add(RuntimeId,
                  agent_failed,
                  _{agent:AgentId, cause:Kind}),
        (   Reply = ok(Value)
        ->  notify_parent_from_reply(RuntimeId, AgentId, Value)
        ;   true
        )
    ;   true
    ).

/* -------------------------------------------------------------------------
 * Engine state machine
 * ---------------------------------------------------------------------- */

agent_state_loop(State0) :-
    engine_fetch(Command),
    catch(agent_transition(Command, State0, Reply, State),
          Exception,
          transition_exception(Exception, State0, Reply, State)),
    engine_yield(Reply),
    agent_state_loop(State).

agent_transition(inspect, State, agent_reply{kind:state, state:State}, State) :-
    !.
agent_transition(deliver(Message), State0, Reply, State) :-
    !,
    transition_message(Message, State0, Reply, State).
agent_transition(Command, State,
                 agent_reply{kind:rejected,
                             reason:invalid_engine_command(Command)},
                 State).

transition_message(request(RunId, CallId, Work), State0, Reply, State) :-
    !,
    require_matching_run(RunId, State0),
    require_active_state(State0),
    get_dict(pending, State0, Pending0),
    (   memberchk(CallId, Pending0)
    ->  Reply = agent_reply{kind:rejected,
                            reason:duplicate_call(CallId)},
        State = State0
    ;   put_dict(pending, State0, [CallId|Pending0], State1),
        increment_processed(State1, State),
        Reply = agent_reply{kind:dispatch,
                            call_id:CallId,
                            work:Work}
    ).
transition_message(result(child(Child), Result), State0, Reply, State) :-
    !,
    put_dict(last_result,
             State0,
             child_result{child:Child, result:Result},
             State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:child_result,
                        child:Child,
                        result:Result}.
transition_message(result(CallId, Result), State0, Reply, State) :-
    !,
    get_dict(pending, State0, Pending0),
    (   select(CallId, Pending0, Pending)
    ->  put_dict(_{pending:Pending, last_result:Result}, State0, State1),
        transition_worker_result(Result, CallId, State1, Reply, State)
    ;   Reply = agent_reply{kind:rejected,
                            reason:unknown_call(CallId)},
        State = State0
    ).
transition_message(spawn(_, Child, Spec, Capabilities), State0, Reply, State) :-
    !,
    increment_processed(State0, State),
    Reply = agent_reply{kind:child_spawned,
                        child:Child,
                        spec:Spec,
                        capabilities:Capabilities}.
transition_message(cancel(RunId, Reason), State0, Reply, State) :-
    !,
    require_matching_run(RunId, State0),
    put_dict(status, State0, cancelled(Reason), State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:cancelled, reason:Reason}.
transition_message(checkpoint(RunId, Label), State0, Reply, State) :-
    !,
    require_matching_run(RunId, State0),
    get_dict(checkpoints, State0, Checkpoints0),
    put_dict(checkpoints, State0, [Label|Checkpoints0], State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:checkpoint, label:Label}.
transition_message(budget_exhausted(RunId, Kind), State0, Reply, State) :-
    !,
    require_matching_run(RunId, State0),
    Failure = resource_exhausted(Kind),
    put_dict(status, State0, failed(Failure), State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:failed, error:Failure}.
transition_message(complete(Value), State0, Reply, State) :-
    !,
    put_dict(_{status:completed, last_result:Value}, State0, State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:completed, value:Value}.
transition_message(Message, State,
                   agent_reply{kind:rejected,
                               reason:invalid_message(Message)},
                   State).

transition_worker_result(ok(Value), CallId, State0, Reply, State) :-
    !,
    increment_processed(State0, State),
    Reply = agent_reply{kind:result, call_id:CallId, value:Value}.
transition_worker_result(error(Error), CallId, State0, Reply, State) :-
    !,
    put_dict(status, State0, failed(Error), State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:failed, call_id:CallId, error:Error}.
transition_worker_result(Result, CallId, State0, Reply, State) :-
    put_dict(status, State0, failed(invalid_worker_result(Result)), State1),
    increment_processed(State1, State),
    Reply = agent_reply{kind:failed,
                        call_id:CallId,
                        error:invalid_worker_result(Result)}.

increment_processed(State0, State) :-
    Value is State0.processed+1,
    put_dict(processed, State0, Value, State).

transition_exception(Exception, State0, Reply, State) :-
    safe_exception(Exception, Safe),
    put_dict(status, State0, failed(engine_exception(Safe)), State),
    Reply = agent_reply{kind:failed, error:engine_exception(Safe)}.

require_matching_run(RunId, State) :-
    (   RunId == State.runtime
    ->  true
    ;   throw(agent_fault(run_id_mismatch(RunId, State.runtime)))
    ).

require_active_state(State) :-
    (   State.status == active
    ->  true
    ;   throw(agent_fault(agent_not_active(State.status)))
    ).

engine_reply(Engine, Command, Outcome) :-
    catch(( engine_post(Engine, Command, Reply)
          -> Outcome = ok(Reply)
          ;  Outcome = error(agent_error{phase:engine,
                                         kind:engine_stopped,
                                         message:"agent engine stopped"})
          ),
          Exception,
          engine_exception_outcome(Exception, Outcome)).

engine_exception_outcome(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = agent_error{phase:engine,
                        kind:engine_exception,
                        exception:Safe,
                        message:"agent engine raised an exception"}.

/* -------------------------------------------------------------------------
 * Status, children, cancellation
 * ---------------------------------------------------------------------- */

agent_status(Runtime, agent(AgentId), Outcome) :-
    catch(agent_status_(Runtime, AgentId, Outcome),
          Exception,
          agent_api_exception(status, Exception, Outcome)).

agent_status_(Runtime, AgentId, Outcome) :-
    runtime_record(Runtime, RuntimeId, _, _),
    agent_record(RuntimeId,
                 AgentId,
                 ParentId,
                 Engine,
                 Queue,
                 Capabilities,
                 Spec),
    engine_reply(Engine, inspect, EngineOutcome),
    status_after_engine(EngineOutcome,
                        RuntimeId,
                        AgentId,
                        ParentId,
                        Queue,
                        Capabilities,
                        Spec,
                        Outcome).

status_after_engine(error(Error), _, _, _, _, _, _, error(Error)) :- !.
status_after_engine(ok(Reply), RuntimeId, AgentId, ParentId, Queue,
                    Capabilities, Spec, ok(Status)) :-
    Reply = agent_reply{kind:state, state:State},
    message_queue_property(Queue, size(QueueSize)),
    findall(worker(CallId, Thread),
            agent_worker(RuntimeId, AgentId, CallId, Thread),
            Workers),
    agent_children(agent_runtime(RuntimeId), agent(AgentId), Children),
    Status = agent_status{agent:agent(AgentId),
                          parent:ParentId,
                          status:State.status,
                          pending:State.pending,
                          checkpoints:State.checkpoints,
                          last_result:State.last_result,
                          processed:State.processed,
                          capabilities:Capabilities,
                          spec:Spec,
                          mailbox_size:QueueSize,
                          workers:Workers,
                          children:Children}.

agent_children(Runtime, agent(AgentId), Children) :-
    runtime_record(Runtime, RuntimeId, _, _),
    findall(agent(ChildId),
            agent_record(RuntimeId, ChildId, AgentId, _, _, _, _),
            Children0),
    sort(Children0, Children).

agent_cancel(Runtime, agent(AgentId), Reason, Outcome) :-
    catch(agent_cancel_(Runtime, AgentId, Reason, Outcome),
          Exception,
          agent_api_exception(cancel, Exception, Outcome)).

agent_cancel_(Runtime, AgentId, Reason, Outcome) :-
    runtime_record(Runtime, RuntimeId, _, _),
    (   agent_record(RuntimeId, AgentId, _, Engine, _, _, _)
    ->  agent_children(Runtime, agent(AgentId), Children),
        cancel_children(Runtime, Children, Reason),
        signal_agent_workers(RuntimeId, AgentId, Reason),
        engine_reply(Engine, deliver(cancel(RuntimeId, Reason)), Reply),
        trace_add(RuntimeId, cancel, _{agent:AgentId, reason:Reason}),
        cancel_reply(Reply, AgentId, Outcome)
    ;   Outcome = error(agent_error{phase:cancel,
                                    kind:unknown_agent,
                                    agent:agent(AgentId),
                                    message:"agent is not registered"})
    ).

cancel_children(_, [], _).
cancel_children(Runtime, [Child|Children], Reason) :-
    agent_cancel(Runtime, Child, Reason, _),
    cancel_children(Runtime, Children, Reason).

cancel_reply(error(Error), _, error(Error)) :- !.
cancel_reply(ok(Reply), AgentId,
             ok(agent_cancel{agent:agent(AgentId), reply:Reply})).

signal_runtime_workers(RuntimeId, Reason) :-
    forall(agent_worker(RuntimeId, _, _, Thread),
           signal_worker(Thread, Reason)).

signal_agent_workers(RuntimeId, AgentId, Reason) :-
    forall(agent_worker(RuntimeId, AgentId, _, Thread),
           signal_worker(Thread, Reason)).

signal_worker(Thread, Reason) :-
    catch(thread_signal(Thread, throw(agent_worker_cancelled(Reason))), _, true).

notify_parent_from_reply(RuntimeId, AgentId, Reply) :-
    is_dict(Reply),
    get_dict(kind, Reply, failed),
    get_dict(error, Reply, Error),
    !,
    (   agent_record(RuntimeId, AgentId, ParentId, _, _, _, _),
        ParentId \== none
    ->  internal_send(RuntimeId,
                      ParentId,
                      result(child(agent(AgentId)), error(Error)),
                      _),
        trace_add(RuntimeId,
                  child_failure,
                  _{parent:ParentId, child:AgentId, error:Error})
    ;   true
    ).
notify_parent_from_reply(_, _, _).

/* -------------------------------------------------------------------------
 * Plan adapter
 * ---------------------------------------------------------------------- */

agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child) :-
    agent_spawn(Runtime, Parent, Spec, Capabilities, Outcome),
    (   Outcome = ok(Child)
    ->  true
    ;   Outcome = error(Error),
        throw(error(agent_spawn_failed(Error),
                    context(rlm_agent:agent_plan_handler/5,
                            'typed plan could not spawn child agent')))
    ).

agent_tool_handler(Runtime, Parent, Request, Child) :-
    normalize_agent_tool_request(Request, Spec, Capabilities),
    agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child).

normalize_agent_tool_request(Request, Spec, Capabilities) :-
    (   is_dict(Request),
        get_dict(spec, Request, Spec),
        get_dict(capabilities, Request, RawCapabilities),
        is_list(RawCapabilities)
    ->  maplist(normalize_agent_tool_capability,
                RawCapabilities,
                Capabilities)
    ;   throw(agent_fault(invalid_agent_spawn_request(Request)))
    ).

normalize_agent_tool_capability(Value, Capability) :-
    capabilities_normalize([Value], ok([Capability])),
    !.
normalize_agent_tool_capability(Value, Capability) :-
    (atom(Value); string(Value)),
    !,
    require_name_atom(Value, Atom),
    (   capabilities_normalize([Atom], ok([Capability]))
    ->  true
    ;   throw(agent_fault(invalid_child_capability(Value)))
    ).
normalize_agent_tool_capability(Value, Capability) :-
    is_dict(Value),
    !,
    (   get_dict(type, Value, Type0),
        get_dict(name, Value, Name0)
    ->  require_name_atom(Type0, Type),
        require_name_atom(Name0, Name),
        Term =.. [Type, Name],
        (   capabilities_normalize([Term], ok([Capability]))
        ->  true
        ;   throw(agent_fault(invalid_child_capability(Value)))
        )
    ;   throw(agent_fault(invalid_child_capability(Value)))
    ).
normalize_agent_tool_capability(Value, _) :-
    throw(agent_fault(invalid_child_capability(Value))).

/* -------------------------------------------------------------------------
 * Trace
 * ---------------------------------------------------------------------- */

agent_trace(Runtime, Events) :-
    runtime_record(Runtime, RuntimeId, _, _),
    findall(Seq-Event,
            agent_trace_event(RuntimeId, Seq, Event),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Events).

trace_add(RuntimeId, Type, Fields) :-
    (   agent_runtime_record(RuntimeId, _, Config)
    ->  with_mutex(rlm_agent_trace,
                   ( retract(agent_trace_sequence(RuntimeId, Seq0)),
                     Seq is Seq0+1,
                     assertz(agent_trace_sequence(RuntimeId, Seq)),
                     put_dict(_{sequence:Seq, type:Type},
                              Fields,
                              Event),
                     assertz(agent_trace_event(RuntimeId, Seq, Event)),
                     trim_trace(RuntimeId, Config.trace_limit)
                   ))
    ;   true
    ).

trim_trace(RuntimeId, Limit) :-
    findall(Seq, agent_trace_event(RuntimeId, Seq, _), Seqs0),
    sort(Seqs0, Seqs),
    length(Seqs, Count),
    Excess is Count-Limit,
    trim_oldest(RuntimeId, Excess, Seqs).

trim_oldest(_, Excess, _) :-
    Excess =< 0,
    !.
trim_oldest(_, _, []) :- !.
trim_oldest(RuntimeId, Excess, [Seq|Seqs]) :-
    retractall(agent_trace_event(RuntimeId, Seq, _)),
    Next is Excess-1,
    trim_oldest(RuntimeId, Next, Seqs).

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

runtime_record(agent_runtime(Id), Id, Pool, Config) :-
    agent_runtime_record(Id, Pool, Config),
    !.
runtime_record(Runtime, _, _, _) :-
    throw(agent_fault(unknown_runtime(Runtime))).

agent_handles(RuntimeId, AgentId, Engine, Queue) :-
    (   agent_record(RuntimeId, AgentId, _, Engine, Queue, _, _)
    ->  true
    ;   throw(agent_fault(unknown_agent(agent(AgentId))))
    ).

agent_queue(RuntimeId, AgentId, Queue) :-
    agent_record(RuntimeId, AgentId, _, _, Queue, _, _).

agent_engine(RuntimeId, AgentId, Engine) :-
    agent_record(RuntimeId, AgentId, _, Engine, _, _, _).

runtime_agent_count(RuntimeId, Count) :-
    findall(AgentId,
            agent_record(RuntimeId, AgentId, _, _, _, _, _),
            AgentIds),
    length(AgentIds, Count).

internal_send(RuntimeId, AgentId, Message, Outcome) :-
    (   agent_runtime_record(RuntimeId, _, Config),
        agent_queue(RuntimeId, AgentId, Queue)
    ->  (   thread_send_message(Queue,
                                Message,
                                [timeout(Config.send_timeout)])
        ->  Outcome = ok
        ;   Outcome = error(mailbox_full)
        )
    ;   Outcome = error(unknown_agent)
    ).

validate_mailbox_message(Message) :-
    (   ground(Message), mailbox_message_shape(Message)
    ->  true
    ;   throw(agent_fault(invalid_mailbox_message(Message)))
    ).

mailbox_message_shape(request(RunId, CallId, work(Type, _))) :-
    nonvar(RunId), nonvar(CallId), atom(Type), !.
mailbox_message_shape(result(CallId, _)) :-
    nonvar(CallId), !.
mailbox_message_shape(spawn(Parent, Child, Spec, Capabilities)) :-
    nonvar(Parent), nonvar(Child), ground(Spec), is_list(Capabilities), !.
mailbox_message_shape(cancel(RunId, _)) :- nonvar(RunId), !.
mailbox_message_shape(checkpoint(RunId, Label)) :-
    nonvar(RunId), nonvar(Label), !.
mailbox_message_shape(budget_exhausted(RunId, Kind)) :-
    nonvar(RunId), nonvar(Kind), !.
mailbox_message_shape(complete(_)).

send_timeout(Options, Default, Timeout) :-
    (   is_list(Options)
    ->  option(timeout(Timeout0), Options, Default)
    ;   throw(agent_fault(invalid_send_options(Options)))
    ),
    require_nonnegative_number(Timeout0, timeout),
    Timeout = Timeout0.

pump_timeout(Options, Timeout) :-
    (   is_list(Options)
    ->  option(timeout(Timeout0), Options, 0.0)
    ;   throw(agent_fault(invalid_pump_options(Options)))
    ),
    require_nonnegative_number(Timeout0, timeout),
    Timeout = Timeout0.

require_capability_outcome(ok(Value), Value) :- !.
require_capability_outcome(error(Error), _) :-
    throw(agent_fault(invalid_capabilities(Error))).

require_positive_integer(Value, _) :-
    integer(Value), Value > 0,
    !.
require_positive_integer(Value, Name) :-
    throw(agent_fault(invalid_option(Name, Value))).

require_nonnegative_integer(Value, _) :-
    integer(Value), Value >= 0,
    !.
require_nonnegative_integer(Value, Name) :-
    throw(agent_fault(invalid_option(Name, Value))).

require_nonnegative_number(Value, _) :-
    number(Value), Value >= 0,
    !.
require_nonnegative_number(Value, Name) :-
    throw(agent_fault(invalid_option(Name, Value))).

require_name_atom(Value, Atom) :-
    atom(Value), Value \== '',
    !,
    Atom = Value.
require_name_atom(Value, Atom) :-
    string(Value), Value \== "",
    !,
    atom_string(Atom, Value).
require_name_atom(Value, _) :-
    throw(agent_fault(invalid_name(Value))).

dict_value_default(Key, Dict, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).

destroy_runtime_agents(RuntimeId) :-
    findall(agent_data(AgentId, Engine, Queue),
            agent_record(RuntimeId, AgentId, _, Engine, Queue, _, _),
            Agents),
    maplist(destroy_agent_data, Agents).

destroy_agent_data(agent_data(_, Engine, Queue)) :-
    catch(engine_destroy(Engine), _, true),
    catch(message_queue_destroy(Queue), _, true).

agent_api_exception(Phase, agent_fault(Fault), error(Error)) :-
    !,
    Error = agent_error{phase:Phase,
                        kind:invalid_request,
                        detail:Fault,
                        message:"agent runtime request is invalid"}.
agent_api_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = agent_error{phase:Phase,
                        kind:exception,
                        exception:Safe,
                        message:"agent runtime operation raised an exception"}.

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
