# Delegation resume runtime

`rlm_delegation_runtime` is the generic bridge from a compiler-authenticated unresolved prompt binding to one bounded parent continuation step. It composes the existing prompt-command, typed tool, supervised agent, and canonical `rlm_subagent` paths; it is not another agent runtime or scheduler.

## Contract

The public entry point is:

```prolog
delegation_resume(+Records,
                  +Trigger,
                  +Runtime,
                  +Parent,
                  +ChildCapabilities,
                  +Context,
                  +CompletionOptions,
                  +ToolOptions,
                  :ResumeHandler,
                  -Outcome).
```

The trusted host supplies runtime/parent identity, the requested child capability ceiling, completion/tool options, and the continuation closure. The parent capability set is read from authoritative `rlm_agent` state immediately before command dispatch; callers cannot supply a synthetic wider parent capability list. `Records` and `Trigger` are closed prompt-command data. They are resolved through `prompt_command_compile/3`; model/KB data never becomes a callable term.

The canonical flow is:

```text
unresolved trigger
-> prompt_command_compile
-> authoritative parent capability snapshot
-> rlm_subagent_register_command
-> prompt_command_execute
-> canonical subagent_result
-> closed delegation_resume_input
-> exactly one trusted continuation call
```

The temporary `rlm_tool` registry is created and destroyed with `setup_call_cleanup/3`. Command fingerprint authentication, query-only argument projection, capability checks, authority/effect handling, supervised child execution, cancellation, and child completion budgets remain owned by their existing modules.

## Resume semantics

Only a ground canonical `subagent_result{status:completed,...}` may become parent continuation input. The resume input carries the authenticated prompt ID/fingerprint plus the existing child result, evidence, usage, correlation, delegation provenance, and trace.

The trusted continuation is invoked at most once and must return a ground `ok(Value)` or `error(Error)`. A continuation failure, exception, or malformed/non-ground result is an explicit `delegation_runtime_error`; it is never converted to empty success.

Failed, cancelled, timed-out, budget-exhausted, malformed, or otherwise non-completed child results do not invoke the continuation. Missing or ambiguous prompt bindings and capability/authority denial likewise remain structured failures.

## Security and ownership invariants

- Prompt-command activation is not execution authority.
- Parent execution capabilities come from the authoritative runtime parent state, not a caller-supplied capability claim.
- Skill/role metadata cannot widen parent or child capabilities.
- The parent must possess `tool(rlm_subagent)` for the authenticated command to execute.
- Child capabilities remain bounded by `rlm_agent`/`rlm_subagent`; this module does not create a second narrowing policy.
- The continuation closure is trusted host code. It is never selected or constructed from model output, KB text, child evidence, or provider data.
- Child output is observation data, not executable Prolog.
- The continuation consumes the already-returned child envelope; it does not resubmit the child because the parent continues.
- Global recursion, concurrency, token/model/time, cancellation, and effect limits remain authoritative in the composed runtime paths.

## Verification

The deterministic `rlm_prompt_command` suite covers automatic unresolved delegation and one successful parent resume, provenance/capability preservation, authoritative parent capability denial with zero continuation calls, failed child results with zero continuation calls, and missing bindings with no child spawn. Negative contracts assert the expected structured failure while CI remains green.

GitHub Actions remains the canonical full gate, including credential-backed REAL OpenRouter where configured.

Related: issue #172, `prolog/rlm_prompt_command.pl`, `prolog/rlm_subagent.pl`, and `docs/agent-runtime.md`.
