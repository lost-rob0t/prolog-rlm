:- use_module(library(plunit)).
:- use_module('../prolog/prlm_session.pl').
:- use_module('../prolog/prlm_kernel.pl').
:- use_module('../prolog/prlm_providers.pl').
:- use_module('../prolog/prlm_tools.pl').
:- use_module('../prolog/prlm_actors.pl').
:- use_module('../prolog/prlm_rlm.pl').

:- begin_tests(prlm_rlm).

% ============================================================
% Helpers
% ============================================================

sess_new(Opts0, S) :-
    (   is_list(Opts0) -> Opts = Opts0 ; Opts = [Opts0] ),
    prlm_session_new([authority(allow_session)|Opts], S).

free_sess(S) :-
    catch(prlm_session_destroy(S), _, true).

event_data(S, Type, Data) :-
    prlm_events(S, -1, Events),
    member(E, Events),
    get_dict(type, E, Type),
    get_dict(data, E, Data),
    !.

all_event_data(S, Type, Datas) :-
    prlm_events(S, -1, Events),
    findall(D,
            (   member(E, Events),
                get_dict(type, E, Type),
                get_dict(data, E, D)
            ),
            Datas).

% A deterministic always-failing tool (error-path probe from prlm_tools).
failing_tool(Name,
             tool{name: Name,
                  description: 'Always fails; error-path probe.',
                  args_schema: [],
                  capability: [],
                  authority: allow_session,
                  effects: [read],
                  result_schema: term,
                  handler: host(prlm_tools:prlm_fail_always)}).

% Consult an in-language plan_spec/3 clause into the session engine's
% prlm_rlm_lang module; a local clause shadows the imported prlm_plan one.
consult_spawn_plan(S) :-
    prlm_session_engine(S, Engine),
    Src = "plan_spec(spec(_, Goal, _, _), _, \c
           [step(n(1), spawn_agent_step(sub)), \c
            step(n(2), yield_step(goal_done(Goal)))]).\n",
    prlm_consult_source(Engine, prlm_rlm_lang, Src, test_spawn_plan).

consult_ctx_plan(S) :-
    prlm_session_engine(S, Engine),
    Src = "plan_spec(spec(_, Goal, _, _), _, \c
           [step(n(1), ctx_compile_step), \c
            step(n(2), yield_step(goal_done(Goal)))]).\n",
    prlm_consult_source(Engine, prlm_rlm_lang, Src, test_ctx_plan).

% ============================================================
% 1. Direct mode, provider prolog: honest prolog-only failure
% ============================================================

