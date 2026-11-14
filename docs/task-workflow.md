# Native task workflow API

`library(rlm_task_workflow)` is a pure, host-owned run journal. It ports the
project-memory workflow into runtime data without an OpenCode dependency or a
new scheduler. Product hosts own persistence, file confinement and authority.

- `task_workflow_create(Project, Revision, Outcome)` creates bounded state.
- `task_workflow_add(State, task{id:Id,title:Text,dependencies:Ids}, Outcome)`
  appends a pending task; dependencies must already exist, making a DAG.
- `task_workflow_ready(State, Outcome)` returns pending actionable IDs.
- `task_workflow_transition(State, Id, Status, Reason, Outcome)` handles
  pending/active/blocked/cancelled. It cannot claim completion.
- `task_workflow_bind(State, Id, FrozenSpec, Outcome)` binds a canonical Spec.
- `task_workflow_verify(State, Id, Observations, Registry, Outcome, Verification)`
  delegates to `spec_verify/4`. Only a passed report can complete a task.
- `task_workflow_refresh(State, NewRevision, Outcome)` invalidates specs and
  verification, reopening active/completed tasks when project state changes.
- `task_workflow_validate(State, Outcome)` validates restored host state.

All outcomes are `ok(Value)` or `error(task_workflow_error(Reason))`.
The reference is `project_state(Project, Revision)`. Required evidence policies
must require current observed/trusted evidence with that exact reference and a
nonempty required-check set. Spec subject must name the same project. The host
must compute the revision from real source state and obtain observations from
trusted collectors. This API does not turn model-supplied evidence into proof.
Do not expose bind/verify or journal replacement directly to a model as arbitrary
data tools. A loaded checkpoint is trusted host state, not an authenticated proof.

Tasks keep reasons, specs, full verification reports and append-only transitions.
Reopening/rebinding a prerequisite invalidates downstream completion. Limits are
256 tasks, 4096 events, 4096-character titles/reasons; hosts must rotate journals
or explicitly archive when full. There is no automatic deletion or compaction.

Compose with existing `rlm_spec_workflow` for Plan/Execute/Verify and bounded
repair, and existing Project APIs for source identity and generation. This module
only owns TODO dependency/lifecycle state. It does not execute commands, migrate
legacy `.prolog` files, promote knowledge, infer diagnoses or implement a shared
knowledge store. Those remain explicit product adapters/follow-on work.

Tests: `swipl -q -s test/rlm_task_workflow_test.pl -g run_tests -t halt`.
