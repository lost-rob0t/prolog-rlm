:- module(rlm_async,
          [ rlm_async_ready/0,
            rlm_async_runtime_status/1,
            rlm_async_submit/2,
            rlm_async_submit/3,
            rlm_future_deferred/2,
            rlm_future_resolve/2,
            rlm_async_current_metadata/1,
            rlm_future_status/2,
            rlm_future_await/2,
            rlm_future_await/3,
            rlm_future_cancel/2,
            rlm_future_destroy/1,
            rlm_future_all/2,
            rlm_future_then/3,
            rlm_future_on_complete/2,
            rlm_future_metadata/2
          ]).

/** <module> Bounded asynchronous task runtime for prolog-rlm

The scheduler owns a fixed worker pool and finite backlog. Futures are opaque
handles over task state; domain libraries submit canonical operation predicates
and synchronous facades wait on the same Future rather than implementing a
second execution path.

Continuation registration is event driven. A continuation is enqueued only
after its parent reaches a terminal state, so composed Futures do not consume
worker threads merely waiting for other Futures.

Deferred Futures are host/library promises with no queued worker. They exist for
external-latency events such as human approval. Trusted library code resolves a
deferred Future later with rlm_future_resolve/2; callbacks and continuations are
then dispatched through the same terminal-state machinery as ordinary tasks.
*/

:- use_module(library(gensym)).

:- meta_predicate rlm_async_submit(1, -).
:- meta_predicate rlm_async_submit(1, +, -).
:- meta_predicate rlm_future_then(+, 2, -).
:- meta_predicate rlm_future_on_complete(+, 1).

:- dynamic async_runtime/3.
:- dynamic async_future_state/2.
:- dynamic async_future_thread/2.
:- dynamic async_future_metadata/2.
:- dynamic async_future_callback/2.
:- dynamic async_future_continuation/3.
:- dynamic async_future_child/2.
:- thread_local async_current_future/1.

default_async_worker_count(8).
default_async_backlog(64).

rlm_async_ready :-
    current_prolog_flag(threads, true).

/* Runtime ---------------------------------------------------------------- */

rlm_async_runtime_status(Status) :-
    ensure_async_runtime(Queue),
    with_mutex(rlm_async,
               async_state_counts(Pending, Running, Completed, Cancelled)),
    (   catch(message_queue_property(Queue, size(Queued0)), _, fail)
    ->  Queued = Queued0
    ;   Queued = 0
    ),
    async_runtime(Queue, Workers, Backlog),
    length(Workers, WorkerCount),
    Status = async_runtime_status{
                 worker_count:WorkerCount,
                 backlog_limit:Backlog,
                 queued:Queued,
                 pending:Pending,
                 running:Running,
                 completed:Completed,
                 cancelled:Cancelled
             }.

async_state_counts(Pending, Running, Completed, Cancelled) :-
    findall(State, async_future_state(_, State), States),
    count_state(pending, States, Pending),
    count_state(running, States, Running),
    findall(1, member(completed(_), States), CompletedOnes),
    length(CompletedOnes, Completed),
    count_state(cancelled, States, Cancelled).

count_state(Target, States, Count) :-
    findall(1, member(Target, States), Ones),
    length(Ones, Count).

ensure_async_runtime(Queue) :-
    with_mutex(rlm_async_runtime,
               ensure_async_runtime_locked(Queue)).

ensure_async_runtime_locked(Queue) :-
    async_runtime(Queue, _, _),
    !.
ensure_async_runtime_locked(Queue) :-
    default_async_worker_count(WorkerCount),
    default_async_backlog(Backlog),
    message_queue_create(Queue, [max_size(Backlog)]),
    catch(create_async_workers(WorkerCount, Queue, Workers),
          Exception,
          ( catch(message_queue_destroy(Queue), _, true),
            throw(Exception)
          )),
    assertz(async_runtime(Queue, Workers, Backlog)).

