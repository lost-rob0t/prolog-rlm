:- module(rlm_async,
          [ rlm_async_ready/0,
            rlm_async_submit/2,
            rlm_future_status/2,
            rlm_future_await/2,
            rlm_future_await/3,
            rlm_future_cancel/2,
            rlm_future_destroy/1,
            rlm_future_all/2
          ]).

/** <module> Small sync/async bridge for prolog-rlm

Blocking-capable library operations can share one implementation while exposing
both synchronous and asynchronous entry points.  The async side schedules a
callable closure in a supervised SWI-Prolog thread and returns an opaque future.
The closure receives one final argument containing the operation's ordinary
result term, so awaiting a future yields exactly the same result shape as the
synchronous API.

This module deliberately does not know about models, tools, MCP, agents, or
UI.  Those libraries wrap their existing synchronous operation in
rlm_async_submit/2 when they need a non-blocking surface.
*/

:- use_module(library(gensym)).

:- meta_predicate rlm_async_submit(1, -).

:- dynamic async_future_state/2.
:- dynamic async_future_thread/2.

rlm_async_ready :-
    current_prolog_flag(threads, true).

/* -------------------------------------------------------------------------
 * Submission
 * ---------------------------------------------------------------------- */

rlm_async_submit(Goal, Future) :-
    require_async_runtime,
    require_callable(Goal),
    with_mutex(rlm_async,
               ( gensym(rlm_future_, Id),
                 assertz(async_future_state(Id, pending))
               )),
    catch(thread_create(rlm_async:async_worker(Id, Goal),
                        Thread,
                        [detached(false)]),
          Exception,
          async_submit_failed(Id, Exception)),
    with_mutex(rlm_async,
               assertz(async_future_thread(Id, Thread))),
    Future = rlm_future(Id).

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

async_submit_failed(Id, Exception) :-
    with_mutex(rlm_async,
               retractall(async_future_state(Id, _))),
    throw(Exception).

async_worker(Id, Goal) :-
    async_mark_running(Id),
    catch(async_call_goal(Goal, Outcome),
          Exception,
          async_exception_outcome(Id, Exception, Outcome)),
    async_store_completion(Id, Outcome).

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

async_mark_running(Id) :-
    with_mutex(rlm_async,
               ( retract(async_future_state(Id, pending))
               -> assertz(async_future_state(Id, running))
               ;  true
               )).

async_store_completion(Id, Outcome) :-
    with_mutex(rlm_async,
               ( async_future_state(Id, cancelled)
               -> true
               ;  retractall(async_future_state(Id, _)),
                  assertz(async_future_state(Id, completed(Outcome)))
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
apply_cancel_transition(Id, cancel, none, ok(cancelled)) :-
    !,
    with_mutex(rlm_async,
               ( async_future_state(Id, cancelled) -> true ; true )).
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
    (   with_mutex(rlm_async,
                   async_future_thread(Id, Thread))
    ->  join_worker(Thread)
    ;   true
    ),
    with_mutex(rlm_async,
               ( retractall(async_future_thread(Id, _)),
                 retractall(async_future_state(Id, _))
               )).

join_worker(Thread) :-
    thread_self(Self),
    (   Thread == Self
    ->  true
    ;   catch(thread_join(Thread, _), _, true)
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
