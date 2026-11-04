:- begin_tests(prlm_providers).

% Sibling modules are resolved from this file's own directory (not the
% CWD) so the file loads correctly from any runner or working directory.
% prlm_session/prolm calls below are module-qualified: where the imports
% land is irrelevant to this file.
:- prolog_load_context(directory, Dir),
   format(atom(KernelPath), '~w/../prolog/prlm_kernel', [Dir]),
   format(atom(SessionPath), '~w/../prolog/prlm_session', [Dir]),
   format(atom(ProvidersPath), '~w/../prolog/prlm_providers', [Dir]),
   use_module(KernelPath),
   use_module(library(lists)),
   use_module(library(yall)),
   (   exists_source(SessionPath)
   ->  use_module(SessionPath)
   ;   use_module('/tmp/prlm_session_stub')
   ),
   use_module(ProvidersPath).

% ============================================================
% Helpers
% ============================================================

:- dynamic test_session/1.

fresh_session(Session) :-
    fresh_session([], Session).

fresh_session(Options, Session) :-
    prlm_session:prlm_session_new(Options, Session),
    assertz(test_session(Session)).

release :-
    retractall(prlm_providers:prlm_prolog_provider(_, _, _, _)),
    retractall(prlm_providers:prlm_http_post(_, _, _, _, _)),
    retractall(prlm_providers:prlm_process_run(_, _, _, _)),
    retractall(prlm_providers:prlm_actor_provider_ask(_, _, _, _)),
    retractall(prlm_providers:prlm_proposal_op(custom_op_step(_))),
    forall(retract(test_session(S)), prlm_session:prlm_session_destroy(S)).

std_msgs([msg(system, "You are a runtime."),
          msg(user, "yield_step(7).")]).

mk_proposal(Text, proposal{text: Text,
                           term: Term,
                           provider: test,
                           status: ok,
                           reason: none,
                           time: 0.0,
                           usage: usage{tokens_in: 0, tokens_out: 0}}) :-
    (   catch(prlm_kernel:prlm_read_goal(Text, T, _), _, fail)
    ->  Term = T
    ;   Term = none
    ).

events_of(Session, Events) :-
    prlm_session:prlm_events(Session, -1, Events).

events_of_type(Session, Type, Evs) :-
    events_of(Session, Events),
    include([E]>>(get_dict(type, E, T), T == Type), Events, Evs).

throws_prlm(Goal, Type) :-
    catch((Goal -> fail ; true), prlm_error(Type, _), true),
    !.

% Trusted fake_fn callbacks (pinned in module `user`: fake_fn/1 resolves
% unqualified callback names there, independent of this file's context
% module).
user:prov_fn_test(_Session, _Messages, "from_fn").
user:prov_fn_fail(_Session, _Messages, _Text) :- fail.

% ============================================================
% echo provider
% ============================================================

test(echo_provider_text_status_term, [cleanup(release)]) :-
    fresh_session([provider(echo)], S),
    prlm_providers:prlm_provider_register(S, echo, echo),
    std_msgs(Msgs),
    prlm_providers:prlm_model_call(S, Msgs, options{}, P),
    assertion(P.text == "yield_step(7)."),
    assertion(P.status == ok),
    assertion(P.term == yield_step(7)),
    assertion(P.provider == echo),
    assertion(P.reason == none),
    assertion(float(P.time)),
    assertion(P.usage.tokens_in == 5),   % "You are a runtime." = 4 + 1
    assertion(P.usage.tokens_out == 1).

test(echo_no_user_message_is_data, [cleanup(release)]) :-
    fresh_session([provider(echo)], S),
    prlm_providers:prlm_provider_register(S, echo, echo),
    prlm_providers:prlm_model_call(S, [msg(system, "only system")], options{}, P),
    assertion(P.status == error),
    assertion(P.reason == no_user_message),
    assertion(P.text == ""),
    assertion(P.term == none).

% ============================================================
% fake(Calls): deterministic consumption + exhaustion
% ============================================================