create_async_workers(0, _, []) :- !.
create_async_workers(Count, Queue, [Thread|Threads]) :-
    Count > 0,
    thread_create(rlm_async:async_worker_loop(Queue),
                  Thread,
                  [detached(true)]),
    Next is Count-1,
    create_async_workers(Next, Queue, Threads).

/* Submission ------------------------------------------------------------- */

rlm_async_submit(Goal, Future) :-
    rlm_async_submit(Goal, async_metadata{}, Future).

rlm_async_submit(Goal, Metadata0, Future) :-
    require_async_runtime,
    require_callable(Goal),
    require_metadata(Metadata0),
    ensure_async_runtime(Queue),
    current_parent_task(Parent),
    with_mutex(rlm_async,
               create_future_locked(Metadata0, Parent, Future, Id)),
    enqueue_future(Queue, Id, Goal).

rlm_future_deferred(Metadata0, Future) :-
    require_async_runtime,
    require_metadata(Metadata0),
    ensure_async_runtime(_),
    current_parent_task(Parent),
    with_mutex(rlm_async,
               create_future_locked(Metadata0, Parent, Future, _)).

rlm_future_resolve(Future, Outcome) :-
    future_id(Future, Id),
    async_store_completion(Id, Outcome).

rlm_async_current_metadata(Metadata) :-
    (   async_current_future(Id),
        with_mutex(rlm_async,
                   async_future_metadata(Id, Found))
    ->  Metadata = Found
    ;   Metadata = none
    ).

current_parent_task(Parent) :-
    async_current_future(Parent),
    !.
current_parent_task(none).

create_future_locked(Metadata0, Parent, rlm_future(Id), Id) :-
    gensym(rlm_future_, Id),
    get_time(CreatedAt),
    metadata_operation(Metadata0, Operation),
    put_dict(async_metadata{id:Id,
                            parent_task:Parent,
                            operation:Operation,
                            created_at:CreatedAt},
             Metadata0,
             Metadata),
    assertz(async_future_state(Id, pending)),
    assertz(async_future_metadata(Id, Metadata)),
    link_parent_child(Parent, Id).

metadata_operation(Metadata, Operation) :-
    (   get_dict(operation, Metadata, Found)
    ->  Operation = Found
    ;   Operation = generic
    ).

link_parent_child(none, _) :- !.
link_parent_child(Parent, Child) :-
    assertz(async_future_child(Parent, Child)).

enqueue_future(Queue, Id, Goal) :-
    (   thread_send_message(Queue,
                            async_task(Id, Goal),
                            [timeout(0)])
    ->  true
    ;   mark_backpressure(Id)
    ).

enqueue_existing_future(Id, Goal) :-
    ensure_async_runtime(Queue),
    enqueue_future(Queue, Id, Goal).

require_async_runtime :-
    rlm_async_ready,
    !.
require_async_runtime :-
    throw(error(resource_error(threads),
                context(rlm_async_submit/2,
                        'SWI-Prolog thread support is required'))).

require_callable(Goal) :-
    callable(Goal),
    !.
require_callable(Goal) :-
    throw(error(type_error(callable, Goal),
                context(rlm_async_submit/2,
                        'async goal must be callable'))).

require_metadata(Metadata) :-
    is_dict(Metadata),
    ground(Metadata),
    !.
require_metadata(Metadata) :-
    throw(error(type_error(async_metadata, Metadata),
                context(rlm_async_submit/3,
                        'task metadata must be a ground dict'))).

mark_backpressure(Id) :-
    Outcome = error(async_error{
                        kind:backpressure,
                        future:Id,
                        message:"asynchronous runtime backlog is full"
                    }),
    async_store_completion(Id, Outcome).

/* Workers ---------------------------------------------------------------- */

async_worker_loop(Queue) :-
    catch(async_worker_step(Queue, Continue),
          Exception,
          async_worker_step_exception(Exception, Continue)),
    (   Continue == stop
    ->  true
    ;   async_worker_loop(Queue)
    ).

