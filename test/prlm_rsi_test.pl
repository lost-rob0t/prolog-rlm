:- begin_tests(prlm_rsi).

:- use_module('../prolog/prlm_rsi').
:- use_module('../prolog/prlm_session').
:- use_module('../prolog/prlm_kernel').
:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(pairs)).
:- use_module(library(readutil)).

% ============================================================
% Helpers
% ============================================================

sess_new(S) :-
    prlm_session_new([authority(allow_session)], S).

sess_destroy(S) :-
    catch(prlm_session_destroy(S), _, true).

% Fresh unique workspace root under /tmp/opencode per call.
tmp_root(Root) :-
    gensym(prlm_rsi_root, Id),
    atom_concat('/tmp/opencode/prlm_rsi_test_', Id, Root).

% Read the accepted tuning value through the kernel bridge (goal var and
% outspec var must be the same host variable).
accepted_tuning(Session, Value) :-
    prlm_session_engine(Session, Engine),
    prlm_call_first(Engine, rsi_tuning, batch_size(V), [value-V], R),
    get_dict(value, R, Value).

set_tuning(Session, Value) :-
    prlm_session_engine(Session, Engine),
    prlm_assertz(Engine, rsi_tuning, batch_size(Value)).

events_of_kind(Session, Kind, Selected) :-
    prlm_events(Session, 0, All),
    include(is_event_kind(Kind), All, Selected).

is_event_kind(Kind, Event) :-
    get_dict(type, Event, Kind).

data_with(Event, Key, Value) :-
    get_dict(data, Event, Data),
    get_dict(Key, Data, Value).

% prlm_rsi_facts/2 emits dicts whose TAG is the fact name, so the tag is
% the fact kind. All uses are existence checks: deterministic on purpose.
fact_of_kind(Facts, Kind, Fact) :-
    once(( member(Fact, Facts),
           is_dict(Fact, Kind) )).

event_with(Session, Type, Key, Value) :-
    events_of_kind(Session, Type, Events),
    once(( member(Event, Events),
           data_with(Event, Key, Value) )).

throws_prlm(Goal, Type, Check) :-
    catch(( call(Goal)
          -> throw(unexpected_success(Goal))
          ;  throw(unexpected_failure(Goal))
          ),
          prlm_error(Type, Info),
          call(Check, Info)).

tc_name(Event, Name) :-
    get_dict(data, Event, Data),
    get_dict(tool, Data, Name).

% ============================================================
% Readiness
% ============================================================

test(rsi_ready) :-
    prlm_rsi_ready.

% ============================================================
% Observe
% ============================================================

test(observe_records_knowledge) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_observe(S, Obs1),
    get_dict(knowledge_count, Obs1, 0),
    get_dict(engine_steps, Obs1, Steps1),
    integer(Steps1),
    Steps1 >= 0,
    get_dict(timestamp, Obs1, TS1),
    float(TS1),
    % machine work charged by the tuning read is visible to the next observe
    prlm_rsi_propose(S, Obs1, _Change),
    prlm_rsi_observe(S, Obs2),
    % observed(...) from observe 1 + proposed(...) from the proposal
    get_dict(knowledge_count, Obs2, 2),
    get_dict(engine_steps, Obs2, Steps2),
    Steps2 >= Steps1,
    sess_destroy(S).

% ============================================================
% Propose (deterministic)
% ============================================================

test(propose_is_deterministic_and_records_facts) :-
    sess_new(S),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, C1),
    C1 = change{id: Id1, target: benchmark_target, kind: tuning,
                patch: patch(batch_size, 16, 32)},
    atom(Id1),
    % propose never mutates the runtime: identical input, identical patch
    prlm_rsi_propose(S, Obs, C2),
    C2 = change{id: Id2, target: benchmark_target, kind: tuning,
                patch: patch(batch_size, 16, 32)},
    Id1 \== Id2,
    prlm_rsi_facts(S, Facts),
    fact_of_kind(Facts, experiment, experiment{id: Id1, desc: _}),
    fact_of_kind(Facts, experiment_change,
                 experiment_change{id: Id1, change: C1}),
    \+ fact_of_kind(Facts, experiment_result, _),
    sess_destroy(S).

test(propose_requires_observation_dict) :-
    sess_new(S),
    throws_prlm(prlm_rsi_propose(S, not_an_obs, _), type_error,
                chk_observation),
    sess_destroy(S).

