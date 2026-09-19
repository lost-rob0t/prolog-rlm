:- begin_tests(prlm_learn).

:- use_module('../prolog/prlm_learn').
:- use_module('../prolog/prlm_session').
:- use_module('../prolog/prlm_kernel').
:- use_module(library(lists)).
:- use_module(library(apply)).
:- use_module(library(pairs)).

% ============================================================
% Helpers
% ============================================================

sess_new(S) :-
    prlm_session_new([authority(allow_session)], S).

sess_destroy(S) :-
    catch(prlm_session_destroy(S), _, true).

completed_outcome(Spec, Result, Out) :-
    Out = outcome{status: completed,
                  spec_id: Spec,
                  result: Result,
                  evidence: evidence{source: rlm_run, provenance: prov},
                  usage: _{steps: 10}}.

failed_outcome(Spec, Out) :-
    Out = outcome{status: failed,
                  spec_id: Spec,
                  result: none,
                  evidence: evidence{source: rlm_run, provenance: prov},
                  usage: _{steps: 3}}.

learning_events(Session, Events) :-
    prlm_events(Session, 0, All),
    include(is_learning, All, Events).

is_learning(Event) :-
    get_dict(type, Event, learning).

learning_data(Session, Datas) :-
    learning_events(Session, Events),
    maplist(ev_data, Events, Datas).

ev_data(Event, Data) :-
    get_dict(data, Event, Data).

% ============================================================
% Readiness
% ============================================================

test(learn_ready) :-
    prlm_learn_ready.

% ============================================================
% Trusted path: completed outcomes
% ============================================================

test(completed_outcome_is_learned) :-
    sess_new(S),
    completed_outcome(spec_a, found(x, 1), Out),
    prlm_learn(S, Out, KFact),
    get_dict(status, KFact, ok),
    get_dict(term, KFact, learned_result(spec_a, found(x, 1))),
    get_dict(spec_id, KFact, spec_a),
    get_dict(provenance, KFact, Prov),
    get_dict(source, Prov, rlm_run),
    get_dict(confidence, Prov, 0.9),
    get_dict(scope, Prov, session),
    get_dict(time, Prov, T),
    float(T),
    sess_destroy(S).

test(completed_outcome_lands_in_engine_kb) :-
    sess_new(S),
    completed_outcome(spec_b, r(2), Out),
    prlm_learn(S, Out, _),
    prlm_session_engine(S, E),
    once(prlm_current_predicate(E, kb, learned_result/2)),
    prlm_query_solutions(E, "kb:learned_result(S, R)", 100, Rows),
    Rows = [Row],
    get_dict('S', Row, spec_b),
    get_dict('R', Row, r(2)),
    sess_destroy(S).

test(completed_outcome_queryable_via_knowledge_patterns) :-
    sess_new(S),
    completed_outcome(spec_c, alpha, OutA),
    prlm_learn(S, OutA, _),
    completed_outcome(spec_c, beta, OutB),
    prlm_learn(S, OutB, _),
    completed_outcome(spec_d, gamma, OutC),
    prlm_learn(S, OutC, _),
    prlm_knowledge(S, all, All),
    length(All, 3),
    prlm_knowledge(S, about(spec_c), AboutC),
    AboutC == [learned_result(spec_c, alpha), learned_result(spec_c, beta)],
    prlm_knowledge(S, about(spec_d), [learned_result(spec_d, gamma)]),
    prlm_knowledge(S, result(spec_c, beta), [learned_result(spec_c, beta)]),
    prlm_knowledge(S, result(spec_c, _), AboutC),
    sess_destroy(S).

test(spec_id_string_is_normalized_to_atom) :-
    sess_new(S),
    completed_outcome("spec_e", ok_val, Out),
    prlm_learn(S, Out, KFact),
    get_dict(spec_id, KFact, spec_e),
    prlm_knowledge(S, about(spec_e), [learned_result(spec_e, ok_val)]),
    sess_destroy(S).

% ============================================================
% Rejected: failed outcomes
% ============================================================

test(failed_outcome_is_rejected_not_completed) :-
    sess_new(S),
    failed_outcome(spec_f, Out),
    prlm_learn(S, Out, KFact),
    KFact == kb_fact{status: rejected, reason: not_completed},
    prlm_session_engine(S, E),
    \+ prlm_current_predicate(E, kb, learned_result/2),
    prlm_knowledge(S, all, []),
    sess_destroy(S).

