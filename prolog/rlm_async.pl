:- module(rlm_async,
          [ rlm_async_ready/0,
            rlm_async_runtime_status/1,
            rlm_async_submit/2,
            rlm_future_status/2,
            rlm_future_await/2,
            rlm_future_await/3,
            rlm_future_cancel/2,
            rlm_future_destroy/1,
            rlm_future_all/2
          ]).

/** <module> Bounded sync/async bridge for prolog-rlm

Blocking-capable library operations can share one implementation while exposing
both synchronous and asynchronous entry points.  The async side submits a
callable closure to a process-local bounded worker queue and returns an opaque
future.  The closure receives one final argument containing the operation's
ordinary result term, so awaiting a future yields exactly the same result shape
as the synchronous API.

The scheduler is intentionally small and domain-neutral.  It knows nothing
about models, tools, MCP, graphs, authority, or UI; those libraries wrap their
existing operations in rlm_async_submit/2.
*/

:- use_module(library(gensym)).

:- meta_predicate rlm_async_submit(1, -).

:- dynamic async_runtime/3.
:- dynamic async_future_state/2.
:- dynamic async_future_thread/2.

/* Keep the generic scheduler bounded.  Domain-specific runtimes may impose
   stricter limits on top of these process-wide defaults. */
default_async_worker_count(8).
default_async_backlog(64).

rlm_async_ready :-
    current_prolog_flag(threads, true).

/* -------------------------------------------------------------------------
 * Runtime and submission
 * ---------------------------------------------------------------------- */

rlm_async_runtime_status(Status) :-
    ensure_async_runtime(Queue),
    with_mutex(rlm_async,
               async_state_counts(Pending, Running, Completed, Cancelled)),
    (   message_queue_property(Queue, size(Queued))
    ->  true
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
    count_completed(States, Completed),
    count_state(cancelled, States, Cancelled).

count_state(Target, States, Count) :-
    findall(1, member(Target, States), Ones),
    length(Ones, Count).

count_completed(States, Count) :-
    findall(1, member(completed(_), States), Ones),
    length(Ones, Count).

rlm_async_submit(Goal, Future) :-
    require_async_runtime,
    require_callable(Goal),
    ensure_async_runtime(Queue),
    with_mutex(rlm_async,
               ( gensym(rlm_future_, Id),
                 assertz(async_future_state(Id, pending))
               )),
    Future = rlm_future(Id),
    (   thread_send_message(Queue,
                            async_task(Id, Goal),
                            [timeout(0)])
    ->  true
    ;   async_backpressure(Id)
    ).

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

ensure_async_runtime(Queue) :-
    with_mutex(rlm_async_runtime,
               ensure_async_runtime_locked(Queue)).

ensure_async_runtime_locked(Queue) :-
    async_runtime(Existing, _, _),
    is_message_queue(Existing),
    !,
    Queue = Existing.
ensure_async_runtime_locked(Queue) :-
    retractall(async_runtime(_, _, _)),
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

async_backpressure(Id) :-
    with_mutex(rlm_async,
               ( retractall(async_future_state(Id, _)),
                 assertz(async_future_state(
                             Id,
                             completed(error(async_error{
                                                 kind:backpressure,
                                                 future:Id,
                                                 message:"asynchronous runtime backlog is full"
                                             }))))
               )).

/* -------------------------------------------------------------------------
 * Worker pool
 * ---------------------------------------------------------------------- */

async_worker_loop(Queue) :-
    catch(thread_get_message(Queue, Message),
          _,
          Message = stop),
    (   Message == stop
    ->  true
    ;   Message = async_task(Id, Goal)
    ->  async_execute_task(Id, Goal),
        async_worker_loop(Queue)
    ;   async_worker_loop(Queue)
    ).

async_execute_task(Id, Goal) :-
    thread_self(Thread),
    with_mutex(rlm_async,
               async_claim_task(Id, Thread, Claimed)),
    (   Claimed == true
    ->  catch(async_call_goal(Goal, Outcome),
              Exception,
              async_exception_outcome(Id, Exception, Outcome)),
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
                                  kind:exception,
                                  exception:Safe,
                                  message:"asynchronous operation raised an exception"
                              })) :-
    safe_exception(Exception, Safe).