test(direct_prolog_provider_unsupported, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_run_spec(S, spec{id: t1, goal: 'hello world', mode: direct}, O),
    get_dict(status, O, failed),
    get_dict(result, O, prolog_provider_unsupported),
    get_dict(attempts, O, 1),
    get_dict(repairs, O, []),
    \+ event_data(S, completion, _),
    event_data(S, verification, VD),
    get_dict(status, VD, fail).

% ============================================================
% 2. Direct mode, echo provider: completed, spec never weakened
% ============================================================

test(direct_echo_completed, [cleanup(free_sess(S))]) :-
    sess_new([provider(echo)], S),
    prlm_provider_register(S, echo, echo),
    prlm_run_spec(S, spec{id: spec_echo, goal: 'say hi', mode: direct}, O),
    get_dict(status, O, completed),
    get_dict(result, O, 'say hi'),
    get_dict(spec_id, O, spec_echo),
    get_dict(attempts, O, 1),
    \+ event_data(S, failure, _).

% ============================================================
% 3. Symbolic, no requirements: fallback plan yields goal_done
% ============================================================

test(symbolic_no_requirements_completed, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_run_spec(S, spec{id: s3, goal: done(1), mode: symbolic}, O),
    get_dict(status, O, completed),
    get_dict(result, O, goal_done(done(1))),
    get_dict(attempts, O, 1),
    event_data(S, specification, SpecD),
    get_dict(goal, SpecD, done(1)),
    get_dict(attempt, SpecD, 1),
    event_data(S, plan, _),
    event_data(S, verification, VD),
    get_dict(status, VD, pass),
    event_data(S, completion, _),
    event_data(S, learning, _).

% ============================================================
% 4. Auto mode resolution via in-language rules
% ============================================================

test(auto_mode_resolves_symbolic, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_session_put(S, rlm_markers, markers(true, false, false)),
    prlm_run_spec(S, spec{id: s4, goal: g, mode: auto}, O),
    get_dict(status, O, completed),
    event_data(S, mode_select, MD),
    get_dict(requested, MD, auto),
    get_dict(resolved, MD, symbolic).

% ============================================================
% 5. Deterministically failing requirement: repairs never weaken
%    the spec; attempts exhausted -> failed
% ============================================================

test(failing_requirement_repairs_then_fails, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_run_spec(S,
                  spec{id: s5, goal: g, mode: symbolic,
                       requirements: [req(r1, 'impossible', never)],
                       max_repairs: 2},
                  O),
    get_dict(status, O, failed),
    get_dict(attempts, O, 3),
    get_dict(verifications, O, Vs),
    length(Vs, 3),
    forall(member(V, Vs), get_dict(status, V, fail)),
    get_dict(repairs, O, Rs),
    length(Rs, 2),
    \+ event_data(S, completion, _),
    event_data(S, failure, FD),
    get_dict(reason, FD, attempts_exhausted),
    % The frozen spec is identical across attempts: every specification
    % event carries the same goal.
    all_event_data(S, specification, Specs),
    length(Specs, 3),
    forall(member(D, Specs), get_dict(goal, D, g)),
    forall(member(D, Specs), get_dict(mode, D, symbolic)).

% ============================================================
% 6. Passing requirement (CheckTerm true): completed attempt 1
% ============================================================

test(passing_requirement_completes, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_run_spec(S,
                  spec{id: s6, goal: g, mode: symbolic,
                       requirements: [req(r1, 'trivial', true)]},
                  O),
    get_dict(status, O, completed),
    get_dict(attempts, O, 1),
    event_data(S, verification, ReqV),
    get_dict(req, ReqV, r1),
    get_dict(status, ReqV, pass),
    event_data(S, completion, _).

% ============================================================
% 7. Repair actually changes the plan (planned_reorder rotation)
% ============================================================

test(repair_reorders_plan, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    failing_tool(fail_always, FailingTool),
    prlm_tool_register(S, FailingTool, _),
    prlm_run_spec(S,
                  spec{id: s7, goal: g, mode: symbolic,
                       requirements: [req(r1, 'd', never)],
                       max_repairs: 1},
                  O),
    get_dict(status, O, failed),
    get_dict(attempts, O, 2),
    get_dict(repairs, O, [planned_reorder]),
    all_event_data(S, plan, Plans),
    Plans = [P1, P2],
    get_dict(steps, P1, Steps1),
    get_dict(steps, P2, Steps2),
    Steps1 \= Steps2,
    % attempt 1: lang plan prepended the tool step for the first tool
    Steps1 = [step(n(1), tool_call_step(fail_always, none)),
              step(n(2), verify_step(r1)),
              step(n(3), yield_step(goal_done(g)))],
    % attempt 2: rotated left by one, renumbered
    Steps2 = [step(n(1), verify_step(r1)),
              step(n(2), yield_step(goal_done(g))),
              step(n(3), tool_call_step(fail_always, none))],
    get_dict(observations, O, Obs),
    member(Ob, Obs),
    get_dict(op, Ob, tool_call_step(fail_always, none)),
    get_dict(status, Ob, error),
    !.

% ============================================================
% 8. symbolic_recursive allows spawn; symbolic forbids it
% ============================================================

test(symbolic_recursive_spawn_ok, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    % warm run loads the lang sources into this session's engine
    prlm_run_spec(S, spec{id: warm, goal: g, mode: symbolic_recursive}, _),
    consult_spawn_plan(S),
    prlm_run_spec(S, spec{id: s8a, goal: my_goal(1),
                          mode: symbolic_recursive}, O),
    get_dict(status, O, completed),
    get_dict(result, O, goal_done(my_goal(1))),
    event_data(S, actor_spawn, _),
    get_dict(observations, O, Obs),
    member(Ob, Obs),
    get_dict(op, Ob, spawn_agent_step(sub)),
    get_dict(status, Ob, ok),
    get_dict(value, Ob, goal_done(my_goal(1))),
    !.

test(symbolic_spawn_forbidden, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_run_spec(S, spec{id: warm, goal: g, mode: symbolic}, _),
    consult_spawn_plan(S),
    prlm_run_spec(S,
                  spec{id: s8b, goal: gg, mode: symbolic,
                       requirements: [req(r1, 'd', never)],
                       max_repairs: 1},
                  O),
    get_dict(status, O, failed),
    get_dict(attempts, O, 2),
    get_dict(observations, O, Obs),
    member(Ob, Obs),
    get_dict(status, Ob, forbidden_in_mode),
    !,
    \+ event_data(S, actor_spawn, _).

% ============================================================
% 9. Mode commands and /learn
% ============================================================

test(mode_commands, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_mode_command(S, '/learn', learn_outcome{status: nothing_to_learn}),
    prlm_mode_command(S, '/symbolic prove(this)', O1),
    get_dict(status, O1, completed),
    prlm_last_outcome(S, O1),
    prlm_mode_command(S, '/learn', learn_outcome{status: ok}),
    prlm_mode_command(S, '/frobnicate now', O2),
    get_dict(status, O2, failed),
    get_dict(result, O2, unknown_command),
    prlm_mode_command(S, '/direct (((', O3),
    get_dict(status, O3, failed),
    get_dict(result, O3, parse_error).

% ============================================================
% 10. Cancellation throws through
% ============================================================

test(cancelled_session_throws, [cleanup(free_sess(S))]) :-
    sess_new([], S),
    prlm_session_token(S, Token),
    prlm_cancel(Token),
    catch((   prlm_run_spec(S, spec{id: s10, goal: g, mode: symbolic}, _)
          ->  throw(run_should_have_thrown)
          ;   throw(run_should_have_thrown)
          ),
          prlm_error(cancellation, Info),
          is_dict(Info)).

% ============================================================
% 11. Steps budget exhaustion propagates
% ============================================================

test(steps_budget_exceeded_throws, [cleanup(free_sess(S))]) :-
    sess_new([budgets(_{steps: 3})], S),
    Reqs = [req(r1, d1, true), req(r2, d2, true), req(r3, d3, true)],
    catch((   prlm_run_spec(S, spec{id: s11, goal: g, mode: symbolic,
                                    requirements: Reqs}, _)
          ->  throw(no_budget_error)
          ;   throw(no_budget_error)
          ),
          prlm_error(budget_exceeded, Info),
          is_dict(Info)).

% ============================================================
% 12. ctx_compile_step skipped when prlm_context is absent
% ============================================================

test(ctx_compile_step_environment_tolerant, [cleanup(free_sess(S))]) :-
    % whatever the environment (prlm_context loaded or not), the ctx step
    % must keep the run completing and record its status honestly.
    sess_new([], S),
    consult_ctx_plan(S),
    prlm_run_spec(S, spec{id: s12, goal: gg, mode: symbolic}, O),
    get_dict(status, O, completed),
    get_dict(observations, O, Obs),
    member(Ob, Obs),
    get_dict(op, Ob, ctx_compile_step),
    (   current_predicate(prlm_context:prlm_ctx_compile/3)
    ->  get_dict(status, Ob, ok)
    ;   get_dict(status, Ob, skipped),
        get_dict(value, Ob, context_compiler_absent)
    ),
    !.

:- end_tests(prlm_rlm).
