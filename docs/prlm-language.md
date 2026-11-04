# The Prolog-RLM Language

Prolog-RLM is one self-hosted language in which **logic, knowledge, context,
LLMs, tools, actors, agents, recursion, verification, and learning** are
native semantics — not layers glued around a model. The language's own
runtime is written in SWI-Prolog, and the runtime owns every semantic
decision: what executes, what counts as a step, what a proposal may do, when
a run may claim completion.

This document is the language definition as implemented under `prolog/` and
`lang/`. `docs/org/prlm-language.org` is the design-rationale narrative for
the same decisions; `docs/self-hosting.md` explains the bootstrap stages;
`docs/rsi.md` explains bounded self-improvement.

---

## 1. What Prolog-RLM is

Prolog-RLM is a language whose programs are ordinary Prolog source
(`.prlm` files) executed by the language's *own* Prolog machine (the stage0
kernel), extended with first-class language semantics for:

| Concern | Native semantics | Implementation |
|---|---|---|
| Logic | Prolog clauses, unification, backtracking, cut, arithmetic, modules | `prolog/prlm_kernel.pl` (the language's own machine) |
| Knowledge | dynamic facts, `assertz/retract/clause` inside the engine, provenance | kernel + `prlm_assertz/3` |
| Context | deterministic context compilation over session notes | `prolog/prlm_context.pl` + `lang/prlm_ctx.prlm` |
| LLMs | replaceable *providers* whose output is inert proposal data | `prolog/prlm_providers.pl` |
| Tools | capability-gated tool records, discoverable without a model | `prolog/prlm_tools.pl` |
| Actors / agents | mailboxes, supervision, narrowing, shared budgets | `prolog/prlm_actors.pl` |
| Recursion | symbolic-recursive mode over supervised agents, depth ≤ 500 | `prolog/prlm_rlm.pl` + `prolog/prlm_actors.pl` |
| RLM loop | SPEC → PLAN → EXECUTE → VERIFY → LEARN → CONTINUE | `prolog/prlm_rlm.pl` + `lang/prlm_mode.prlm` + `lang/prlm_plan.prlm` |
| Verification | requirement checks gate `completion`; failure never weakens the spec | `prolog/prlm_rlm.pl` |
| Learning | trust-bounded facts: trusted KB vs untrusted store | `prolog/prlm_learn.pl` (inside the `/learn` command) |
| Self-hosting | stage0 → stage1 → stage2 with an equivalence gate | `prolog/prlm_kernel.pl` + `prolog/prlm_selfhost.pl` |
| Self-improvement | bounded OBSERVE → PROPOSE → … → ACCEPT/REJECT loop | `prolog/prlm_rsi.pl` |
| Interfaces | one normalized event stream; MCP surface generated from the engine | `prolog/prlm_session.pl`, `prolog/prlm_mcp_export.pl` |

The design stance, in three sentences:

1. **A language, not a library.** RLM semantics are the language's
   execution model; a consumer cannot opt out of budgets, authority, or
   verification by calling around them, because there is no "around".
2. **The runtime owns semantics; the model proposes.** Everything an LLM
   produces is inert *data* (a proposal term). Only whitelisted, validated
   proposal shapes ever become actions, and the runtime — never the model —
   decides validity.
3. **Verification gates completion.** A run is not done when a model says
   so; it is done when its own requirement checks pass on its own
   observations.

## 2. The stage0 kernel and the no-escape property

`prolog/prlm_kernel.pl` *is* the stage0 bootstrap: a complete Prolog machine
written in Prolog, with its own term representation, unification,
backtracking, cut, arithmetic, module system, loader, and error model.

### 2.1 `'$v'` representation

Interpreted variables are represented explicitly as the compound term
`'$v'(Name)`. Unification is *functional*: it threads an immutable
substitution environment (a dict `Name -> Term`) from state to state, so
choicepoints share their captured environment and no trail is needed.

### 2.2 Structural no-escape

A program goal containing `'$v'(_)` terms is never a callable SWI goal.
Because every host variable is reified into this inert form at the parse
boundary (`prlm_read_goal/3` — parse only, never executes), the engine is
*structurally incapable* of delegating execution of program code to the
host: there is no `call/1` escape hatch. This is why the property is called
structural: it does not depend on discipline or review, it depends on term
representation.

The single sanctioned crossing point for *trusted host code* is
`prlm_call_first/5`, which converts host variables to engine variables,
runs one solution through the machine, and projects a ground result dict.
Untrusted text can only enter through `prlm_read_goal/3`.

### 2.3 The host primitive whitelist

The kernel declares exactly what host functionality it rests on:

```prolog
prlm_host_primitive(dynamic_state/1).     % dynamic storage of closed engine facts
prlm_host_primitive(dict_ops/1).          % dict get/put for immutable environments
prlm_host_primitive(list_walk/1).         % list construction/deconstruction/length
prlm_host_primitive(atom_number_ops/1).   % atom/number construction, comparison, arithmetic
prlm_host_primitive(structural_ops/1).    % =../2, arg/3, ==/2 on closed terms
prlm_host_primitive(source_reader/1).     % parse of source text into inert terms
prlm_host_primitive(path_file_ops/1).     % path resolution and file existence/read
prlm_host_primitive(sorting/1).           % keysort for clause sequence ordering
```

Everything above this line must be (and in stage1 is) implementable in the
language itself. The self-host gate verifies the builtin surface is exactly
this whitelist. Notably absent: `call/1`, `sort/2`, atom/string
introspection, dicts, `between/3` — which is why `lang/prlm_ctx.prlm` ships
its own stable merge sort and represents text as character-code lists.

### 2.4 Directives and the load hook

The loader handles `module/2`, `use_module/1`, `dynamic/1`,
`discontiguous/1`, `initialization/1`. Any other directive is offered to the
multifile hook `prlm_kernel:prlm_load_directive/3` and is a load error
(`directive_error`) if no hook accepts it — fail closed. The MCP layer uses
exactly this hook to accept `:- mcp_export(Name/Arity).`.

### 2.5 Errors and budgets

All engine errors are `throw(prlm_error(Type, Info))` with `Type` one of
`syntax_error, directive_error, existence_error, type_error,
instantiation_error, budget_exceeded, uncaught_throw, internal_error`.
Every machine step is charged to the engine's step counter; exceeding
`max_steps` raises `budget_exceeded`, which upper layers map onto session
budget semantics. Nothing in the kernel writes to streams; all I/O lives at
the boundaries.

## 3. Sessions: one stream, shared budgets, narrowable authority

`prolog/prlm_session.pl` is the substrate every other layer builds on.

* **One normalized event stream.** Every session produces a monotonic
  sequence (seq 1, 2, 3, …) of closed event dicts
  `event{seq, time, type, session, data}`. UIs (OpenCode, Zara, MCP) all see
  the same typed facts. The only I/O is `prlm_events_jsonl/2`, the export
  boundary.
* **Shared budgets.** Counters for `steps`, `tool_calls`, `depth`, `repairs`
  live on the *session*, not on any caller frame, so nested/recursive work
  draws down one allowance. Defaults: steps 1 000 000, tool_calls 10 000,
  **depth 500**, repairs 3. `prlm_budget_check/3` is fail closed: it emits a
  `budget` event *before* throwing.
* **Authority tiers.** Exactly `approve_diff < allow_once < allow_session <
  dangerous`. Sessions may only *narrow*; `prlm_authority_child/3` derives
  the minimum of parent and request (a child can never widen); `allow_once`
  is a consumable that fails closed once spent.
* **Fail-closed cancellation.** Tokens are fresh atoms; cancellation is
  idempotent and one-directional; `prlm_check_cancelled/1` throws so worker
  loops cannot continue past a cancel.

## 4. Native execution modes and the RLM loop

`prolog/prlm_rlm.pl` implements the per-attempt loop:

```
SPEC → PLAN → EXECUTE → VERIFY → LEARN → CONTINUE
```

* **SPEC.** The spec `spec{id, goal, mode, requirements, max_repairs,
  invariants}` is frozen once per run (also stored under session KVS key
  `rlm_frozen_spec`) and re-emitted identically on every attempt.
* **MODE.** `auto` is resolved by the *in-language* rules
  (`lang/prlm_mode.prlm: select_mode/3`, stage0-surface-only Prolog):
  model-only specs go `direct`; agent needs go `symbolic_recursive`;
  tool needs (or no markers) go `symbolic`. An explicit mode is kept.
* **PLAN.** `lang/prlm_plan.prlm: plan_spec/3` turns the frozen spec into
  steps `[step(n(1), Op), …]`. A local clause in `prlm_rlm_lang` can shadow
  it — which is how plans are specialised *in-language*.
* **EXECUTE.** Steps are a closed op set: `model_call_step/1`,
  `tool_call_step/2`, `ctx_compile_step`, `ctx_op_step/1`,
  `assert_fact_step/2`, `verify_step/1`, `yield_step/1`, `learn_step/1`,
  `spawn_agent_step/1`, `send_message_step/2` (the last two only legal in
  `symbolic_recursive`; violations are `forbidden_in_mode` failures).
  Each op yields an observation `obs(StepId, Op, Status, Value)`.
* **VERIFY.** Requirement checks run host-rule-first, then the in-language
  checker `prlm_rlm_lang:check_requirement/3` over the observations
  (missing checker or `false` fails closed). A failed verification blocks
  `completion`.
* **LEARN.** On pass, a `learning` event with `source: run`; the `/learn`
  command can also distill a run into trust-bounded facts (§8).
* **CONTINUE (repair).** Verification failure *never* weakens the spec; it
  only repairs the **plan**, deterministically:
  `repair(planned_reorder)` if any step errored; else
  `repair(add_model_step)` if no model step ran and the provider is not
  `prolog`; else `repair(retry)`. Attempts are bounded by `max_repairs`
  (default 3); exhaustion emits `failure` and the outcome is `failed`.
  Direct mode never repairs — its single failure is final.

### 4.1 The repair-not-weaken rule

Why frozen specs? Because the cheaper failure mode in agent systems is to
quietly redefine success until the model passes. Prolog-RLM makes that
structurally impossible: the spec is immutable session state; repairs are
plan transforms with three closed shapes; the repair budget is a session
counter visible on the event stream.

### 4.2 The no-model path

The default provider is `prolog`: when the runtime can answer
procedurally (via the `prlm_prolog_provider/4` hook), the language runs
with **no model at all** — deterministic, offline, and cheap. Model calls
enter only where the plan says a `model_call_step` is needed and the
provider can produce one.

## 5. The context compiler

Materialization is host glue (`prlm_context.pl`); the operations are *in the
language* (`lang/prlm_ctx.prlm`, executed by the kernel machine):

* Host side: `prlm_ctx_note/4,5` appends session notes
  `section(Id, Kind, Content, Tokens, Priority, Provenance)` with sequential
  ids (`s1, s2, …`) and kind-defaulted priorities (fact/rule/memory 5,
  tool_result/evidence 7, attempt/artifact 3, child_result 6,
  conversation 4, file/source 2). The host converts atom|string text to
  character-code lists because the kernel deliberately exposes no atom
  introspection.
* In language: `ctx_compile/3` returns
  `compiled(Sections, TotalTokens, Dropped)` ordered deterministically
  (priority DESC, then id ASC) under a token budget; `ctx_op/3` validates and
  dispatches `inspect / search / select / slice / transform / delegate /
  aggregate`.

Every operation is a pure, deterministic Prolog computation: same inputs,
same compiled context, provably, because the machine that runs it is the
kernel's and it charges every step. No LLM is involved anywhere in context
compilation — *why*: an agent's working memory must not be a nondeterminism
source; budgets and provenance must be accountable, and "what did the model
see?" must have one exact answer.

## 6. Tools as capabilities

A tool is a closed record:

```prolog
tool{name, description, args_schema, capability, authority,
     effects, result_schema, handler}
```

* `args_schema: [arg(Name, Type), …]` with types
  `atom|number|integer|string|list|term|dict`; arguments are validated and
  normalized (extra keys rejected) before anything runs.
* `capability: [atom]` — the caller must *hold* these caps; registration
  alone confers nothing. Capability possession is separate from tool
  availability by design: discovering a tool is data, invoking it is
  permission.
* `authority` — one canonical tier; checked via
  `prlm_authority_allows/2` (`allow_once` consumes one use).
* `effects: subset of [read, write, shell, net, process, external]` —
  declared, not inferred.
* `result_schema` — a single declared type; unground results are converted
  to `status: error` (fail closed).
* `handler` — `host(M:Pred)`, `lang(M:N/2)` (runs on the session's engine),
  `mcp(Server, Tool)`, or `actor(ActorId)`.

`prlm_tool_call/5` runs a fixed gate order — cancellation check, lookup,
argument validation, capability gate, authority gate, budget check+charge,
`tool_call` event, handler, `result{status, value, evidence{tool, args,
time, provenance, duration_ms}}`, `observation` event — each step strictly
before the next. Handler exceptions never escape: they become
`result{status: error}` plus a `failure` event. The default starter pack
(`echo, kv_put, kv_get, add, clock, fail_always`) is deterministic, needs no
network, and includes a deliberate always-failing probe for the error path.

*Why this shape:* evidence and provenance on every result is what makes
later verification and RSI benchmarking meaningful; declared effects are
what makes authority review reviewable.

## 7. Actors and agents

`prolog/prlm_actors.pl` makes actors runtime primitives, not a library:
identity, state, mailbox, supervision, lifecycle, capabilities,
cancellation, and child actors are language mechanics. Agents, supervisors,
MCP connections and worker processes are *kinds* of actor, so there is one
runtime to reason about instead of several that drift.

* Mailboxes are FIFO; scheduling is a deterministic round-robin over
  mailboxes — host threads cannot provide these semantics.
* Child authority is the narrowing (`prlm_authority_child/3`) of the
  parent's; child capabilities must be a subset of the parent's; both rules
  fail closed.
* Depth is charged per nesting level against the session's shared depth
  budget (500 by default): supervised recursion is bounded *globally*, not
  per frame.
* Agents are actors whose behavior invokes the `prlm_agent_run_goal/5` hook
  (stage1 replaces it with the RLM loop); results flow back as structured
  `agent_result{status, value, evidence, usage}` — never as prose.

*Why 500 under shared budgets:* deep recursive agents are exactly where
budgets get lost; a per-session depth counter plus shared steps/tool_calls
makes "how much did the recursion cost?" a queryable fact rather than an
audit.

## 8. Learning: trust boundaries

`prolog/prlm_learn.pl` (reached inside the RLM `/learn` command) distills a
run into candidate knowledge, separated by trust:

* **Trusted KB** — facts that passed verification inside the run and come
  with provenance (the run's spec id, attempt, evidence). These may be
  consulted by later planning.
* **Untrusted store** — everything else the run observed (model text,
  unverified heuristics). Available for inspection, never for inference.

*Why the boundary:* a learned "fact" is a model-era shortcut; if it could
silently join the trusted KB, the language would drift into believing its
own outputs. Promotion is explicit and evidenced.

## 9. Verification gates completion

`completion` is an event, and it is only emitted when the VERIFY phase
passed: requirement checks evaluated against the run's observations, with
fail-closed defaults (`never` never passes; a missing in-language checker
fails). This is the language's honesty mechanism — a partial or hopeful run
reports `failed`/`exhausted`, not `completed`.

## 10. The event stream

The canonical event types, emitted by `prlm_event_emit/3` and consumed by
every UI over one stream:

```
session_start, specification, mode_select, plan, model_call, tool_call,
actor_spawn, actor_message, observation, verification, repair, learning,
failure, cancellation, completion, budget, context_compiled
```

Non-canonical types are rejected (`type_error`) — the vocabulary is closed
so downstream consumers can rely on it. `rsi`-specific lifecycle is carried
inside event `data` (`_{kind: rsi, …}`) rather than widening the type set.

## 11. MCP export: the language generates its interface from itself

Convention in `.prlm` source:

```prolog
:- module(my_tools, [double/2, double_schema/1]).
:- mcp_export(double/2).

double(X, Y) :- Y is X * 2.
double_schema(schema([arg(x, integer)])).
```

* The `mcp_export/1` directive is handled through the kernel's
  `prlm_load_directive/3` hook; any other unknown directive still fails the
  load — one hook, fail closed.
* The **`<name>_schema/1` companion** (returning
  `schema([arg(Name, Type), …])`, exactly Arity−1 entries, last argument is
  the result) names and types the tool input. Malformed companions fall
  back to positional `arg1..argN` typed `string`; unknown types are
  sanitized — surface generation can never throw on bad schema.
* `prlm_mcp_surface/2` yields tool descriptors only for declarations whose
  predicate is actually *exported* by its engine module (availability again
  separate from capability); `prlm_mcp_register_tools/3` turns them into
  ordinary gated tools.

*Why generated from the engine:* there is no second place where the tool
catalog lives, so the MCP interface cannot drift from what the language can
actually do.

## 12. RSI fact shapes

`prolog/prlm_rsi.pl` records every experiment as closed facts (surfaced by
`prlm_rsi_facts/2` as dicts):

```
experiment(ExpId, Desc)
experiment_metric(ExpId, Phase, Metric, Value)   % Phase: pre|baseline|candidate
experiment_change(ExpId, Change)
experiment_result(ExpId, accepted|rejected)
experiment_failure(ExpId, Reason)
```

`experiment` is deliberately not a canonical session event type; lifecycle
events are emitted with `_{kind: rsi, …}` data instead. See `docs/rsi.md`
for the loop, the isolated-workspace discipline, promotion and rollback.

## 13. A small example program

The shape of a `.prlm` program is plain Prolog — this is exactly the
program the `stage0` subcommand consults inline and queries:

```prolog
% family.prlm — facts and a recursive definition, nothing host-executed
parent(tom, bob).
parent(tom, liz).
parent(bob, ann).
parent(ann, jim).

ancestor(X, Y) :- parent(X, Y).
ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).
```

```prolog
?- prlm_kernel:prlm_engine_new([], E),
   prlm_kernel:prlm_consult_source(E, user,
     "parent(tom, bob).\nparent(bob, ann).\n\
      ancestor(X, Y) :- parent(X, Y).\n\
      ancestor(X, Y) :- parent(X, Z), ancestor(Z, Y).", '<doc>'),
   prlm_kernel:prlm_query_solutions(E, 'ancestor(tom, Who)', 100, Rows).
Rows = [row{Who:bob}, row{Who:ann}].
```

Solutions are projected, ground, and produced by the language's own
machine — every step charged to the engine's budget.

## 14. CLI reference

The entrypoint is `bin/prlm.pl`. Every subcommand prints exactly one line
of JSON on stdout. All I/O lives in the CLI; the modules write nothing.

```sh
swipl -q -s bin/prlm.pl -- help          # {subcommands: [...], exit_codes}
swipl -q -s bin/prlm.pl -- demo          # deterministic walkthrough; {demo: ok, steps: [...]}
swipl -q -s bin/prlm.pl -- stage0        # kernel machine query;  {stage0: ok, solutions: N}
swipl -q -s bin/prlm.pl -- stage1        # guarded: prlm_selfhost:prlm_stage1_new/1
swipl -q -s bin/prlm.pl -- stage2        # guarded: prlm_selfhost:prlm_stage2_new/1
swipl -q -s bin/prlm.pl -- selfhost      # guarded: prlm_selfhost:prlm_selfhost_gate/1
swipl -q -s bin/prlm.pl -- run --mode <direct|symbolic|symbolic-recursive|auto> --goal "<text>"
swipl -q -s bin/prlm.pl -- mcp           # demo engine surface via :- mcp_export(double/2).
swipl -q -s bin/prlm.pl -- usage         # synthetic events -> prlm_usage ingest+report
swipl -q -s bin/prlm.pl -- rsi --dry     # {"rsi":"dry", ...}; bare `rsi` is a usage error
swipl -q -s bin/prlm.pl -- events        # fresh session, 3 canonical events, their types
```

Guards. `stage1`/`stage2`/`selfhost` require
`prlm_selfhost:prlm_stage1_new/1` / `prlm_stage2_new/1` /
`prlm_selfhost_gate/1`; `run` requires `prlm_rlm` (`prlm_run_spec/3` with
spec `spec{id, goal, mode}` and the goal parsed untrusted via
`prlm_read_goal/3`, falling back to `prlm_mode_command/3` command lines like
`/direct <goal text>`); `mcp` requires `prlm_mcp_export`; `usage` requires
`prlm_usage`; `rsi --dry` requires `prlm_rsi`. Every use is checked with
`current_predicate/2` *before* calling; when a module or its predicate is
absent the subcommand degrades to `{"error":"<name>_module_absent"}` and
exits 3 — the CLI never crashes because an in-progress module is missing.

### Exit-code matrix

| Code | Meaning | Examples |
|---|---|---|
| 0 | success | `demo`, `stage0`, `help`, no args, gate passed |
| 1 | gate / runtime failure | `selfhost` gate report (body carries the report JSON); internal `prlm_error` |
| 2 | usage error | unknown subcommand; `run` without/with bad `--mode`; missing `--goal`; `rsi` without `--dry` |
| 3 | optional module absent | `stage1`/`stage2`/`selfhost` without `prlm_selfhost`; `run` without `prlm_rlm` (`rlm_module_absent`); `mcp`, `usage`, `rsi --dry` analogues |

### Example CLI session

```console
$ swipl -q -s bin/prlm.pl -- demo
{"demo":"ok","kv_roundtrip":"hello-prlm","proposal_op":"verify_step(ancestor_tom_bob)","steps":["session_new","tools_default","provider_register","model_call","validate_proposal","kv_put","kv_get"]}

$ swipl -q -s bin/prlm.pl -- stage0
{"query":"ancestor(tom, Who)","solutions":4,"stage0":"ok"}

$ swipl -q -s bin/prlm.pl -- events
{"events":["specification","tool_call","completion"]}

$ swipl -q -s bin/prlm.pl -- run --mode auto --goal "yield_step(ok)" | python3 -m json.tool
{
    "run": "ok",
    "mode": "auto",
    "goal": "yield_step(ok)",
    "outcome": {
        "status": "failed",
        "result": "prolog_provider_unsupported",
        "verifications": [{"attempt": 1,
                           "status": "fail",
                           "failures": ["prolog_provider_unsupported"]}],
        "usage": {"steps": 1, "model_calls": 1, "tool_calls": 0},
        ...
    }
}

$ swipl -q -s bin/prlm.pl -- selfhost        # if prlm_selfhost is absent
{"error":"selfhost_module_absent"}
$ echo $?
3
```

Note the `run` output: with the default `prolog` provider and no
`prlm_prolog_provider/4` hook clause, the direct path cannot produce a
model call, so the loop *honestly* reports `"status":"failed"` with the
recorded verification failure instead of pretending to complete — the CLI
process still exits 0 because the run itself (spec → … → outcome) finished
deterministically. Registering a provider hook (or a `fake`/`echo`
provider on the session) turns the same command into a completed run.

`demo` is the contract-walk in one line: a fresh `allow_session` session,
the default capability-gated tools, an `echo`-provider model call whose
output is validated through the proposal authority gate (a whitelisted
`verify_step/1` op), and a `kv_put`/`kv_get` roundtrip through the gated
tool path — no network, no model, fully deterministic.