safe_exception(Exception, Safe) :-
    catch(term_string(Exception, Safe, [quoted(true)]),
          _,
          Safe = "<unprintable exception>").

async_store_completion(Id, Outcome) :-
    with_mutex(rlm_async,
               ( retractall(async_future_thread(Id, _)),
                 ( async_future_state(Id, cancelled)
                 -> true
                 ;  async_future_state(Id, _)
                 -> retractall(async_future_state(Id, _)),
                    assertz(async_future_state(Id, completed(Outcome)))
                 ;  true
                 )
               )).

/* -------------------------------------------------------------------------
 * Status and waiting
 * ---------------------------------------------------------------------- */

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

status_term(Id, pending,
            future_status{id:Id, state:pending}).
status_term(Id, running,
            future_status{id:Id, state:running}).
status_term(Id, cancelled,
            future_status{id:Id, state:cancelled}).
status_term(Id, completed(Outcome),
            future_status{id:Id, state:completed, outcome:Outcome}).

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

await_state(completed(Outcome), _, _, _, Outcome) :-
    !.
await_state(cancelled, Id, _, _,
            error(async_error{
                      kind:cancelled,
                      future:Id,
                      message:"asynchronous operation was cancelled"
                  })) :-
    !.
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

await_timed_out(_, infinite) :-
    !,
    fail.
await_timed_out(Start, Timeout) :-
    get_time(Now),
    Elapsed is Now-Start,
    Elapsed >= Timeout.

/* -------------------------------------------------------------------------
 * Cancellation and cleanup
 * ---------------------------------------------------------------------- */

rlm_future_cancel(Future, Outcome) :-
    future_id(Future, Id),
    with_mutex(rlm_async,
               future_cancel_transition(Id, Transition, Thread)),
    apply_cancel_transition(Id, Transition, Thread, Outcome).

future_cancel_transition(Id, already_completed, none) :-
    async_future_state(Id, completed(_)),
    !.
future_cancel_transition(Id, already_cancelled, none) :-
    async_future_state(Id, cancelled),
    !.
future_cancel_transition(Id, cancel, Thread) :-
    async_future_state(Id, State),
    memberchk(State, [pending, running]),
    !,
    retractall(async_future_state(Id, _)),
    assertz(async_future_state(Id, cancelled)),
    (   async_future_thread(Id, Worker)
    ->  Thread = Worker
    ;   Thread = none
    ).
future_cancel_transition(Id, _, _) :-
    throw(error(existence_error(rlm_future, rlm_future(Id)),
                context(rlm_future_cancel/2,
                        'future does not exist or was destroyed'))).

apply_cancel_transition(_, already_completed, _, ok(already_completed)) :- !.
apply_cancel_transition(_, already_cancelled, _, ok(already_cancelled)) :- !.
apply_cancel_transition(_, cancel, none, ok(cancelled)) :- !.
apply_cancel_transition(Id, cancel, Thread, ok(cancelled)) :-
    catch(thread_signal(Thread, throw(rlm_async_cancelled(Id))), _, true).

rlm_future_destroy(Future) :-
    future_id(Future, Id),
    (   with_mutex(rlm_async,
                   async_future_state(Id, State))
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
                 retractall(async_future_state(Id, _))
               )).

wait_for_task_release(Id, Timeout) :-
    get_time(Start),
    wait_for_task_release_loop(Id, Start, Timeout).

wait_for_task_release_loop(Id, Start, Timeout) :-
    (   with_mutex(rlm_async,
                   \+ async_future_thread(Id, _))
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