chk_observation(Info) :-
    get_dict(observation, Info, not_an_obs).

test(propose_break_is_deterministic_regression) :-
    sess_new(S),
    prlm_rsi_propose_break(S, C),
    C = change{id: _, target: benchmark_target, kind: tuning,
               patch: patch(batch_size, 16, -1984)},
    sess_destroy(S).

% ============================================================
% Workspace guard
% ============================================================

test(missing_workspace_throws_before_any_effect) :-
    sess_new(S),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, Change),
    get_dict(id, Change, ExpId),
    throws_prlm(prlm_rsi_run(S, Change, _), existence_error,
                chk_workspace(ExpId)),
    % nothing was recorded beyond the propose facts
    prlm_rsi_facts(S, Facts),
    \+ fact_of_kind(Facts, experiment_metric, _),
    \+ fact_of_kind(Facts, experiment_result, _),
    sess_destroy(S).

chk_workspace(ExpId, Info) :-
    get_dict(workspace, Info, rsi_workspace_root),
    atom(ExpId).

% ============================================================
% ACCEPT path
% ============================================================

test(run_accepts_improved_candidate_and_promotes) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, Change),
    get_dict(id, Change, ExpId),
    get_dict(patch, Change, patch(batch_size, 16, 32)),
    prlm_rsi_run(S, Change, Verdict),
    Verdict = verdict{status: accepted,
                      reason: probe_ok_metric_improved,
                      metrics: _{baseline: 16, candidate: C},
                      workspace: Dir},
    C > 16,
    atom_concat(Root, '/', RootSlash),
    atom_concat(RootSlash, ExpId, ExpectedDir),
    Dir == ExpectedDir,
    % the ONLY promotion path bumped the accepted runtime
    accepted_tuning(S, 32),
    % the workspace holds the isolated candidate copy
    directory_file_path(Dir, 'rsi_tuning.pl', CandidateFile),
    exists_file(CandidateFile),
    read_file_to_string(CandidateFile, Content, []),
    once(sub_string(Content, _, _, _, "batch_size(32)")),
    % pre/baseline/candidate metrics + result recorded as experiment facts
    prlm_rsi_facts(S, Facts),
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: pre,
                                   metric: tuning, value: 16}),
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: baseline,
                                   metric: throughput, value: 16}),
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: candidate,
                                   metric: throughput, value: C}),
    fact_of_kind(Facts, experiment_result,
                 experiment_result{id: ExpId, status: accepted}),
    % rollback check does not apply to accepted experiments
    prlm_rsi_rollback_check(S, ExpId, false),
    % canonical events: verification passed + completion, no failure
    event_with(S, verification, experiment, ExpId),
    event_with(S, verification, status, passed),
    event_with(S, completion, experiment, ExpId),
    events_of_kind(S, failure, Fails),
    Fails == [],
    % every mutating/executing phase really went through the gated tool path
    events_of_kind(S, tool_call, Calls),
    map_list_to_pairs(tc_name, Calls, Tagged),
    pairs_keys(Tagged, ToolNames),
    msort(ToolNames, [rsi_benchmark, rsi_patch, rsi_test]),
    sess_destroy(S).

% A second run of the same experiment is refused.
test(run_twice_same_experiment_throws) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, Change),
    prlm_rsi_run(S, Change, _),
    get_dict(id, Change, ExpId),
    throws_prlm(prlm_rsi_run(S, Change, _), type_error,
                chk_finished(ExpId)),
    sess_destroy(S).

chk_finished(ExpId, Info) :-
    get_dict(experiment_finished, Info, ExpId).

% ============================================================
% REJECT path 1: candidate fails the correctness probe
% ============================================================

test(run_rejects_probe_failure_and_runtime_untouched) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_propose_break(S, Change),
    accepted_tuning(S, 16),
    get_dict(id, Change, ExpId),
    get_dict(patch, Change, patch(batch_size, 16, -1984)),
    prlm_rsi_run(S, Change, Verdict),
    Verdict = verdict{status: rejected,
                      reason: probe_failed(not_positive_integer),
                      metrics: _{baseline: 16, candidate: _C},
                      workspace: _Dir},
    % runtime was never touched: rollback guarantee holds
    accepted_tuning(S, 16),
    prlm_rsi_rollback_check(S, ExpId, true),
    prlm_rsi_facts(S, Facts),
    fact_of_kind(Facts, experiment_result,
                 experiment_result{id: ExpId, status: rejected}),
    fact_of_kind(Facts, experiment_failure,
                 experiment_failure{id: ExpId,
                                    reason: probe_failed(not_positive_integer)}),
    % the pre-run snapshot was recorded for the rollback check
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: pre,
                                   metric: tuning, value: 16}),
    % rejection events on canonical types
    event_with(S, verification, experiment, ExpId),
    event_with(S, verification, status, failed),
    event_with(S, failure, experiment, ExpId),
    sess_destroy(S).