async_worker_step(Queue, Continue) :-
    thread_get_message(Queue, Message),
    (   Message == stop
    ->  Continue = stop
    ;   Message = async_task(Id, Goal)
    ->  async_execute_task(Id, Goal),
        Continue = continue
    ;   Continue = continue
    ).

async_worker_step_exception(rlm_async_cancelled(_), continue) :- !.
async_worker_step_exception('$aborted', stop) :- !.
async_worker_step_exception(abort, stop) :- !.
async_worker_step_exception(Exception, continue) :-
    print_message(error, Exception).

async_execute_task(Id, Goal) :-
    thread_self(Thread),
    with_mutex(rlm_async,
               async_claim_task(Id, Thread, Claimed)),
    (   Claimed == true
    ->  setup_call_cleanup(
            asserta(async_current_future(Id)),
            catch(async_call_goal(Goal, Outcome),
                  Exception,
                  async_exception_outcome(Id, Exception, Outcome)),
            retractall(async_current_future(Id))),
        async_store_completion(Id, Outcome)
    ;   true
    ).

async_claim_task(Id, Thread, true) :-
    retract(async_future_state(Id, pending)),
    !,
    assertz(async_future_state(Id, running)),
    retractall(async_future_thread(Id, _)),
    assertz(async_future_thread(Id, Thread)).
async_claim_task(_, _, false).

async_call_goal(Goal, Outcome) :-
    (   call(Goal, Value)
    ->  Outcome = Value
    ;   Outcome = error(async_error{
                            kind:goal_failed,
                            message:"asynchronous goal failed without producing a result"
                        })
    ).

async_exception_outcome(Id, rlm_async_cancelled(Id),
                        error(async_error{
                                  kind:cancelled,
                                  future:Id,
                                  message:"asynchronous operation was cancelled"
                              })) :-
    !.
async_exception_outcome(_, Exception,
                        error(async_error{
                                  kind:control_exception,
                                  exception:Safe,
                                  exception_term:Exception,
                                  message:"asynchronous control exception crossed the Future boundary"
                              })) :-
    ground(Exception),
    async_control_exception(Exception),
    !,
    safe_exception(Exception, Safe).
async_exception_outcome(_, Exception,
                        error(async_error{
                                  kind:exception,
                                  exception:Safe,
                                  message:"asynchronous operation raised an exception"
                              })) :-
    safe_exception(Exception, Safe).

async_control_exception(time_limit_exceeded).
async_control_exception(time_limit_exceeded(_)).
async_control_exception('$aborted').
async_control_exception(abort).
async_control_exception(cancelled(_)).
async_control_exception(rlm_cancelled(_)).
async_control_exception(chain_cancelled(_)).
async_control_exception(graph_cancelled(_)).
async_control_exception(error(Exception, _)) :-
    async_control_exception(Exception).

async_store_completion(Id, Outcome) :-
    with_mutex(rlm_async,
               completion_transition_locked(Id,
                                            Outcome,
                                            Transition,
                                            Callbacks,
                                            Continuations)),
    run_completion_transition(Transition,
                              Outcome,
                              Callbacks,
                              Continuations).

completion_transition_locked(Id, _, ignored, [], []) :-
    \+ async_future_state(Id, _),
    !,
    retractall(async_future_thread(Id, _)).
completion_transition_locked(Id, _, ignored, [], []) :-
    async_future_state(Id, cancelled),
    !,
    retractall(async_future_thread(Id, _)).
completion_transition_locked(Id,
                             Outcome,
                             completed,
                             Callbacks,
                             Continuations) :-
    async_future_state(Id, State),
    memberchk(State, [pending, running]),
    !,
    retractall(async_future_thread(Id, _)),
    retractall(async_future_state(Id, _)),
    assertz(async_future_state(Id, completed(Outcome))),
    take_terminal_handlers_locked(Id, Callbacks, Continuations),
    retractall(async_future_child(Id, _)).
completion_transition_locked(_, _, ignored, [], []).

run_completion_transition(ignored, _, _, _) :- !.
run_completion_transition(completed, Outcome, Callbacks, Continuations) :-
    run_completion_callbacks(Callbacks, Outcome),
    schedule_continuations(Continuations, Outcome).

