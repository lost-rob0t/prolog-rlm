# Self-Hosting Prolog-RLM: stage0 → stage1 → stage2

Prolog-RLM claims to be a self-hosted language: its RLM semantics are part
of the language, and its later stages are *written in the language* and
executed by the language. This document explains what that claim means
mechanically, what already lives in the language, and how the repository
fails closed when the claim would be false.

## 1. The three stages

### stage0 — the bootstrap machine

`prolog/prlm_kernel.pl` is a complete Prolog machine implemented in SWI
Prolog: explicit `'$v'(Name)` variable representation, functional
unification over immutable environments, choicepoint stack with Prolog
cut semantics (barrier truncation), if-then-else commits, `catch/3` /
`throw/1` unwinding, findall, negation, arithmetic, a module system, a
source loader with provenance, and a step counter with a `max_steps`
budget.

stage0 is *allowed* to use host primitives — that is what "stage0
bootstrap" means; every self-hosting language starts from a host. The
complete whitelist is declared in `prlm_host_primitive/1`
(`dynamic_state`, `dict_ops`, `list_walk`, `atom_number_ops`,
`structural_ops`, `source_reader`, `path_file_ops`, `sorting`).

### stage1 — the language implementing itself

stage1 is ordinary `.prlm` source under `lang/`, loaded into a kernel
engine via `prlm_consult_source/3,4` and executed *only* by the kernel
machine:

* `lang/prlm_ctx.prlm` — the deterministic context operations
  (`ctx_compile/3`, `inspect/search/select/slice/transform/delegate/
  aggregate`), including its own stable merge sort because the engine has
  no `sort/2`, and character-code-list text because the engine exposes no
  atom/string introspection.
* `lang/prlm_mode.prlm` — `select_mode/3`, the auto-mode resolution rules,
  written in stage0-surface-only Prolog (equality on closed terms and
  if-then-else commits; no cuts, no negation, no list builtins).
* `lang/prlm_plan.prlm` — `plan_spec/3`, plan construction and step
  shapes, deliberately shape-identical to the host dispatcher so plans are
  host/lang comparable.

These files are why the mode rules and plan construction are *language*
semantics: they run on the language's own machine, charged to its own
budgets, with no host `call/1` in sight.

### stage2 — the full RLM loop in-language

stage2 is the target state in which the entire SPEC → PLAN → EXECUTE →
VERIFY → LEARN → CONTINUE loop (and the RSI harness) executes through the
kernel machine, with the host reduced to the whitelisted boundary surface
(session events, provider calls, tool gating). `prolog/prlm_selfhost.pl`
owns the gate that certifies progress toward that state; until it lands, the CLI `stage1`, `stage2` and `selfhost`
subcommands degrade to `{"error":"selfhost_module_absent"}` exit 3
rather than pretending.

## 2. The equivalence gate

`prlm_selfhost:prlm_selfhost_gate/1` verifies the self-hosting claim with
three checks, all of which must hold:

1. **Probe corpus equivalence.** A fixed corpus of programs and goals
   (facts, recursion, arithmetic, cut/if-then-else, catch/throw, findall,
   dynamic DB, module resolution) is executed twice: once through the
   stage0 kernel machine, once through the *stage2* (in-language)
   meta-interpreter (`msolve`). Solutions must agree exactly — same
   substitutions, same order, same failure behavior. Equivalence on a
   corpus, not a proof, is the honest artifact: it is machine-checkable,
   extensible, and every corpus entry is a regression test forever.
2. **Builtin-surface exactness.** The set of builtins the stage1/stage2
   sources actually reference must be exactly the declared
   `prlm_host_primitive/1` whitelist — no more, no fewer. Fewer would mean
   dead declarations; more would mean undeclared host reliance.
3. **Execution provenance.** Stage1/stage2 semantics must have executed
   through the kernel machine (step counters charged, no host evaluation of
   language code) for the gate's own probe runs.

