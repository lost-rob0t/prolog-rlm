:- module(prlm_learn,
          [ prlm_learn_ready/0,
            prlm_learn/3,
            prlm_learn_text/4,
            prlm_knowledge/3,
            prlm_untrusted_knowledge/2,
            prlm_learn_forget_session/1
          ]).

/** <module> prlm_learn — completed run outcomes become queryable knowledge

Why this exists
===============

A useful runtime result should not evaporate when the run ends: "/learn"
turns a structured outcome into a knowledge fact, with provenance, so later
planning can query it. The trust boundary is the whole point of this module:

* *Trusted path* — prlm_learn/3 accepts only outcome{status: completed}
  records produced by the runtime itself. The learned term is derived
  deterministically from the outcome (learned_result(SpecId, Result)) and
  stored in the session engine's module `kb` (via prlm_kernel:prlm_assertz/3)
  and in a module-local mirror used for pattern queries. Provenance is
  provenance{source: rlm_run, time, confidence: 0.9, scope: session}.

* *Untrusted path* — prlm_learn_text/4 takes arbitrary text (typically LLM
  output). The text is only PARSED (prlm_read_goal/3 is parse-only; the term
  is inert data, never executed). A parse failure is rejected(unparseable).
  A successful parse is stored ONLY in the engine module `kb_untrusted` with
  scope untrusted and confidence 0.3 — NEVER in `kb`, NEVER in the mirror,
  and therefore never returned by prlm_knowledge/3.

Trust invariant
===============

For every Term: Term appears in prlm_knowledge/3 results iff it was stored
by prlm_learn/3 from a completed outcome. No untrusted text can promote
itself into the trusted store: there is no path from kb_untrusted to kb.

Query patterns (prlm_knowledge/3)
=================================

prlm_knowledge/3 scans the trusted mirror. Pattern is one of:

  * `all`               — every trusted learned term.
  * about(SpecId)       — learned_result(SpecId, _) terms for SpecId.
  * result(SpecId, Res) — learned_result(SpecId, R) with R == Res
                          (Res unbound selects all results for SpecId).

Engine-side, the same facts live in engine module `kb` and remain queryable
through prlm_query_solutions/4 with module-qualified goal text, e.g.
"kb:learned_result(S, R)" (the kernel supports M:G qualification). The mirror
is maintained in lockstep: every prlm_learn/3 success writes both stores,
and prlm_learn_forget_session/1 drains both.

Events
======

Every accepted or rejected learning attempt emits a canonical `learning`
event (status, scope, confidence, spec/source identifiers). The learned
Result term itself is never copied into event data; the outcome's full
evidence remains in the runtime's own outcome record/event stream.

Errors follow the prlm error model: throw(prlm_error(Type, InfoDict)).
*/

:- use_module('./prlm_kernel').
:- use_module('./prlm_session').

prlm_learn_ready :-
    prlm_kernel_ready,
    prlm_session_ready.

% Module-local state, keyed by the session handle (mirrors the kernel's
% engine state discipline; all of it is dropped by prlm_learn_forget_session/1
% and dies with the session on prlm_session_destroy/1).
:- dynamic learn_fact/2.     % learn_fact(Session, KFact)      — full audit index
:- dynamic kb_mirror/2.      % kb_mirror(Session, TrustedTerm) — trusted scan base
:- dynamic untrusted_fact/3. % untrusted_fact(Session, Term, Source)

% ============================================================
% Helpers
% ============================================================

require_session(Session) :-
    prlm_session_engine(Session, _).

as_atom(A, A) :-
    atom(A),
    !.
as_atom(S, A) :-
    string(S),
    !,
    atom_string(A, S).
as_atom(T, _) :-
    throw(prlm_error(type_error, _{expected: atom, got: T})).

% ============================================================
% Trusted learning from run outcomes
% ============================================================

%! prlm_learn(+Session, +Outcome, -KFact) is det
%
% Learn from a structured run outcome
% outcome{status, spec_id, result, evidence: evidence{...}, usage}.
%
%   * status completed -> KFact = kb_fact{status: ok,
%       term: learned_result(SpecId, Result),
%       provenance: provenance{source: rlm_run, time: Float,
%                              confidence: 0.9, scope: session},
%       spec_id: SpecId}.
%     The term is stored in the session engine module `kb` and in the
%     trusted mirror; a `learning` event is emitted.
%   * status failed -> KFact = kb_fact{status: rejected,
%     reason: not_completed}. Nothing is stored in the engine.
%   * any other status is a type error (fail closed).
prlm_learn(Session, Outcome, KFact) :-
    require_session(Session),
    (   is_dict(Outcome, outcome)
    ->  true
    ;   throw(prlm_error(type_error, _{outcome: Outcome}))
    ),
    get_dict(status, Outcome, Status),
    learn_completed(Status, Session, Outcome, KFact),
    assertz(learn_fact(Session, KFact)).

learn_completed(completed, Session, Outcome, KFact) :-
    !,
    get_dict(spec_id, Outcome, SpecId0),
    as_atom(SpecId0, SpecId),
    get_dict(result, Outcome, Result),
    get_time(Time),
    LearnedTerm = learned_result(SpecId, Result),
    prlm_session_engine(Session, Engine),
    prlm_assertz(Engine, kb, LearnedTerm),
    assertz(kb_mirror(Session, LearnedTerm)),
    KFact = kb_fact{status: ok,
                    term: LearnedTerm,
                    provenance: provenance{source: rlm_run,
                                           time: Time,
                                           confidence: 0.9,
                                           scope: session},
                    spec_id: SpecId},
    prlm_event_emit(Session, learning,
                    _{status: ok,
                      spec_id: SpecId,
                      scope: session,
                      confidence: 0.9,
                      source: rlm_run}).