take_terminal_handlers_locked(Id, Callbacks, Continuations) :-
    findall(Callback, async_future_callback(Id, Callback), Callbacks),
    findall(continuation(Callback, NextId),
            async_future_continuation(Id, Callback, NextId),
            Continuations),
    retractall(async_future_callback(Id, _)),
    retractall(async_future_continuation(Id, _, _)),
    forall(member(continuation(_, NextId), Continuations),
           retractall(async_future_child(Id, NextId))).

run_completion_callbacks([], _).
run_completion_callbacks([Callback|Callbacks], Outcome) :-
    catch(call(Callback, Outcome), _, true),
    run_completion_callbacks(Callbacks, Outcome).

schedule_continuations([], _).
schedule_continuations([continuation(Callback, NextId)|Continuations], Outcome) :-
    enqueue_existing_future(NextId,
                            continuation_task(Callback, Outcome)),
    schedule_continuations(Continuations, Outcome).

continuation_task(Callback, ParentOutcome, Outcome) :-
    call(Callback, ParentOutcome, Outcome).

/* Status and await ------------------------------------------------------- */

rlm_future_status(Future, Status) :-
    future_id(Future, Id),
    with_mutex(rlm_async,
               future_state_snapshot(Id, State)),
    status_term(Id, State, Status).

future_state_snapshot(Id, State) :-
    (   async_future_state(Id, State0)
    ->  State = State0
    ;   throw(error(existence_error(rlm_future, rlm_future(Id)),
                    context(rlm_future_status/2,
                            'future does not exist or was destroyed')))
    ).

status_term(Id, pending, future_status{id:Id, state:pending}).
status_term(Id, running, future_status{id:Id, state:running}).
status_term(Id, cancelled, future_status{id:Id, state:cancelled}).
status_term(Id, completed(Outcome),
            future_status{id:Id, state:completed, outcome:Outcome}).

rlm_future_metadata(Future, Metadata) :-
    future_id(Future, Id),
    with_mutex(rlm_async,
               (   async_future_metadata(Id, Found)
               ->  Metadata = Found
               ;   throw(error(existence_error(rlm_future, Future),
                               context(rlm_future_metadata/2,
                                       'future does not exist or was destroyed')))
               )).

rlm_future_await(Future, Outcome) :-
    rlm_future_await(Future, infinite, Outcome).

rlm_future_await(Future, Timeout, Outcome) :-
    future_id(Future, Id),
    normalize_timeout(Timeout, Normalized),
    get_time(Start),
    await_loop(Id, Start, Normalized, Outcome).

await_loop(Id, Start, Timeout, Outcome) :-
    with_mutex(rlm_async,
               future_state_snapshot(Id, State)),
    await_state(State, Id, Start, Timeout, Outcome).

await_state(completed(error(Error)), _, _, _, _) :-
    is_dict(Error, async_error),
    get_dict(kind, Error, control_exception),
    get_dict(exception_term, Error, Exception),
    !,
    throw(Exception).
await_state(completed(StoredOutcome), _, _, _, Outcome) :-
    !,
    Outcome = StoredOutcome.
await_state(cancelled, Id, _, _, Outcome) :-
    !,
    cancellation_outcome(Id, Outcome).
await_state(_, Id, Start, Timeout, Outcome) :-
    (   await_timed_out(Start, Timeout)
    ->  Outcome = error(async_error{
                            kind:timeout,
                            future:Id,
                            message:"timed out waiting for asynchronous operation"
                        })
    ;   sleep(0.005),
        await_loop(Id, Start, Timeout, Outcome)
    ).

normalize_timeout(infinite, infinite) :- !.
normalize_timeout(Timeout, Timeout) :-
    number(Timeout),
    Timeout >= 0,
    !.
normalize_timeout(Timeout, _) :-
    throw(error(domain_error(async_timeout, Timeout),
                context(rlm_future_await/3,
                        'timeout must be infinite or a non-negative number'))).

