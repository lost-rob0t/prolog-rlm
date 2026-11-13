:- begin_tests(rlm_question).

:- use_module('../prolog/rlm_async').
:- use_module('../prolog/rlm_authority').

/* rlm_ask/4 registers a question pending-operation ---------------------- */

test(ask_creates_pending_question) :-
    Context = agent(q_ask_create, 1),
    rlm_ask(Context, "Which dataset?", [red, blue], Outcome),
    (   Outcome = ok(Record)
    ->  get_dict(state, Record, pending),
        get_dict(prompt, Record, "Which dataset?"),
        get_dict(choices, Record, [red, blue]),
        get_dict(id, Record, QuestionId),
        atom(QuestionId),
        rlm_pending_resolution_async(QuestionId, _Future)
    ;   assertion(failed(Outcome))
    ),
    rlm_authority_clear(Context).

test(ask_without_choices) :-
    Context = agent(q_ask_free, 1),
    rlm_ask(Context, "Free-form prompt", [], ok(Record)),
    get_dict(choices, Record, []),
    rlm_authority_clear(Context).

test(ask_rejects_nonground_prompt) :-
    Context = agent(q_ask_nonground, 1),
    rlm_ask(Context, _Prompt, [], error(Error)),
    get_dict(kind, Error, invalid_question),
    rlm_authority_clear(Context).

test(ask_emits_question_pending_event) :-
    Context = agent(q_ask_event, 1),
    rlm_ask(Context, "Event prompt?", [yes], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_authority_events(Context, Events),
    member(Event, Events),
    get_dict(type, Event, question_pending),
    get_dict(question_id, Event, QuestionId),
    get_dict(prompt, Event, "Event prompt?"),
    get_dict(choices, Event, [yes]),
    rlm_authority_clear(Context).

/* rlm_pending_questions/2 ------------------------------------------------ */

test(pending_questions_lists_pending_only) :-
    Context = agent(q_list, 1),
    rlm_ask(Context, "First?", [], ok(First)),
    rlm_ask(Context, "Second?", [], ok(Second)),
    get_dict(id, First, FirstId),
    rlm_answer(FirstId, yes, ok(_)),
    rlm_pending_questions(Context, Pending),
    Pending = [Only],
    get_dict(id, Only, SecondId),
    get_dict(id, Second, SecondId),
    rlm_authority_clear(Context).

/* rlm_answer/3 completes the round trip ---------------------------------- */

test(answer_resolves_future_and_records_event) :-
    Context = agent(q_answer, 1),
    rlm_ask(Context, "Proceed?", [ok, cancel], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_answer(QuestionId, ok, Outcome),
    (   Outcome = ok(Transition)
    ->  get_dict(state, Transition, answered),
        get_dict(answer, Transition, ok)
    ;   assertion(failed(Outcome))
    ),
    rlm_pending_resolution(QuestionId, Resolution),
    Resolution = answered(Answered),
    get_dict(question_id, Answered, QuestionId),
    get_dict(answer, Answered, ok),
    rlm_authority_events(Context, Events),
    member(Event, Events),
    get_dict(type, Event, question_answered),
    get_dict(question_id, Event, QuestionId),
    get_dict(answer, Event, ok),
    rlm_authority_clear(Context).

test(answer_is_awaitable_across_threads) :-
    Context = agent(q_thread, 1),
    rlm_ask(Context, "Threaded?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    thread_create(rlm_answer(QuestionId, from_thread, _), Id, []),
    rlm_pending_resolution(QuestionId, Resolution),
    Resolution = answered(Answered),
    get_dict(answer, Answered, from_thread),
    thread_join(Id, true),
    rlm_authority_clear(Context).

test(answer_unknown_question_fails_closed) :-
    rlm_answer(q_does_not_exist, yes, error(Error)),
    get_dict(kind, Error, unknown_question).

test(answer_twice_fails_closed) :-
    Context = agent(q_twice, 1),
    rlm_ask(Context, "Once?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_answer(QuestionId, first, ok(_)),
    rlm_answer(QuestionId, second, error(Error)),
    get_dict(kind, Error, question_not_pending),
    rlm_authority_clear(Context).

test(answer_rejects_nonground_answer) :-
    Context = agent(q_nonground, 1),
    rlm_ask(Context, "Ground?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_answer(QuestionId, _Answer, error(Error)),
    get_dict(kind, Error, invalid_question),
    rlm_authority_clear(Context).

/* Approval APIs stay approval-scoped ------------------------------------- */

test(approve_on_question_fails_closed) :-
    Context = agent(q_approve, 1),
    rlm_ask(Context, "Approve me?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_approve(QuestionId, error(Error)),
    get_dict(kind, Error, not_an_approval),
    rlm_authority_clear(Context).

test(deny_on_question_resolves_denied_with_question_event) :-
    Context = agent(q_deny, 1),
    rlm_ask(Context, "Deny me?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_deny(QuestionId, cancelled(test), ok(_)),
    rlm_pending_resolution(QuestionId, denied(Denied)),
    get_dict(reason, Denied, cancelled(test)),
    rlm_authority_events(Context, Events),
    member(Event, Events),
    get_dict(type, Event, question_denied),
    get_dict(question_id, Event, QuestionId),
    rlm_authority_clear(Context).

/* Teardown ---------------------------------------------------------------- */

test(cancel_owner_denies_pending_questions) :-
    Context = agent(q_cancel_owner, 1),
    rlm_ask(Context, "Orphan?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_pending_cancel_owner(Context, test_done),
    rlm_pending_resolution(QuestionId, denied(Denied)),
    get_dict(reason, Denied, cancelled(test_done)),
    rlm_authority_clear(Context).

test(clear_destroys_question_futures) :-
    Context = agent(q_clear, 1),
    rlm_ask(Context, "Cleanup?", [], ok(Record)),
    get_dict(id, Record, QuestionId),
    rlm_authority_clear(Context),
    catch(rlm_pending_resolution_async(QuestionId, _),
          error(existence_error(rlm_pending_operation, _), _),
          true).

/* Questions stay out of approval listings -------------------------------- */

test(pending_approvals_exclude_questions) :-
    Context = agent(q_no_listing_leak, 1),
    rlm_ask(Context, "Hidden?", [], ok(_)),
    rlm_pending_approvals(Context, Approvals),
    Approvals == [],
    rlm_authority_clear(Context).

:- end_tests(rlm_question).
