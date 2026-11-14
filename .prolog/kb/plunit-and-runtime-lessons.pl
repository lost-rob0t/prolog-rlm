% Verified SWI Prolog + plunit lessons from the question-resolution (#576) and
% inline-completion (#575) slices, 2026-11-13. Evidence: RED->GREEN suites
% rlm_question_test.pl (15/15) and rlm_inline_test.pl (14/14), aggregate
% 108 suites 1372/1372 at prolog-rlm main 6583c68.

prolog_semantics(dict_unification, 'SWI dict unification (=) requires IDENTICAL key sets: {a:1} = {a:1,b:2} FAILS silently-subset-wise. Patterns like Message = stream_message{phase:delta,text:T} never match richer runtime dicts - use get_dict/3 field access in event/message dispatch. Cost a long silent-failure debug in rlm_inline (handler consumed every event, delivered nothing).').

plunit_semantics(assertion_no_binding, 'assertion(Outcome = ok(Record)) under goal expansion does NOT bind Record in the enclosing test body (leaves it unbound; downstream Record.field throws instantiation_error). Corpus style is the safe pattern: plain (Outcome = ok(Record)) conjunct + get_dict/3 field checks, never assertion around unification.').

plunit_semantics(http_handler_collision, 'http_handler(root(path),...) registrations are GLOBAL and first-wins across the whole test process: two plunit suites registering root(sse) silently steal each other SSE servers (3 cross-suite failures). Every suite-local HTTP fixture must use a distinct path (e.g. root(inline_sse)).').

runtime_surface(question_resolution, 'Public question API on main (48d8048+): rlm_ask/4 registers a question pending-op (deferred Future + question_pending event), rlm_answer/3 terminal-answers (Future resolves answered(authority_answer{question_id,answer}) + question_answered event), rlm_pending_questions/2 lists; rlm_deny on a question -> question_denied resolution; rlm_approve rejects with not_an_approval; answered joins bounded terminal retention.').

runtime_surface(inline_completion, 'U1 inline session class on main (6583c68): rlm_inline.pl - hard-capped grants (max_tokens<=256, time_limit<=10s, max_proposals<=256), one streaming llm_query per proposal via text_delta_handler (no ADARD ceremony), sink events proposal_started/delta/finished, batched lineage rlm_inline_lineage/2, accept/discard are authority-free decisions. Wire events proposal_* are legal prolog_agent_ui_v1 event types (reducer accumulates text; proposals view/snapshot field, optional on input for old-snapshot compatibility).').
