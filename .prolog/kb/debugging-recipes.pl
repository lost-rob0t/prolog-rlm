/* Debugging recipes for silent goal failures and persistence defects.
   Verified during the #98 review-fix session (2026-09-11). */

% rlm_async goal failures are silent: async_call_goal does call(Goal, Value);
% a plain failure (no exception) surfaces only as
% error(async_error{kind:goal_failed}) with no stack, and catch/3 inside the
% execute wrapper does not fire because nothing was thrown.
silent_failure_rule(async_goal_failed_has_no_stack,
                    'debug canonical execution by calling the *_execute/5 wrapper DIRECTLY in a fresh swipl, never through the async facade; instrument the internal pipeline with step banners that print which subgoal failed').

% library(persistency) generates, for :- persistent foo(a,b,c):
%   foo/3          - dynamic QUERY predicate (membership test; fails on an
%                    empty database)
%   assert_foo/3   - the durable journaling append (db_assert)
%   retract_foo/3  - the durable retraction
% Using the bare query form as an assert silently fails instead of
% journaling, and fails plain (no exception) inside callers.
silent_failure_rule(persistency_bare_predicate_is_a_query,
                    'journal writes must call assert_<name>/N; the bare persistent predicate is only a query and fails on an empty journal').

% SWI dict unification requires the same key set on both sides: a partial
% pattern like D = tag{one_key:X} never unifies with a multi-key dict.  Use
% get_dict/3, dot access (D.key == V), or a full-key pattern.
dict_rule(subset_dict_pattern_never_unifies).

% Journal rows that store whole publications require deterministic
% observation identities: id = semantic_observation(Extraction, Seq) with Seq
% restarting at 1 per publication.  One extraction always normalizes to the
% same observations (pack replacement and content change force a new
% extraction identity), so re-publication re-journals an identical row and
% snapshot replay (sort/2 duplicate collapse) stays idempotent.  A monotonic
% per-extraction sequence (max+1) instead makes re-publication emit a
% DIFFERENT row that hydration replays as duplicate project_symbol facts.
journal_rule(publication_ids_restart_at_one_per_extraction).

% Test-context traps hit while bisecting the suite:
%   - tmp probe files must use absolute use_module/consult paths; relative
%     paths resolve against the loading file's directory, not the shell CWD.
%   - copy-based probes of test units must hardcode the fixture directory
%     because prolog_load_context(directory) follows the copy.
%   - a fresh-process probe passing does not clear a suite failure: bisect
%     with a copy of the real runner and verify failure reproduction before
%     and after each hypothesis (bogus pipe exit codes once hid a vacuous
%     run).
suite_debug_rule(bisect_with_runner_copies_and_verify_reproduction).
