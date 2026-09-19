:- module(prlm_rlm,
          [ prlm_rlm_ready/0,
            prlm_run_spec/3,
            prlm_mode_command/3,
            prlm_last_outcome/2
          ]).

/** <module> prlm_rlm — the RLM language execution loop

SPEC -> PLAN -> EXECUTE -> VERIFY -> LEARN -> CONTINUE, per attempt, with
REPAIR/REPLANNING on verification failure.  A failed verification NEVER
weakens the specification: the spec is frozen once per run (also stored in
the session KVS under key `rlm_frozen_spec`) and repairs only change the
PLAN.  This module is where "RLM is language semantics".

Per-attempt loop
================

  1. SPEC    : emit `specification` {spec_id, goal, mode, attempt} from the
               frozen spec — identical every attempt.
  2. MODE    : mode=auto resolves via the in-language rules (engine module
               `prlm_rlm_lang`, loaded from lang/prlm_mode.prlm; host
               fallback with identical semantics).  Markers come from the
               session KVS key `rlm_markers` (markers(NeedsTools, NeedsAgents,
               ModelOnly), booleans true/false) when present, else derived:
               NeedsTools=true iff any tool is registered on the session,
               NeedsAgents=false, ModelOnly = \+ NeedsTools.  Emits
               `mode_select` {spec_id, attempt, requested, resolved, markers}.
  3. PLAN    : plan{attempt, steps}; steps built by engine predicate
               prlm_rlm_lang:plan_spec/3 (from lang/prlm_plan.prlm), host
               fallback with identical shapes.  Emits `plan`
               {spec_id, attempt, source: lang|host, reordered, steps}.
               Repairs transform the plan: repair(add_model_step) prepends a
               model_call_step(GoalText); repair(planned_reorder) rotates the
               step list left by one.  Steps are then (re)numbered n(1)..n(K).
  4. EXECUTE : each step: prlm_check_cancelled, budget check+charge steps=1,
               op dispatch, `observation` event + observation{attempt,
               step_id, op, status, value, time} record.
  5. VERIFY  : all requirements pass -> pass; no requirements -> pass iff a
               yield_step recorded a result.  Emits per-requirement
               `verification` events during dispatch and one aggregate
               `verification` {spec_id, attempt, status, failures} per attempt.
  6. LEARN   : pass -> `learning` {spec_id, attempt, result, source: run} ->
               `completion` -> outcome completed (and stored as the session's
               last outcome).  fail -> `repair` {spec_id, attempt, repair,
               next_attempt} -> replan -> continue; attempts exhausted
               (max_repairs+1 total) -> `failure` -> outcome failed.

Step ids and op shapes (shared with lang/prlm_plan.prlm)
========================================================

  step(n(I), Op) with I = 1,2,3,... in plan order (structured id: the stage0
  engine has no atom construction, so ids are n(I), not the atom n1).

  * model_call_step(Text)       : prlm_model_call -> prlm_validate_proposal;
                                  rejected -> observation status
                                  proposal_rejected + `failure`; accepted ->
                                  validated Op dispatched recursively, at
                                  most 8 nested dispatches (deeper -> status
                                  error dispatch_depth_exceeded + `failure`).
                                  Every nested dispatch emits its own
                                  observation record/event, keyed to the
                                  parent step_id.
  * tool_call_step(Name, Args)  : prlm_tool_call with caller caps from
                                  session KVS `rlm_caps` (default []); Args
                                  is a dict or the atom `none` (= empty
                                  args dict); any gate/handler throw or
                                  result status error -> status error.
  * ctx_compile_step            : delegated to prlm_context:prlm_ctx_compile/3
                                  when that predicate exists (emits
                                  `context_compiled`), else observation
                                  status skipped, value
                                  context_compiler_absent.
  * ctx_op_step(OpT)            : delegated to prlm_context:prlm_ctx_op/3
                                  when loaded, else skipped as above.
  * assert_fact_step(Module, T) : prlm_kernel:prlm_assertz/3.
  * verify_step(ReqId)          : requirement check — host rule first:
                                  CheckTerm == never NEVER passes; then the
                                  in-language checker prlm_rlm_lang:
                                  check_requirement(ReqId, Observations,
                                  Result) (Result = true|false; Observations
                                  = [obs(StepId, Op, Status, Value), ...] in
                                  execution order) when clauses exist
                                  (missing/false = fail closed); otherwise
                                  host fallback = pass, recorded with
                                  checker none.  The step itself has status
                                  ok even when the check fails (the failure
                                  surfaces in VERIFY).
  * yield_step(Value)           : records the run result.
  * learn_step(T)               : emits `learning` {spec_id, attempt, data,
                                  source: step}.
  * spawn_agent_step(Spec)      : only legal in mode symbolic_recursive,
                                  else observation status forbidden_in_mode
                                  + `failure`.  Spec is an agent dict or an
                                  atom name (host builds agent{name: Spec,
                                  goal: <spec goal>, mode:
                                  symbolic_recursive, caps: [],
                                  authority: approve_diff});
                                  prlm_agent_spawn + prlm_agent_ask; the
                                  structured agent result value becomes the
                                  observation value.
  * send_message_step(To, Msg)  : only legal in symbolic_recursive; prlm_send.

Verification/repair policy (deterministic)
==========================================

  repair(planned_reorder) if any step of the attempt had status error;
  else repair(add_model_step) if no model_call_step ran and the session
  provider is not prolog; else repair(retry).  forbidden_in_mode and
  proposal_rejected do NOT count as step errors (reordering cannot fix a
  mode violation).  Direct mode never repairs: its single failure is final.

Direct path
===========

  One prlm_model_call with the goal text as the user message.  The proposal
  text is the result WITHOUT validation-as-plan (a parsed proposal term is
  never executed in direct mode).  Emits model_call (by the provider
  module), observation, verification (pass iff proposal status ok) and, on
  pass, learning/completion.  Provider prolog + status unsupported ->
  outcome failed with result prolog_provider_unsupported.

Errors: cancellation (prlm_error(cancellation,_)) and budget exhaustion
(prlm_error(budget_exceeded,_)) throw through to the caller.
*/