test(fake_calls_order_and_exhaustion, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, fk, fake([fake("one"), fake("two")])),
    Msgs = [msg(user, "u")],
    prlm_providers:prlm_model_call(S, fk, Msgs, options{}, P1),
    assertion(P1.text == "one"),
    assertion(P1.term == one),
    prlm_providers:prlm_model_call(S, fk, Msgs, options{}, P2),
    assertion(P2.text == "two"),
    prlm_session:prlm_session_get(S, provider_fake_remaining(fk), Rest),
    assertion(Rest == []),
    prlm_providers:prlm_model_call(S, fk, Msgs, options{}, P3),
    assertion(P3.status == error),
    assertion(P3.reason == fake_exhausted),
    assertion(P3.text == ""),
    assertion(P3.term == none),
    % A failure event was emitted carrying the prlm_error info payload.
    events_of_type(S, failure, [F|_]),
    get_dict(info, F.data, InfoEv),
    assertion(get_dict(fake, InfoEv, exhausted)),
    assertion(F.data.reason == fake_exhausted),
    % Exhaustion is stable: repeated calls stay in the error state.
    prlm_providers:prlm_model_call(S, fk, Msgs, options{}, P4),
    assertion(P4.status == error),
    assertion(P4.reason == fake_exhausted).

% ============================================================
% fake_fn(Pred): trusted host callback
% ============================================================

test(fake_fn_trusted_callback, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, fn, fake_fn(prov_fn_test)),
    prlm_providers:prlm_model_call(S, fn, [msg(user, "u")], options{}, P),
    assertion(P.status == ok),
    assertion(P.text == "from_fn").

test(fake_fn_callback_failure_is_data, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, bad, fake_fn(prov_fn_fail)),
    prlm_providers:prlm_model_call(S, bad, [msg(user, "u")], options{}, P),
    assertion(P.status == error),
    assertion(P.reason == fake_fn_failed).

% ============================================================
% Provider swap determinism: the runtime stays authoritative
% ============================================================

test(provider_swap_same_validation, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, echo, echo),
    prlm_providers:prlm_provider_register(S, fk, fake([fake("yield_step(42)."),
                                        fake("call(halt).")])),
    prlm_providers:prlm_model_call(S, echo, [msg(user, "yield_step(42).")], options{}, Pe),
    prlm_providers:prlm_model_call(S, fk,    [msg(user, "ignored")],         options{}, Pf),
    assertion(Pe.text == "yield_step(42)."),
    assertion(Pf.text == "yield_step(42)."),
    prlm_providers:prlm_validate_proposal(S, Pe, Ope),
    prlm_providers:prlm_validate_proposal(S, Pf, Opf),
    assertion(Ope == yield_step(42)),
    assertion(Opf == yield_step(42)),
    assertion(Ope == Opf),
    % Identical rejected flow from both providers too.
    prlm_providers:prlm_model_call(S, echo, [msg(user, "call(halt).")], options{}, Pe2),
    prlm_providers:prlm_model_call(S, fk,    [msg(user, "ignored")],    options{}, Pf2),
    prlm_providers:prlm_validate_proposal(S, Pe2, Ope2),
    prlm_providers:prlm_validate_proposal(S, Pf2, Opf2),
    assertion(Ope2 == rejected(not_whitelisted)),
    assertion(Ope2 == Opf2).

% ============================================================
% validate_proposal: the authority gate
% ============================================================

test(validate_proposal_whitelist_shapes, [cleanup(release)]) :-
    fresh_session([], S),
    mk_proposal("yield_step(42).", P1),
    prlm_providers:prlm_validate_proposal(S, P1, yield_step(42)),
    mk_proposal("call(halt).", P2),
    prlm_providers:prlm_validate_proposal(S, P2, rejected(not_whitelisted)),
    mk_proposal("not prolog at all", P3),
    prlm_providers:prlm_validate_proposal(S, P3, rejected(not_a_term)),
    mk_proposal("tool_call_step(kv, _{x:1}).", P4),
    prlm_providers:prlm_validate_proposal(S, P4, Op4),
    Op4 = tool_call_step(kv, Args),
    assertion(is_dict(Args)),
    % Rejected proposals are inert DATA: functor rejected/1 over an atom.
    prlm_providers:prlm_validate_proposal(S, P2, Rej),
    assertion(Rej == rejected(not_whitelisted)),
    functor(Rej, rejected, 1),
    arg(1, Rej, Reason),
    assertion(atom(Reason)),
    % Malformed proposals never throw; they are simply not a term.
    prlm_providers:prlm_validate_proposal(S, 42, rejected(not_a_term)).