% ============================================================
% REJECT path 2: candidate loses the benchmark (high pre-set tuning)
% ============================================================

% The accepted tuning is pre-set absurdly high; the regression proposal then
% passes the probe (8000 > 0) but its throughput loses the benchmark, so the
% experiment is rejected on METRIC grounds. Under the documented formula the
% pure +16 bump from 10000 would still improve, hence the regression driver.
test(run_rejects_metric_failure_and_runtime_untouched) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    set_tuning(S, 10000),
    prlm_rsi_propose_break(S, Change),
    get_dict(id, Change, ExpId),
    get_dict(patch, Change, patch(batch_size, 10000, 8000)),
    prlm_rsi_run(S, Change, Verdict),
    Verdict = verdict{status: rejected,
                      reason: metric_not_improved,
                      metrics: _{baseline: 10000, candidate: C},
                      workspace: _Dir},
    C < 10000,
    abs(C - (1000 / 2001 + 8000)) < 1e-9,
    % runtime unchanged: still the pre-set high value
    accepted_tuning(S, 10000),
    prlm_rsi_rollback_check(S, ExpId, true),
    prlm_rsi_facts(S, Facts),
    fact_of_kind(Facts, experiment_failure,
                 experiment_failure{id: ExpId, reason: metric_not_improved}),
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: pre,
                                   metric: tuning, value: 10000}),
    fact_of_kind(Facts, experiment_metric,
                 experiment_metric{id: ExpId, phase: baseline,
                                   metric: throughput, value: 10000}),
    sess_destroy(S).

% ============================================================
% Authority gate
% ============================================================

% An approve_diff session may propose but cannot run: the first tool call
% (rsi_patch, authority allow_session) is refused by the session authority.
test(run_requires_session_authority) :-
    prlm_session_new([], S),            % default authority: approve_diff
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, Change),
    throws_prlm(prlm_rsi_run(S, Change, _), forbidden, chk_forbidden),
    % runtime untouched by the refused run
    accepted_tuning(S, 16),
    prlm_session_destroy(S).

chk_forbidden(Info) :-
    get_dict(tool, Info, rsi_patch),
    get_dict(authority, Info, allow_session).

% ============================================================
% Facts as queryable knowledge
% ============================================================

test(facts_cover_all_shapes) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_propose_break(S, Change),
    get_dict(id, Change, ExpId),
    prlm_rsi_run(S, Change, _),
    prlm_rsi_facts(S, Facts),
    fact_of_kind(Facts, experiment, experiment{id: ExpId, desc: _}),
    fact_of_kind(Facts, experiment_change, _),
    fact_of_kind(Facts, experiment_metric, _),
    fact_of_kind(Facts, experiment_result, _),
    fact_of_kind(Facts, experiment_failure, _),
    % every metric fact is keyed to the experiment id
    forall(fact_of_kind(Facts, experiment_metric,
                        experiment_metric{id: Id, phase: _,
                                          metric: _, value: _}),
           Id == ExpId),
    sess_destroy(S).

test(rollback_check_false_for_unknown_experiment) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_rollback_check(S, no_such_experiment, false),
    sess_destroy(S).

% ============================================================
% Isolation contract: candidates live under the declared root only
% ============================================================

test(candidate_workspace_is_isolated_per_experiment) :-
    sess_new(S),
    tmp_root(Root),
    prlm_session_put(S, rsi_workspace_root, Root),
    prlm_rsi_observe(S, Obs),
    prlm_rsi_propose(S, Obs, Change),
    prlm_rsi_run(S, Change, Verdict),
    get_dict(workspace, Verdict, Dir),
    sub_atom(Dir, 0, _, _, Root),        % inside the declared root only
    file_directory_name(Dir, Root),      % directly under it, one dir per id
    sess_destroy(S).

:- end_tests(prlm_rsi).