test(bad_status_throws) :-
    sess_new(S),
    catch(( prlm_learn(S, outcome{status: weird, spec_id: x, result: y}, _),
            throw(no_throw) ),
          prlm_error(type_error, Info),
          true),
    is_dict(Info),
    sess_destroy(S).

% ============================================================
% Untrusted path: LLM text
% ============================================================

test(untrusted_text_never_enters_trusted_knowledge) :-
    sess_new(S),
    completed_outcome(spec_g, real_result, Out),
    prlm_learn(S, Out, _),
    prlm_learn_text(S, "assertz(backdoor).", llm, KFact),
    get_dict(status, KFact, ok),
    get_dict(term, KFact, assertz(backdoor)),
    get_dict(provenance, KFact, Prov),
    get_dict(scope, Prov, untrusted),
    get_dict(confidence, Prov, 0.3),
    get_dict(source, Prov, llm),
    % stored ONLY in the untrusted engine module
    prlm_session_engine(S, E),
    once(prlm_current_predicate(E, kb_untrusted, assertz/1)),
    \+ prlm_current_predicate(E, kb, assertz/1),
    \+ prlm_current_predicate(E, kb, learned_result(backdoor, _)),
    % invisible to the trusted query surface
    prlm_knowledge(S, all, Trusted),
    Trusted == [learned_result(spec_g, real_result)],
    \+ member(assertz(backdoor), Trusted),
    % visible on the audit surface
    prlm_untrusted_knowledge(S, [assertz(backdoor)]),
    sess_destroy(S).

test(unparseable_text_is_rejected) :-
    sess_new(S),
    prlm_learn_text(S, "this is ]{ not prolog", llm, KFact),
    KFact == kb_fact{status: rejected, reason: unparseable},
    prlm_untrusted_knowledge(S, []),
    prlm_session_engine(S, E),
    \+ prlm_current_predicate(E, kb_untrusted, _/_),
    sess_destroy(S).

test(reserved_var_text_is_rejected_not_stored) :-
    sess_new(S),
    prlm_learn_text(S, "'$v'(x)", sneaky, KFact),
    get_dict(status, KFact, rejected),
    get_dict(reason, KFact, unparseable),
    prlm_untrusted_knowledge(S, []),
    sess_destroy(S).

% ============================================================
% Events
% ============================================================

test(learning_event_emitted_for_accepted_and_rejected) :-
    sess_new(S),
    completed_outcome(spec_h, v, OutOk),
    prlm_learn(S, OutOk, _),
    failed_outcome(spec_i, OutRej),
    prlm_learn(S, OutRej, _),
    learning_data(S, Datas),
    Datas = [OkData, RejData|_],
    get_dict(status, OkData, ok),
    get_dict(spec_id, OkData, spec_h),
    get_dict(confidence, OkData, 0.9),
    get_dict(status, RejData, rejected),
    get_dict(reason, RejData, not_completed),
    sess_destroy(S).

test(untrusted_learning_event_emitted) :-
    sess_new(S),
    prlm_learn_text(S, "kb_note(7).", llm, KFact),
    get_dict(status, KFact, ok),
    learning_data(S, [Data]),
    get_dict(status, Data, ok),
    get_dict(scope, Data, untrusted),
    get_dict(confidence, Data, 0.3),
    sess_destroy(S).

% ============================================================
% Forgetting
% ============================================================

test(forget_session_drains_everything) :-
    sess_new(S),
    completed_outcome(spec_j, a, Out),
    prlm_learn(S, Out, _),
    prlm_learn_text(S, "note(b).", llm, _),
    prlm_knowledge(S, all, [_]),
    prlm_learn_forget_session(S),
    prlm_session_engine(S, E),
    \+ prlm_current_predicate(E, kb, learned_result/2),
    \+ prlm_current_predicate(E, kb_untrusted, note/1),
    prlm_knowledge(S, all, []),
    prlm_untrusted_knowledge(S, []),
    sess_destroy(S).

test(forget_then_relearn) :-
    sess_new(S),
    completed_outcome(spec_k, one, Out1),
    prlm_learn(S, Out1, _),
    prlm_learn_forget_session(S),
    completed_outcome(spec_k, two, Out2),
    prlm_learn(S, Out2, KFact),
    get_dict(status, KFact, ok),
    prlm_knowledge(S, about(spec_k), [learned_result(spec_k, two)]),
    sess_destroy(S).

:- end_tests(prlm_learn).