test(validate_proposal_untrusted_safety, [cleanup(release)]) :-
    fresh_session([], S),
    mk_proposal("assertz(danger).", P),
    prlm_providers:prlm_validate_proposal(S, P, rejected(not_whitelisted)),
    % Parse-only contract: prlm_read_goal yields the inert parsed term and
    % has not executed it (assertion of term equality is the whole check).
    prlm_kernel:prlm_read_goal("assertz(danger).", T, _),
    assertion(T == assertz(danger)).

test(proposal_op_add_extends_whitelist, [cleanup(release)]) :-
    fresh_session([], S),
    mk_proposal("weird_op(1).", P0),
    prlm_providers:prlm_validate_proposal(S, P0, rejected(not_whitelisted)),
    prlm_providers:prlm_proposal_op_add(custom_op_step(_)),
    mk_proposal("custom_op_step(9).", P1),
    prlm_providers:prlm_validate_proposal(S, P1, Op),
    Op = custom_op_step(9),
    assertion(Op == custom_op_step(9)),
    mk_proposal("custom_op_step(9).", P2),
    prlm_providers:prlm_validate_proposal(S, P2, custom_op_step(9)).

% ============================================================
% prolog provider: Prolog-only mode, no model
% ============================================================

test(prolog_provider_unsupported_by_default, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_model_call(S, [msg(user, "anything")], options{}, P),
    assertion(P.status == unsupported),
    assertion(P.text == ""),
    assertion(P.term == none),
    assertion(P.usage.tokens_out == 0).

test(prolog_provider_hook_clause_ok, [cleanup(release)]) :-
    fresh_session([], S),
    assertz(prlm_providers:prlm_prolog_provider(S, _M, _O, "procedural answer")),
    prlm_providers:prlm_model_call(S, [msg(user, "anything")], options{}, P),
    assertion(P.status == ok),
    assertion(P.text == "procedural answer"),
    assertion(P.term == none),           % two words: not a single term
    % Session scoping: another session does not see this clause.
    fresh_session([], S2),
    prlm_providers:prlm_model_call(S2, [msg(user, "anything")], options{}, P2),
    assertion(P2.status == unsupported).

% ============================================================
% Deferred adapters: http / process / actor
% ============================================================

test(deferred_adapters_error_then_hook_ok, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, web, http('http://example.test', _{})),
    prlm_providers:prlm_provider_register(S, sh, process(some_cmd)),
    prlm_providers:prlm_provider_register(S, ag, actor(agent1)),
    Msgs = [msg(user, "hello")],
    prlm_providers:prlm_model_call(S, web, Msgs, options{}, Pw),
    assertion(Pw.status == error),
    assertion(Pw.reason == http_hook_failed),
    prlm_providers:prlm_model_call(S, sh, Msgs, options{}, Ps),
    assertion(Ps.status == error),
    assertion(Ps.reason == process_hook_failed),
    prlm_providers:prlm_model_call(S, ag, Msgs, options{}, Pa),
    assertion(Pa.status == error),
    assertion(Pa.reason == actor_hook_failed),
    events_of_type(S, failure, Fs),
    assertion(length(Fs, 3)),
    % With hook clauses present, the same adapters succeed.
    assertz(prlm_providers:prlm_http_post(_, 'http://example.test',
                                          _, _Body, "http reply")),
    assertz(prlm_providers:prlm_process_run(_, some_cmd, _In, "proc reply")),
    assertz(prlm_providers:prlm_actor_provider_ask(_, agent1, _Ms, "actor reply")),
    prlm_providers:prlm_model_call(S, web, Msgs, options{}, Pw2),
    assertion(Pw2.status == ok),
    assertion(Pw2.text == "http reply"),
    prlm_providers:prlm_model_call(S, sh, Msgs, options{}, Ps2),
    assertion(Ps2.status == ok),
    assertion(Ps2.text == "proc reply"),
    prlm_providers:prlm_model_call(S, ag, Msgs, options{}, Pa2),
    assertion(Pa2.status == ok),
    assertion(Pa2.text == "actor reply").

% ============================================================
% Events: exactly one model_call per call, with both token counts
% ============================================================

test(model_call_event_once_with_tokens, [cleanup(release)]) :-
    fresh_session([provider(echo)], S),
    prlm_providers:prlm_provider_register(S, echo, echo),
    std_msgs(Msgs),
    prlm_providers:prlm_model_call(S, Msgs, options{}, _),
    prlm_providers:prlm_model_call(S, Msgs, options{}, _),
    events_of_type(S, model_call, Ms),
    assertion(length(Ms, 2)),
    Ms = [E1, _E2],
    get_dict(data, E1, D),
    get_dict(provider, D, Prov),
    assertion(Prov == echo),
    get_dict(messages_count, D, MC),
    assertion(MC == 2),
    get_dict(tokens_in, D, TI),
    assertion(TI == 5),
    get_dict(tokens_out, D, TO),
    assertion(TO == 1).

% ============================================================
% model_call/5 explicit provider override
% ============================================================

test(explicit_provider_override, [cleanup(release)]) :-
    fresh_session([provider(echo)], S),
    prlm_providers:prlm_provider_register(S, echo, echo),
    prlm_providers:prlm_provider_register(S, fk, fake([fake("from_fake")])),
    Msgs = [msg(user, "via_echo")],
    prlm_providers:prlm_model_call(S, Msgs, options{}, Pd),
    assertion(Pd.provider == echo),
    assertion(Pd.text == "via_echo"),
    prlm_providers:prlm_model_call(S, fk, Msgs, options{}, Po),
    assertion(Po.provider == fk),
    assertion(Po.text == "from_fake").

% ============================================================
% Registry and validation errors
% ============================================================

test(provider_registered_sorted, [cleanup(release)]) :-
    fresh_session([], S),
    prlm_providers:prlm_provider_register(S, zeta, echo),
    prlm_providers:prlm_provider_register(S, alpha, prolog),
    prlm_providers:prlm_provider_register(S, mid, fake([])),
    prlm_providers:prlm_provider_registered(S, Names),
    assertion(Names == [alpha, mid, zeta]).

test(register_rejects_unknown_adapter, [cleanup(release)]) :-
    fresh_session([], S),
    throws_prlm(prlm_providers:prlm_provider_register(S, bad, whatever(1)), type_error),
    catch(prlm_providers:prlm_provider_register(S, bad2, whatever(2)),
          prlm_error(type_error, Info),
          (get_dict(adapter, Info, A), A == whatever(2))).

test(model_call_rejects_bad_messages_and_options, [cleanup(release)]) :-
    fresh_session([], S),
    throws_prlm(prlm_providers:prlm_model_call(S, [msg(bogus, "x")], options{}, _),
                type_error),
    throws_prlm(prlm_providers:prlm_model_call(S, [msg(user, _)], options{}, _),
                type_error),
    throws_prlm(prlm_providers:prlm_model_call(S, notalist, options{}, _),
                type_error),
    throws_prlm(prlm_providers:prlm_model_call(S, [msg(user, "x")], options{model: 42}, _),
                type_error),
    throws_prlm(prlm_providers:prlm_model_call(S, [msg(user, "x")], options{bogus: 1}, _),
                type_error),
    throws_prlm(prlm_providers:prlm_model_call(S, [msg(user, "x")], notadict, _),
                type_error),
    % Unregistered provider override is a programming error: it throws.
    throws_prlm(prlm_providers:prlm_model_call(S, nosuch, [msg(user, "x")], options{}, _),
                existence_error).

:- end_tests(prlm_providers).