The gate is a predicate `prlm_selfhost_gate(Report)`; the CLI `selfhost`
subcommand prints the report JSON and exits 1 when it does not pass —
failing closed, loudly, with evidence.

## 3. The structural no-escape argument

Why can stage1 code not "cheat" by running on the host?

* Program variables are reified to `'$v'(Name)` at the parse boundary
  (`prlm_read_goal/3`), which only *parses* — it never executes.
* A goal containing `'$v'(_)` terms is not a callable SWI goal. There is
  no `call/1` in the engine's step dispatch: a program goal can only be
  processed by the machine's own `step/4` clauses.
* The engine's builtins are a closed set dispatched by functor
  (`builtin_name/1`); unknown functors resolve as *user predicates* —
  clauses in the engine's own database, again executed by `step/4`.
* The one bridge for trusted host code, `prlm_call_first/5`, converts host
  variables to engine variables and funnels execution through
  `machine_solve/5` — the same machine. Untrusted input has no bridge at
  all.

So "the language executes its own stage1/stage2" is not a convention; it is
a consequence of term representation. Any execution of stage1 semantics
outside the machine would require introducing a `call/1`-shaped escape
hatch, which would change the builtin surface and fail check 2 above.

## 4. The dependency direction

The allowed dependency direction is one-way:

```
lang/*.prlm  ──uses only──▶  whitelisted builtin surface (stage0 machine)
prolog/prlm_*.pl  ──may load/consult──▶  lang/*.prlm  (via prlm_consult*)
lang/*.prlm  ──never calls──▶  prolog/prlm_*.pl, SWI libraries, or the host
```

In practice this is enforced by construction: the engine's module system
(`use_module/1` between *engine* modules) has no notion of "SWI library";
there is no predicate in the machine that could import or call host code.
A stage1 source that tried would simply raise `existence_error` inside the
machine — fail closed at run time, in addition to the gate's static
surface check.

This direction is what makes the equivalence gate meaningful: stage1 code
cannot reach around the machine, so agreement between machine and
meta-interpreter on the probe corpus really does measure *the machine*, not
the discipline of its users.

## 5. How the gate fails closed

Every layer in the self-hosting story fails closed, deliberately:

* **Load time.** Unknown directives are a `directive_error` unless a hook
  explicitly accepts them; `use_module/1` targets that do not resolve are
  `directive_error`; module exports must be `atom/integer` shapes.
* **Run time.** Unknown predicates in engine modules are
  `existence_error`; step exhaustion is `budget_exceeded`; uncaught balls
  escape as `prlm_error(uncaught_throw, …)` instead of vanishing.
* **Gate time.** `prlm_selfhost_gate/1` failing any check yields a report
  with the failing check and evidence; the CLI prints it and exits 1.
* **CLI time.** A missing or half-landed `prlm_selfhost` module never
  produces a false "ok": `stage1`/`stage2`/`selfhost` check
  `current_predicate(prlm_selfhost:…)` before calling and degrade to
  `{"error":"selfhost_module_absent"}` exit 3.

There is no code path in which the repository reports a self-hosting stage
as reached without the gate having said so.

## 6. Where each piece lives

| Piece | Location | Executes on |
|---|---|---|
| The machine | `prolog/prlm_kernel.pl` | host (SWI) — stage0 by definition |
| Context ops | `lang/prlm_ctx.prlm` | kernel machine |
| Mode resolution rules | `lang/prlm_mode.prlm` | kernel machine |
| Plan construction | `lang/prlm_plan.prlm` | kernel machine |
| RLM loop driver | `prolog/prlm_rlm.pl` | host, dispatching language plans/ops |
| Self-host gate | `prolog/prlm_selfhost.pl` | host, probing both machines |
| Bootstrap/CLI | `bin/prlm.pl` | host; loads everything script-relative |

The long-term direction (stage2) moves the loop driver's row down into the
"kernel machine" column, one verified equivalence probe at a time.