learn_completed(failed, Session, _Outcome, KFact) :-
    !,
    KFact = kb_fact{status: rejected, reason: not_completed},
    prlm_event_emit(Session, learning,
                    _{status: rejected, reason: not_completed, scope: none}).
learn_completed(Status, _, _, _) :-
    throw(prlm_error(type_error, _{outcome_status: Status})).

% ============================================================
% Untrusted learning from text
% ============================================================

%! prlm_learn_text(+Session, +Text, +Source, -KFact) is det
%
% The UNTRUSTED path (e.g. LLM output). Text is parsed with
% prlm_read_goal/3 (parse-only: the result is an inert engine term that is
% never executed here).
%
%   * parse failure -> KFact = kb_fact{status: rejected,
%     reason: unparseable}; nothing is stored.
%   * parse success -> the term is stored ONLY in the engine module
%     `kb_untrusted` with provenance{source: Source, time, confidence: 0.3,
%     scope: untrusted}. It is never written to `kb` and never mirrored
%     into prlm_knowledge/3.
prlm_learn_text(Session, Text, Source, KFact) :-
    require_session(Session),
    as_atom(Source, Src),
    (   catch(( prlm_read_goal(Text, Term, _) -> true ), _ParseError, fail)
    ->  !,
        learn_text_ok(Session, Term, Src, KFact)
    ;   !,
        KFact = kb_fact{status: rejected, reason: unparseable},
        assertz(learn_fact(Session, KFact)),
        prlm_event_emit(Session, learning,
                        _{status: rejected, reason: unparseable, source: Src})
    ).

learn_text_ok(Session, Term, Src, KFact) :-
    get_time(Time),
    prlm_session_engine(Session, Engine),
    prlm_assertz(Engine, kb_untrusted, Term),
    assertz(untrusted_fact(Session, Term, Src)),
    KFact = kb_fact{status: ok,
                    term: Term,
                    provenance: provenance{source: Src,
                                           time: Time,
                                           confidence: 0.3,
                                           scope: untrusted},
                    spec_id: none},
    prlm_event_emit(Session, learning,
                    _{status: ok,
                      scope: untrusted,
                      confidence: 0.3,
                      source: Src}).

% ============================================================
% Queries
% ============================================================

%! prlm_knowledge(+Session, +Pattern, -Matches) is det
%
% Trusted knowledge only. Matches are learned terms from the trusted mirror
% (written exclusively by prlm_learn/3 on completed outcomes). Untrusted
% terms are structurally unreachable here. Patterns:
%
%   * all — every trusted learned term
%   * about(SpecId) — terms learned_result(SpecId, _)
%   * result(SpecId, Res) — learned_result(SpecId, R) with R == Res
%     (unbound Res selects every result recorded for SpecId)
prlm_knowledge(Session, Pattern, Matches) :-
    require_session(Session),
    knowledge_pattern(Pattern, Session, Matches).

knowledge_pattern(all, Session, Matches) :-
    !,
    findall(T, kb_mirror(Session, T), Matches).
knowledge_pattern(about(SpecId), Session, Matches) :-
    !,
    as_atom(SpecId, Spec),
    findall(learned_result(Spec, R),
            kb_mirror(Session, learned_result(Spec, R)),
            Matches).
knowledge_pattern(result(SpecId, Res), Session, Matches) :-
    !,
    as_atom(SpecId, Spec),
    findall(learned_result(Spec, R),
            (   kb_mirror(Session, learned_result(Spec, R0)),
                (   var(Res)
                ->  R = R0
                ;   R0 == Res,
                    R = R0
                )
            ),
            Matches).
knowledge_pattern(Pattern, _, _) :-
    throw(prlm_error(type_error, _{knowledge_pattern: Pattern})).

%! prlm_untrusted_knowledge(+Session, -Terms) is det
%
% All untrusted (confidence 0.3) terms stored by prlm_learn_text/4, for
% audit and for planners that want to treat them differently from trusted
% knowledge.
prlm_untrusted_knowledge(Session, Terms) :-
    require_session(Session),
    findall(T, untrusted_fact(Session, T, _), Terms).

% ============================================================
% Forgetting
% ============================================================

%! prlm_learn_forget_session(+Session) is det
%
% Drain all learning state for Session: the trusted module `kb` facts, the
% untrusted module `kb_untrusted` facts (one drain per distinct stored
% functor) and the module-local indexes. Session destruction (which destroys
% the owned engine) achieves the same end state; this predicate exists for
% long-lived sessions that must reset knowledge in place.
prlm_learn_forget_session(Session) :-
    require_session(Session),
    prlm_session_engine(Session, Engine),
    drain_engine(Engine, kb, learned_result, 2),
    findall(F/A,
            (   untrusted_fact(Session, T, _),
                functor(T, F, A)
            ),
            Pairs0),
    sort(Pairs0, Pairs),
    forall(member(F/A, Pairs),
           drain_engine(Engine, kb_untrusted, F, A)),
    retractall(learn_fact(Session, _)),
    retractall(kb_mirror(Session, _)),
    retractall(untrusted_fact(Session, _, _)).

drain_engine(Engine, Module, Name, Arity) :-
    (   prlm_retract_first(Engine, Module, Name, Arity)
    ->  drain_engine(Engine, Module, Name, Arity)
    ;   true
    ).