await_timed_out(_, infinite) :- !, fail.
await_timed_out(Start, Timeout) :-
    get_time(Now),
    Elapsed is Now-Start,
    Elapsed >= Timeout.

/* Continuations ---------------------------------------------------------- */

rlm_future_on_complete(Future, Callback) :-
    require_callback(Callback, rlm_future_on_complete/2),
    future_id(Future, Id),
    with_mutex(rlm_async,
               register_completion_callback_locked(Id, Callback, Action)),
    apply_completion_callback_action(Action, Callback).

register_completion_callback_locked(Id, Callback, wait) :-
    async_future_state(Id, State),
    memberchk(State, [pending, running]),
    !,
    assertz(async_future_callback(Id, Callback)).
register_completion_callback_locked(Id, _, call(Outcome)) :-
    async_future_state(Id, completed(Outcome)),
    !.
register_completion_callback_locked(Id, _, call(Outcome)) :-
    async_future_state(Id, cancelled),
    !,
    cancellation_outcome(Id, Outcome).
register_completion_callback_locked(Id, _, _) :-
    throw(error(existence_error(rlm_future, rlm_future(Id)),
                context(rlm_future_on_complete/2,
                        'future does not exist or was destroyed'))).

apply_completion_callback_action(wait, _) :- !.
apply_completion_callback_action(call(Outcome), Callback) :-
    catch(call(Callback, Outcome), _, true).

rlm_future_then(Future, Callback, NextFuture) :-
    require_callback(Callback, rlm_future_then/3),
    future_id(Future, ParentId),
    with_mutex(rlm_async,
               register_continuation_locked(ParentId,
                                            Callback,
                                            NextFuture,
                                            NextId,
                                            Action)),
    apply_continuation_action(Action, Callback, NextId).

register_continuation_locked(ParentId,
                             Callback,
                             NextFuture,
                             NextId,
                             Action) :-
    (   async_future_state(ParentId, ParentState)
    ->  true
    ;   throw(error(existence_error(rlm_future, rlm_future(ParentId)),
                    context(rlm_future_then/3,
                            'future does not exist or was destroyed')))
    ),
    create_future_locked(async_metadata{operation:continuation},
                         ParentId,
                         NextFuture,
                         NextId),
    continuation_action_locked(ParentState,
                               ParentId,
                               Callback,
                               NextId,
                               Action).

continuation_action_locked(State, ParentId, Callback, NextId, wait) :-
    memberchk(State, [pending, running]),
    !,
    assertz(async_future_continuation(ParentId, Callback, NextId)).
continuation_action_locked(completed(Outcome), ParentId, _, NextId, run(Outcome)) :-
    !,
    retractall(async_future_child(ParentId, NextId)).
continuation_action_locked(cancelled, ParentId, _, NextId, cancel) :-
    retractall(async_future_child(ParentId, NextId)).

apply_continuation_action(wait, _, _) :- !.
apply_continuation_action(run(Outcome), Callback, NextId) :-
    enqueue_existing_future(NextId,
                            continuation_task(Callback, Outcome)).
apply_continuation_action(cancel, _, NextId) :-
    catch(rlm_future_cancel(rlm_future(NextId), _), _, true).

require_callback(Callback, _) :-
    callable(Callback),
    !.
require_callback(Callback, Context) :-
    throw(error(type_error(callable, Callback),
                context(Context,
                        'Future callback must be a host/library callable'))).

/* Cancellation and cleanup ---------------------------------------------- */

rlm_future_cancel(Future, Outcome) :-
    future_id(Future, Id),
    with_mutex(rlm_async,
               future_cancel_transition(Id,
                                        Transition,
                                        Thread,
                                        Callbacks,
                                        Children)),
    apply_cancel_transition(Id,
                            Transition,
                            Thread,
                            Callbacks,
                            Children,
                            Outcome).

future_cancel_transition(Id, already_completed, none, [], []) :-
    async_future_state(Id, completed(_)),
    !.
future_cancel_transition(Id, already_cancelled, none, [], []) :-
    async_future_state(Id, cancelled),
    !.