:- use_module(library(lists)).
:- use_module(library(gensym)).
:- use_module(library(readutil)).
:- use_module('./prlm_kernel').
:- use_module('./prlm_session').
:- use_module('./prlm_providers').
:- use_module('./prlm_tools').
:- use_module('./prlm_actors').

:- discontiguous dispatch_known/9.

% ============================================================
% In-language sources (lang/prlm_mode.prlm, lang/prlm_plan.prlm)
% ============================================================

% Resolved once at load time, relative to this file: <repo>/lang/.
:- dynamic lang_source/2.
:- (   prolog_load_context(directory, Dir),
       file_directory_name(Dir, RepoDir),
       directory_file_path(RepoDir, lang, LangDir),
       directory_file_path(LangDir, 'prlm_mode.prlm', ModeFile),
       directory_file_path(LangDir, 'prlm_plan.prlm', PlanFile),
       assertz(lang_source(prlm_mode, ModeFile)),
       assertz(lang_source(prlm_plan, PlanFile))
   ->  true
   ;   true
   ).

prlm_rlm_ready :-
    lang_source(prlm_mode, _),
    lang_source(prlm_plan, _).

% Lazily consult both lang sources into the session engine.  Each file is
% loaded under its own declared module name (prlm_consult_source requires the
% fixed module to match the file's module/2 declaration); module
% `prlm_rlm_lang` is then declared as the umbrella that imports both, so the
% host calls everything uniformly via prlm_rlm_lang, and in-language
% specialisations (e.g. plan_spec/3 or check_requirement/3 clauses) are
% consulted into prlm_rlm_lang where local clauses shadow the imports.
ensure_lang(Session) :-
    (   prlm_session_get(Session, rlm_lang_loaded, _)
    ->  true
    ;   (   prlm_session_engine(Session, Engine),
            catch(load_lang_files(Engine), _, fail)
        ->  prlm_session_put(Session, rlm_lang_loaded, true)
        ;   prlm_session_put(Session, rlm_lang_loaded, false)   % host fallback
        )
    ).

load_lang_files(Engine) :-
    lang_source(prlm_mode, ModeFile),
    lang_source(prlm_plan, PlanFile),
    read_file_to_string(ModeFile, ModeText, []),
    read_file_to_string(PlanFile, PlanText, []),
    prlm_consult_source(Engine, prlm_mode, ModeText, ModeFile),
    prlm_consult_source(Engine, prlm_plan, PlanText, PlanFile),
    Umbrella = ":- module(prlm_rlm_lang, []).\n\c
                \c:- use_module(prlm_mode).\n\c
                \c:- use_module(prlm_plan).\n",
    prlm_consult_source(Engine, prlm_rlm_lang, Umbrella, '<prlm_rlm_lang>').

lang_ready(Session) :-
    prlm_session_get(Session, rlm_lang_loaded, true).

lang_select_mode(Session, Engine, Requested, Markers, Resolved) :-
    lang_ready(Session),
    catch(prlm_call_first(Engine, prlm_rlm_lang,
                          select_mode(Requested, Markers, ResolvedV),
                          [r-ResolvedV], D),
          _, fail),
    get_dict(r, D, Resolved).

lang_plan(Session, Engine, spec(SpecId, Goal, _Mode, Reqs), ResolvedMode,
          ToolNames, Ops) :-
    lang_ready(Session),
    catch(prlm_call_first(Engine, prlm_rlm_lang,
                          plan_spec(spec(SpecId, Goal, ResolvedMode, Reqs),
                                    ToolNames, OpsV),
                          [s-OpsV], D),
          _, fail),
    get_dict(s, D, Ops),
    ground(Ops).

% ============================================================
% Spec normalisation (the spec is frozen after this point)
% ============================================================

normalize_spec(Session, Spec,
               spec{id: Id, goal: Goal, mode: Mode, requirements: Reqs,
                    max_repairs: MaxRepairs, invariants: Invariants}) :-
    (   is_dict(Spec)
    ->  true
    ;   throw(prlm_error(type_error, _{spec: Spec}))
    ),
    (   get_dict(id, Spec, Id0), atom(Id0)
    ->  Id = Id0
    ;   throw(prlm_error(type_error, _{spec: Spec, reason: bad_id}))
    ),
    (   get_dict(goal, Spec, Goal0), ground(Goal0)
    ->  Goal = Goal0
    ;   throw(prlm_error(type_error, _{spec: Spec, reason: bad_goal}))
    ),
    (   get_dict(mode, Spec, Mode0) -> true ; Mode0 = auto ),
    (   memberchk(Mode0, [direct, symbolic, symbolic_recursive, auto])
    ->  Mode = Mode0
    ;   throw(prlm_error(type_error, _{spec_mode: Mode0}))
    ),
    (   get_dict(requirements, Spec, Reqs0) -> true ; Reqs0 = [] ),
    (   is_list(Reqs0),
        forall(member(R, Reqs0), valid_requirement(R))
    ->  Reqs = Reqs0
    ;   throw(prlm_error(type_error, _{requirements: Reqs0}))
    ),
    (   get_dict(max_repairs, Spec, MR0)
    ->  true
    ;   prlm_session_option(Session, repairs, MR0)
    ),
    (   integer(MR0), MR0 >= 0
    ->  MaxRepairs = MR0
    ;   throw(prlm_error(type_error, _{max_repairs: MR0}))
    ),
    (   get_dict(invariants, Spec, Inv0) -> true ; Inv0 = [] ),
    (   is_list(Inv0), forall(member(I, Inv0), ground(I))
    ->  Invariants = Inv0
    ;   throw(prlm_error(type_error, _{invariants: Inv0}))
    ).

valid_requirement(req(Id, Desc, Check)) :-
    atom(Id),
    ground(Desc),
    ground(Check).

% ============================================================
% Mode resolution (markers -> resolved mode)
% ============================================================

resolve_mode(Session, Requested, Markers, Resolved) :-
    markers_of(Session, Markers),
    prlm_session_engine(Session, Engine),
    (   lang_select_mode(Session, Engine, Requested, Markers, Resolved)
    ->  true
    ;   host_select_mode(Requested, Markers, Resolved)
    ).

markers_of(Session, markers(NT, NA, MO)) :-
    (   prlm_session_get(Session, rlm_markers, M0)
    ->  M0 = markers(NT, NA, MO)
    ;   derive_markers(Session, NT, NA, MO)
    ),
    marker_bool(NT),
    marker_bool(NA),
    marker_bool(MO).

derive_markers(Session, NeedsTools, false, ModelOnly) :-
    (   prlm_tool_discover(Session, [_|_])
    ->  NeedsTools = true,
        ModelOnly = false
    ;   NeedsTools = false,
        ModelOnly = true
    ).

marker_bool(true).
marker_bool(false).

host_select_mode(auto, markers(NT, NA, MO), direct) :-
    MO == true, NT == false, NA == false,
    !.
host_select_mode(auto, markers(_, NA, _), symbolic_recursive) :-
    NA == true,
    !.
host_select_mode(auto, _, symbolic).
host_select_mode(Mode, _, Mode).

% ============================================================
% Run state (one dict threaded through an attempt chain)
% ============================================================
% rlm_st{attempt, requested, mode, markers, max_repairs, invariants,
%        observations (newest first), verifications (newest first),
%        result (none until yield), repairs (newest first),
%        steps, model_calls, tool_calls, last_failures}

prlm_run_spec(Session, Spec0, Outcome) :-
    prlm_check_cancelled(Session),
    normalize_spec(Session, Spec0, Spec),
    ensure_lang(Session),
    Spec = spec{id: SpecId, goal: Goal, mode: SpecMode, requirements: Reqs,
                max_repairs: MaxRepairs, invariants: Invariants},
    Frozen = spec(SpecId, Goal, SpecMode, Reqs),
    prlm_session_put(Session, rlm_frozen_spec, Frozen),
    resolve_mode(Session, SpecMode, Markers, Mode),
    St0 = rlm_st{attempt: 1, requested: SpecMode, mode: Mode,
                 markers: Markers, max_repairs: MaxRepairs,
                 invariants: Invariants, observations: [],
                 verifications: [], result: none, repairs: [],
                 steps: 0, model_calls: 0, tool_calls: 0,
                 last_failures: []},
    run_attempt(Session, Frozen, St0, Outcome).

run_attempt(Session, Frozen, St0, Outcome) :-
    prlm_check_cancelled(Session),
    Frozen = spec(SpecId, Goal, _, _),
    Attempt = St0.attempt,
    prlm_event_emit(Session, specification,
                    _{spec_id: SpecId, goal: Goal, mode: St0.requested,
                      attempt: Attempt}),
    prlm_event_emit(Session, mode_select,
                    _{spec_id: SpecId, attempt: Attempt,
                      requested: St0.requested, resolved: St0.mode,
                      markers: St0.markers}),
    (   St0.mode == direct
    ->  direct_path(Session, Frozen, St0, St1, Pass)
    ;   symbolic_attempt(Session, Frozen, St0, St1, Pass)
    ),
    (   Pass == true
    ->  complete(Session, Frozen, St1, Outcome)
    ;   St0.mode == direct
    ->  direct_failed(Session, Frozen, St1, Outcome)
    ;   St1.attempt =< St1.max_repairs
    ->  repair_and_continue(Session, Frozen, St1, Outcome)
    ;   exhausted(Session, Frozen, St1, Outcome)
    ).

complete(Session, Frozen, St, Outcome) :-
    Frozen = spec(SpecId, _, _, _),
    prlm_event_emit(Session, learning,
                    _{spec_id: SpecId, attempt: St.attempt, result: St.result,
                      source: run}),
    prlm_event_emit(Session, completion,
                    _{spec_id: SpecId, attempts: St.attempt,
                      result: St.result}),
    finalize(St, completed, SpecId, Outcome),
    retractall(rlm_last_outcome(Session, _)),
    assertz(rlm_last_outcome(Session, Outcome)).

repair_and_continue(Session, Frozen, St0, Outcome) :-
    repair_term(Session, St0, Repair),
    Frozen = spec(SpecId, _, _, _),
    NextAttempt is St0.attempt + 1,
    prlm_event_emit(Session, repair,
                    _{spec_id: SpecId, attempt: St0.attempt, repair: Repair,
                      next_attempt: NextAttempt}),
    St1 = St0.put(attempt, NextAttempt).put(repairs, [Repair|St0.repairs]),
    run_attempt(Session, Frozen, St1, Outcome).

exhausted(Session, Frozen, St, Outcome) :-
    Frozen = spec(SpecId, _, _, _),
    prlm_event_emit(Session, failure,
                    _{spec_id: SpecId, attempts: St.attempt,
                      reason: attempts_exhausted,
                      failures: St.last_failures}),
    finalize(St, failed, SpecId, Outcome).

direct_failed(Session, Frozen, St, Outcome) :-
    Frozen = spec(SpecId, _, _, _),
    prlm_event_emit(Session, failure,
                    _{spec_id: SpecId, attempt: St.attempt,
                      reason: St.last_failures}),
    finalize(St, failed, SpecId, Outcome).

finalize(St, Status, SpecId,
         rlm_outcome{status: Status,
                     spec_id: SpecId,
                     attempts: St.attempt,
                     observations: ObsR,
                     verifications: VerR,
                     result: St.result,
                     repairs: RepairsR,
                     usage: usage{steps: St.steps,
                                  model_calls: St.model_calls,
                                  tool_calls: St.tool_calls}}) :-
    reverse(St.observations, ObsR),
    reverse(St.verifications, VerR),
    reverse(St.repairs, RepairsR).

%! repair_term(+Session, +St, -Repair) is det
%
% Deterministic repair policy (see module header).
repair_term(_Session, St, planned_reorder) :-
    any_error_step(St),
    !.
repair_term(Session, St, add_model_step) :-
    \+ ran_model_call(St),
    prlm_session_option(Session, provider, Provider),
    Provider \== prolog,
    !.
repair_term(_, _, retry).

% Committed scans (a successful member/2 would leave a pending choicepoint
% for the rest of the run).

any_error_step(St) :-
    Attempt = St.attempt,
    scan_status(St.observations, Attempt, error),
    !.

scan_status([O|Os], Attempt, Status) :-
    (   get_dict(attempt, O, Attempt),
        get_dict(status, O, Status)
    ->  true
    ;   scan_status(Os, Attempt, Status)
    ).

ran_model_call(St) :-
    scan_op(St.observations, model_call_step(_)),
    !.

scan_op([O|Os], Pattern) :-
    (   get_dict(op, O, Pattern)
    ->  true
    ;   scan_op(Os, Pattern)
    ).

% ============================================================
% Symbolic path: PLAN -> EXECUTE -> VERIFY
% ============================================================

symbolic_attempt(Session, Frozen, St0, St2, Pass) :-
    build_plan(Session, Frozen, St0, Plan),
    exec_steps(Session, Frozen, Plan, St0, St1),
    verify_attempt(Session, Frozen, St1, St2, Pass).

tool_names(Session, Names) :-
    prlm_tool_discover(Session, Tools),
    tools_names_(Tools, Names).

tools_names_([], []).
tools_names_([T|Ts], [N|Ns]) :-
    get_dict(name, T, N),
    tools_names_(Ts, Ns).

host_plan(spec(_, Goal, Mode, Reqs), Mode, ToolNames, Ops) :-
    (   Mode == symbolic,
        ToolNames = [FirstTool|_]
    ->  Pre = [tool_call_step(FirstTool, none)]
    ;   Pre = []
    ),
    findall(verify_step(Id), member(req(Id, _, _), Reqs), VerifyOps),
    append(Pre, VerifyOps, Mid),
    append(Mid, [yield_step(goal_done(Goal))], Ops).

build_plan(Session, Frozen, St, Plan) :-
    Frozen = spec(SpecId, Goal, _, _Reqs),
    prlm_session_engine(Session, Engine),
    tool_names(Session, ToolNames),
    % Both plan sources are normalised to unnumbered ops; ids are
    % positional per plan build (regenerated after every transform).
    (   lang_plan(Session, Engine, Frozen, St.mode, ToolNames, LangSteps)
    ->  steps_ops(LangSteps, BaseOps),
        Source = lang
    ;   host_plan(Frozen, St.mode, ToolNames, BaseOps),
        Source = host
    ),
    (   St.repairs = [LastRepair|_]
    ->  true
    ;   LastRepair = none
    ),
    goal_text(Goal, GoalText),
    (   LastRepair == add_model_step
    ->  Ops = [model_call_step(GoalText)|BaseOps],
        Reordered = false
    ;   LastRepair == planned_reorder
    ->  rotate(BaseOps, Ops),
        Reordered = true
    ;   Ops = BaseOps,
        Reordered = false
    ),
    number_ops(Ops, 1, Steps),
    Plan = plan{attempt: St.attempt, steps: Steps},
    prlm_event_emit(Session, plan,
                    _{spec_id: SpecId, attempt: St.attempt, source: Source,
                      reordered: Reordered, steps: Steps}).

steps_ops([], []).
steps_ops([step(_, Op)|Steps], [Op|Ops]) :-
    steps_ops(Steps, Ops).

rotate([First|Rest], Rotated) :-
    append(Rest, [First], Rotated).

number_ops([], _, []).
number_ops([Op|Ops], N, [step(n(N), Op)|Steps]) :-
    N1 is N + 1,
    number_ops(Ops, N1, Steps).

goal_text(Goal, Text) :-
    (   atom(Goal) -> Text = Goal
    ;   string(Goal) -> Text = Goal
    ;   term_to_atom(Goal, Text)
    ).

% ============================================================
% Step execution
% ============================================================

exec_steps(_, _, Plan, St, St) :-
    get_dict(steps, Plan, []),
    !.
exec_steps(Session, Frozen, Plan, St0, St) :-
    get_dict(steps, Plan, [step(StepId, Op)|Rest]),
    prlm_check_cancelled(Session),
    charge_steps(Session, St0, St0a),
    get_time(Time),
    dispatch_op(Session, Frozen, StepId, Op, 0, St0a, Value, Status, St1),
    Obs = observation{attempt: St0.attempt, step_id: StepId, op: Op,
                      status: Status, value: Value, time: Time},
    prlm_event_emit(Session, observation, Obs),
    St1b = St1.put(observations, [Obs|St1.observations]),
    PlanRest = plan{attempt: Plan.attempt, steps: Rest},
    exec_steps(Session, Frozen, PlanRest, St1b, St).

charge_steps(Session, St, St2) :-
    prlm_budget_check(Session, steps, 1),
    prlm_budget_charge(Session, steps, 1),
    Steps1 is St.steps + 1,
    St2 = St.put(steps, Steps1).

report_failure(Session, Frozen, St, Reason, Data) :-
    Frozen = spec(SpecId, _, _, _),
    prlm_event_emit(Session, failure,
                    _{spec_id: SpecId, attempt: St.attempt,
                      reason: Reason}.put(Data)).

% --- dispatch: committed choice between unknown-op error, the nested
% dispatch depth bound, and the known ops (no pending clause choicepoints
% may survive a step) ---

dispatch_op(Session, Frozen, StepId, Op, Depth, St0, Value, Status, St2) :-
    (   \+ op_known(Op)
    ->  Value = unknown_op(Op),
        Status = error,
        St2 = St0
    ;   Depth > 8
    ->  Value = dispatch_depth_exceeded,
        Status = error,
        St2 = St0,
        report_failure(Session, Frozen, St0, dispatch_depth_exceeded,
                       _{op: Op, step_id: StepId})
    ;   % once/1: each dispatch_known clause is deterministic, but SWI cannot
        % index the clause set (leading args are variables), so later clauses
        % would linger as pending choicepoints after a successful dispatch.
        once(dispatch_known(Session, Frozen, StepId, Op, Depth, St0,
                            Value, Status, St2))
    ).

% --- model_call_step: model -> validate -> recursive dispatch ---

dispatch_known(Session, Frozen, StepId, model_call_step(Text), Depth, St0,
               Value, Status, St2) :-
    catch(model_call_dispatch(Session, Frozen, StepId, Text, Depth, St0,
                              Value, Status, St2),
          Err,
          (   closed_ball(Err, Value),
              Status = error,
              St2 = St0
          )).

model_call_dispatch(Session, Frozen, StepId, Text, Depth, St0,
                    Value, Status, St2) :-
    ModelCalls1 is St0.model_calls + 1,
    St1 = St0.put(model_calls, ModelCalls1),
    % once/1: prlm_model_call is det by contract, but the provider module's
    % adapter dispatch leaves a pending clause choicepoint behind.
    once(prlm_model_call(Session, [msg(user, Text)], _{}, Proposal)),
    (   get_dict(status, Proposal, ok)
    ->  prlm_validate_proposal(Session, Proposal, Op),
        (   Op = rejected(_)
        ->  Value = Op,
            Status = proposal_rejected,
            St2 = St1,
            report_failure(Session, Frozen, St1, proposal_rejected,
                           _{op: Op, step_id: StepId})
        ;   Depth1 is Depth + 1,
            charge_steps(Session, St1, St1b),
            dispatch_op(Session, Frozen, StepId, Op, Depth1, St1b,
                        Value, Status, St2a),
            % The dispatched proposal op is a step of its own: observable.
            get_time(NestedTime),
            NestedObs = observation{attempt: St1b.attempt, step_id: StepId,
                                    op: Op, status: Status, value: Value,
                                    time: NestedTime},
            prlm_event_emit(Session, observation, NestedObs),
            St2 = St2a.put(observations, [NestedObs|St2a.observations])
        )
    ;   get_dict(status, Proposal, unsupported)
    ->  Value = unsupported,
        Status = error,
        St2 = St1
    ;   get_dict(reason, Proposal, Reason)
    ->  Value = Reason,
        Status = error,
        St2 = St1
    ;   Value = unknown_proposal_status,
        Status = error,
        St2 = St1
    ).

% --- tool_call_step ---

dispatch_known(Session, _Frozen, _StepId, tool_call_step(Name, ArgsIn), _Depth,
            St0, Value, Status, St2) :-
    ToolCalls1 is St0.tool_calls + 1,
    St1 = St0.put(tool_calls, ToolCalls1),
    (   catch((arg_dict(ArgsIn, Args),
               caps_of(Session, Caps),
               prlm_tool_call(Session, Caps, Name, Args, Result)),
              Err, true)
    ->  tool_outcome_value(Result, Err, Value, Status)
    ;   Value = tool_failed,
        Status = error
    ),
    St2 = St1.

tool_outcome_value(Result, _Err, Value, ok) :-
    nonvar(Result),
    get_dict(status, Result, ok),
    !,
    get_dict(value, Result, Value).
tool_outcome_value(Result, _Err, Value, error) :-
    nonvar(Result),
    get_dict(value, Result, Value),
    !.
tool_outcome_value(_, Err, Value, error) :-
    closed_ball(Err, Value).

arg_dict(none, Args) :-
    !,
    dict_create(Args, args, []).
arg_dict(Args, Args) :-
    is_dict(Args),
    !.
arg_dict(Args, _) :-
    throw(prlm_error(type_error, _{tool_args: Args})).

caps_of(Session, Caps) :-
    (   prlm_session_get(Session, rlm_caps, Caps)
    ->  true
    ;   Caps = []
    ).

% --- ctx_compile_step / ctx_op_step ---

dispatch_known(Session, Frozen, StepId, ctx_compile_step, _Depth, St0,
            Value, Status, St0) :-
    (   current_predicate(prlm_context:prlm_ctx_compile/3)
    ->  call_with_result(prlm_context:prlm_ctx_compile(Session, 100000),
                          Value, Status),
        (   Status == ok
        ->  Frozen = spec(SpecId, _, _, _),
            prlm_event_emit(Session, context_compiled,
                            _{spec_id: SpecId, step_id: StepId,
                              source: prlm_context})
        ;   true
        )
    ;   Value = context_compiler_absent,
        Status = skipped
    ).

dispatch_known(Session, _Frozen, _StepId, ctx_op_step(OpT), _Depth, St0,
            Value, Status, St0) :-
    (   current_predicate(prlm_context:prlm_ctx_op/3)
    ->  call_with_result(prlm_context:prlm_ctx_op(Session, OpT),
                         Value, Status)
    ;   Value = context_compiler_absent,
        Status = skipped
    ).

call_with_result(Goal0, Value, Status) :-
    (   catch(call(Goal0, Value), Err,
              (   closed_ball(Err, Value),
                  Status = error
              ))
    ->  (   var(Status) -> Status = ok ; true )
    ;   Value = goal_failed,
        Status = error
    ).

% --- assert_fact_step ---

dispatch_known(Session, _Frozen, _StepId, assert_fact_step(Module, Term), _Depth,
            St0, Value, Status, St0) :-
    prlm_session_engine(Session, Engine),
    (   catch(prlm_assertz(Engine, Module, Term), Err, true)
    ->  (   var(Err)
        ->  Value = Term,
            Status = ok
        ;   closed_ball(Err, Value),
            Status = error
        )
    ;   Value = assert_failed,
        Status = error
    ).

% --- verify_step ---

dispatch_known(Session, Frozen, _StepId, verify_step(ReqId), _Depth, St0,
            Value, Status, St0) :-
    Frozen = spec(SpecId, _, _, Reqs),
    Attempt = St0.attempt,
    (   req_lookup(Reqs, ReqId, Check)
    ->  obs_tuples(St0, ObsTuples),
        requirement_check(Session, ReqId, Check, ObsTuples,
                          Checker, Pass, FailInfo),
        (   Pass == true
        ->  Value = pass,
            VStatus = pass,
            Failures = []
        ;   Value = fail(FailInfo),
            VStatus = fail,
            Failures = [FailInfo]
        ),
        Status = ok
    ;   Value = unknown_requirement(ReqId),
        Status = error,
        Checker = none,
        VStatus = fail,
        Failures = [unknown_requirement(ReqId)]
    ),
    prlm_event_emit(Session, verification,
                    _{spec_id: SpecId, attempt: Attempt, req: ReqId,
                      status: VStatus, checker: Checker, failures: Failures}).

% Committed requirement lookup (a successful member/2 would leave a pending
% choicepoint for the rest of the run).
req_lookup([req(Id, _, Check)|_], Id, Check) :-
    !.
req_lookup([_|Reqs], Id, Check) :-
    req_lookup(Reqs, Id, Check).

% Host rule first: CheckTerm == never NEVER passes (the spec is never
% weakened).  Then the in-language checker prlm_rlm_lang:check_requirement/3
% when clauses exist (no solution or Result \== true fails closed).  Otherwise
% the requirement passes vacuously with checker none.
requirement_check(_Session, _ReqId, never, _ObsTuples, none, false, never) :-
    !.
requirement_check(Session, ReqId, _Check, ObsTuples, lang, Pass, FailInfo) :-
    lang_check(Session, ReqId, ObsTuples, Pass),
    !,
    (   Pass == true -> FailInfo = none ; FailInfo = lang_check_failed ).
requirement_check(_Session, _ReqId, _Check, _ObsTuples, none, true, none).

lang_check(Session, ReqId, ObsTuples, true) :-
    prlm_session_engine(Session, Engine),
    prlm_current_predicate(Engine, prlm_rlm_lang, check_requirement/3),
    catch(prlm_call_first(Engine, prlm_rlm_lang,
                          check_requirement(ReqId, ObsTuples, ResultV),
                          [r-ResultV], D),
          _, fail),
    get_dict(r, D, true).

obs_tuples(St, Tuples) :-
    reverse(St.observations, Obs),
    obs_tuples_(Obs, Tuples).

obs_tuples_([], []).
obs_tuples_([O|Os], [obs(StepId, Op, Status, Value)|Ts]) :-
    get_dict(step_id, O, StepId),
    get_dict(op, O, Op),
    get_dict(status, O, Status),
    get_dict(value, O, Value),
    obs_tuples_(Os, Ts).

% --- yield_step ---

dispatch_known(_Session, _Frozen, _StepId, yield_step(Value), _Depth, St0,
            Value, ok, St0.put(result, Value)).

% --- learn_step ---

dispatch_known(Session, Frozen, _StepId, learn_step(Data), _Depth, St0,
            Data, ok, St0) :-
    Frozen = spec(SpecId, _, _, _),
    prlm_event_emit(Session, learning,
                    _{spec_id: SpecId, attempt: St0.attempt, data: Data,
                      source: step}).

% --- spawn_agent_step ---

dispatch_known(Session, Frozen, StepId, spawn_agent_step(Spec), _Depth, St0,
            Value, Status, St0) :-
    Frozen = spec(_, Goal, _, _),
    (   St0.mode == symbolic_recursive
    ->  agent_profile(Spec, Goal, Profile),
        (   catch((prlm_agent_spawn(Session, none, Profile, AgentId),
                   prlm_agent_ask(Session, AgentId, AgentResult)),
                  Err, true)
        ->  agent_result_value(AgentResult, Err, Value, Status)
        ;   Value = agent_spawn_failed,
            Status = error
        )
    ;   Value = forbidden_in_mode,
        Status = forbidden_in_mode,
        report_failure(Session, Frozen, St0, forbidden_in_mode,
                       _{op: spawn_agent_step(Spec), step_id: StepId,
                         mode: St0.mode})
    ).

agent_result_value(AgentResult, _Err, Value, ok) :-
    nonvar(AgentResult),
    get_dict(status, AgentResult, ok),
    !,
    get_dict(value, AgentResult, Value).
agent_result_value(AgentResult, _Err, Value, error) :-
    nonvar(AgentResult),
    get_dict(value, AgentResult, Value),
    !.
agent_result_value(_, Err, Value, error) :-
    closed_ball(Err, Value).

agent_profile(Spec, Goal, Profile) :-
    (   atom(Spec)
    ->  Profile = agent{name: Spec, goal: Goal,
                        mode: symbolic_recursive, caps: [],
                        authority: approve_diff}
    ;   is_dict(Spec)
    ->  Profile = Spec
    ;   throw(prlm_error(type_error, _{agent_spec: Spec}))
    ).

% --- send_message_step ---

dispatch_known(Session, Frozen, StepId, send_message_step(To, Msg), _Depth, St0,
            Value, Status, St0) :-
    (   St0.mode == symbolic_recursive
    ->  (   catch(prlm_send(Session, To, Msg), Err, true)
        ->  (   var(Err)
            ->  Value = sent,
                Status = ok
            ;   closed_ball(Err, Value),
                Status = error
            )
        ;   Value = send_failed,
            Status = error
        )
    ;   Value = forbidden_in_mode,
        Status = forbidden_in_mode,
        report_failure(Session, Frozen, St0, forbidden_in_mode,
                       _{op: send_message_step(To, Msg), step_id: StepId,
                         mode: St0.mode})
    ).

% --- unknown ops never reach dispatch_known (see dispatch_op) ---

op_known(model_call_step(_)).
op_known(tool_call_step(_, _)).
op_known(ctx_compile_step).
op_known(ctx_op_step(_)).
op_known(assert_fact_step(_, _)).
op_known(verify_step(_)).
op_known(yield_step(_)).
op_known(learn_step(_)).
op_known(spawn_agent_step(_)).
op_known(send_message_step(_, _)).

% ============================================================
% VERIFY (aggregate per attempt)
% ============================================================

verify_attempt(Session, Frozen, St0, St, Pass) :-
    Frozen = spec(SpecId, _, _, Reqs),
    Attempt = St0.attempt,
    (   Reqs == []
    ->  (   St0.result == none
        ->  ReqFailures = [no_result]
        ;   ReqFailures = []
        )
    ;   req_failures(Reqs, St0, ReqFailures)
    ),
    inv_failures(St0.invariants, InvFailures),
    append(ReqFailures, InvFailures, Failures),
    (   Failures == []
    ->  Pass = true,
        VStatus = pass
    ;   Pass = false,
        VStatus = fail
    ),
    V = verification{attempt: Attempt, status: VStatus, failures: Failures},
    prlm_event_emit(Session, verification,
                    _{spec_id: SpecId, attempt: Attempt, status: VStatus,
                      failures: Failures}),
    St = St0.put(verifications, [V|St0.verifications])
            .put(last_failures, Failures).

req_failures([], _, []).
req_failures([req(Id, _, _)|Reqs], St, Fs) :-
    req_failures(Reqs, St, Fs0),
    (   req_passed(St, Id)
    ->  Fs = Fs0
    ;   (   req_ran(St, Id) -> Why = check_failed ; Why = unverified ),
        Fs = [fail_req(Id, Why)|Fs0]
    ).

req_passed(St, Id) :-
    Attempt = St.attempt,
    scan_verify(St.observations, Attempt, Id, pass),
    !.

req_ran(St, Id) :-
    Attempt = St.attempt,
    scan_verify_any(St.observations, Attempt, Id),
    !.

scan_verify([O|Os], Attempt, Id, Value) :-
    (   get_dict(attempt, O, Attempt),
        get_dict(op, O, verify_step(Id)),
        get_dict(value, O, Value)
    ->  true
    ;   scan_verify(Os, Attempt, Id, Value)
    ).

scan_verify_any([O|Os], Attempt, Id) :-
    (   get_dict(attempt, O, Attempt),
        get_dict(op, O, verify_step(Id))
    ->  true
    ;   scan_verify_any(Os, Attempt, Id)
    ).

% Invariants use the same never-rule as requirement checks: an invariant
% `never` fails the attempt; everything else passes (recorded host rule).
inv_failures([], []).
inv_failures([I|Is], Fs) :-
    inv_failures(Is, Fs0),
    (   I == never
    ->  Fs = [invariant(never)|Fs0]
    ;   Fs = Fs0
    ).

% ============================================================
% Direct path
% ============================================================

direct_path(Session, Frozen, St0, St1, Pass) :-
    Frozen = spec(SpecId, Goal, _, _),
    goal_text(Goal, Text),
    charge_steps(Session, St0, St0a),
    once(prlm_model_call(Session, [msg(user, Text)], _{}, Proposal)),
    ModelCalls1 is St0a.model_calls + 1,
    St0b = St0a.put(model_calls, ModelCalls1),
    get_time(Time),
    (   get_dict(status, Proposal, ok)
    ->  Status = ok,
        Value = Proposal.text,
        Pass = true,
        Failures = [],
        VStatus = pass
    ;   get_dict(status, Proposal, unsupported)
    ->  Status = error,
        Value = prolog_provider_unsupported,
        Pass = false,
        Failures = [prolog_provider_unsupported],
        VStatus = fail
    ;   get_dict(reason, Proposal, Reason)
    ->  Status = error,
        Value = Reason,
        Pass = false,
        Failures = [Reason],
        VStatus = fail
    ),
    % The proposal text is the result; a parsed proposal term is data and is
    % NEVER executed in direct mode.
    Obs = observation{attempt: 1, step_id: direct_call,
                      op: model_call_step(Text), status: Status,
                      value: Value, time: Time},
    prlm_event_emit(Session, observation, Obs),
    V = verification{attempt: 1, status: VStatus, failures: Failures},
    prlm_event_emit(Session, verification,
                    _{spec_id: SpecId, attempt: 1, status: VStatus,
                      failures: Failures}),
    St1 = St0b.put(observations, [Obs|St0b.observations])
               .put(verifications, [V|St0b.verifications])
               .put(result, Value)
               .put(last_failures, Failures).

% ============================================================
% Ground-ball helper (event data must be closed)
% ============================================================

closed_ball(Ball, Closed) :-
    (   ground(Ball)
    ->  Closed = Ball
    ;   copy_term(Ball, Copy),
        numbervars(Copy, 0, _),
        Closed = Copy
    ).

% ============================================================
% Mode commands: /direct /symbolic /symbolic-recursive /auto /learn
% ============================================================

%! prlm_mode_command(+Session, +CmdLine, -Outcome) is det
%
% CmdLine is an atom or string of the form "<command> <goal text>"; the rest
% after the first space is the goal text (parsed untrusted via
% prlm_read_goal/3, parse-only).
prlm_mode_command(Session, CmdLine, Outcome) :-
    cmd_text(CmdLine, Text),
    split_command(Text, Cmd, Rest),
    (   Cmd == '/learn'
    ->  learn_command(Session, Outcome)
    ;   cmd_mode(Cmd, Mode)
    ->  (   catch(prlm_read_goal(Rest, Goal, _), _, fail)
        ->  gensym(prlm_spec, SpecId),
            prlm_run_spec(Session,
                          spec{id: SpecId, goal: Goal, mode: Mode},
                          Outcome)
        ;   command_failure(Session, parse_error, Outcome)
        )
    ;   command_failure(Session, unknown_command, Outcome)
    ).

cmd_text(CmdLine, Text) :-
    (   atom(CmdLine) -> atom_string(CmdLine, Text)
    ;   string(CmdLine) -> Text = CmdLine
    ;   throw(prlm_error(type_error, _{command_line: CmdLine}))
    ).

split_command(Text, Cmd, Rest) :-
    (   once(sub_string(Text, Pos, 1, _, " "))
    ->  sub_string(Text, 0, Pos, _, W),
        atom_string(Cmd, W),
        Pos1 is Pos + 1,
        sub_string(Text, Pos1, _, 0, Rest)
    ;   atom_string(Cmd, Text),
        Rest = ""
    ).

cmd_mode('/direct', direct).
cmd_mode('/symbolic', symbolic).
cmd_mode('/symbolic-recursive', symbolic_recursive).
cmd_mode('/auto', auto).

learn_command(Session, learn_outcome{status: ok}) :-
    rlm_last_outcome(Session, Last),
    !,
    get_dict(spec_id, Last, SpecId),
    get_dict(result, Last, Result),
    prlm_event_emit(Session, learning,
                    _{source: mode_command, spec_id: SpecId,
                      result: Result}).
learn_command(_, learn_outcome{status: nothing_to_learn}).

command_failure(Session, Reason,
               rlm_outcome{status: failed, spec_id: none, attempts: 0,
                           observations: [], verifications: [],
                           result: Reason, repairs: [],
                           usage: usage{steps: 0, model_calls: 0,
                                        tool_calls: 0}}) :-
    prlm_event_emit(Session, failure,
                    _{source: mode_command, reason: Reason}).

% ============================================================
% Last completed outcome (per session)
% ============================================================

:- dynamic rlm_last_outcome/2.

prlm_last_outcome(Session, Outcome) :-
    rlm_last_outcome(Session, Outcome).