future_cancel_transition(Id, cancel, Thread, Callbacks, Children) :-
    async_future_state(Id, State),
    memberchk(State, [pending, running]),
    !,
    retractall(async_future_state(Id, _)),
    assertz(async_future_state(Id, cancelled)),
    (   async_future_thread(Id, Worker)
    ->  Thread = Worker
    ;   Thread = none
    ),
    findall(Callback, async_future_callback(Id, Callback), Callbacks),
    findall(Child, async_future_child(Id, Child), Children0),
    sort(Children0, Children),
    retractall(async_future_callback(Id, _)),
    retractall(async_future_continuation(Id, _, _)),
    retractall(async_future_child(Id, _)).
future_cancel_transition(Id, _, _, _, _) :-
    throw(error(existence_error(rlm_future, rlm_future(Id)),
                context(rlm_future_cancel/2,
                        'future does not exist or was destroyed'))).

apply_cancel_transition(_, already_completed, _, _, _, ok(already_completed)) :- !.
apply_cancel_transition(_, already_cancelled, _, _, _, ok(already_cancelled)) :- !.
apply_cancel_transition(Id, cancel, Thread, Callbacks, Children, ok(cancelled)) :-
    signal_async_cancel(Id, Thread),
    cancellation_outcome(Id, CancelOutcome),
    run_completion_callbacks(Callbacks, CancelOutcome),
    cancel_children(Children).

signal_async_cancel(_, none) :- !.
signal_async_cancel(Id, Thread) :-
    catch(thread_signal(Thread, throw(rlm_async_cancelled(Id))), _, true).

cancel_children([]).
cancel_children([Child|Children]) :-
    catch(rlm_future_cancel(rlm_future(Child), _), _, true),
    cancel_children(Children).

cancellation_outcome(Id,
                     error(async_error{
                               kind:cancelled,
                               future:Id,
                               message:"asynchronous operation was cancelled"
                           })).

rlm_future_destroy(Future) :-
    future_id(Future, Id),
    (   with_mutex(rlm_async, async_future_state(Id, State))
    ->  destroy_existing_future(Id, State)
    ;   true
    ).

destroy_existing_future(Id, State) :-
    (   memberchk(State, [pending, running])
    ->  catch(rlm_future_cancel(rlm_future(Id), _), _, true)
    ;   true
    ),
    wait_for_task_release(Id, 1.0),
    with_mutex(rlm_async,
               ( retractall(async_future_thread(Id, _)),
                 retractall(async_future_state(Id, _)),
                 retractall(async_future_metadata(Id, _)),
                 retractall(async_future_callback(Id, _)),
                 retractall(async_future_continuation(Id, _, _)),
                 retractall(async_future_child(Id, _)),
                 retractall(async_future_child(_, Id))
               )).

wait_for_task_release(Id, Timeout) :-
    get_time(Start),
    wait_for_task_release_loop(Id, Start, Timeout).

wait_for_task_release_loop(Id, Start, Timeout) :-
    (   with_mutex(rlm_async, \+ async_future_thread(Id, _))
    ->  true
    ;   get_time(Now),
        Elapsed is Now-Start,
        (   Elapsed >= Timeout
        ->  true
        ;   sleep(0.005),
            wait_for_task_release_loop(Id, Start, Timeout)
        )
    ).

rlm_future_all(Futures, Outcomes) :-
    must_be_future_list(Futures),
    maplist(rlm_future_await, Futures, Outcomes).

must_be_future_list([]).
must_be_future_list([Future|Futures]) :-
    future_id(Future, _),
    must_be_future_list(Futures).

future_id(rlm_future(Id), Id) :-
    atom(Id),
    !.
future_id(Future, _) :-
    throw(error(type_error(rlm_future, Future),
                context(rlm_async,
                        'expected an opaque rlm_future/1 handle'))).

safe_exception(Exception, Safe) :-
    catch(term_string(Exception, Safe, [quoted(true)]),
          _,
          Safe = "<unprintable exception>").
