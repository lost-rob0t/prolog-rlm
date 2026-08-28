# SPEC/PLAN authority architecture (refinement of PR #290)

Status: design record. This document refines, and where stated supersedes, the
sketch in `docs/typed-plans.md` ("Planned direction: SPEC-seeded symbolic
planning"). It defines the concrete schemas, validation gates, and runtime
boundaries for the INTENT → SPEC → PLAN → EXPERT loop before implementation
slices are opened. Evidence base: merged `main` at `a89175b` (PR #286 runtime
consolidation) plus the plan-graph slice on `rage/288-spec-plan-graph-executor`
(closed project vocabulary, dependency-graph executor, `symbolRef`/`sourceSpan`
contract). The working research KB for this refinement is
`research/spec-plan-refinement-kb.pl`.

Design input that is already merged and must not be reinvented:

| Area | Merged evidence | Predicates (selection) |
|---|---|---|
| SPEC authoring language | `prolog/rlm_spec_lang.pl` | `spec_source_normalize/2`, `spec_source_compile/4`, `spec_language_catalog/2` |
| Frozen Spec identity | `prolog/rlm_spec.pl` | `spec_validate/3`, `spec_freeze/3`, `spec_fingerprint/2`, `spec_publish/5`, `spec_resolve/3` |
| Verification | `prolog/rlm_verify.pl` | `spec_verify/4`, `spec_observe_execute/5`, `spec_observe_async/5` |
| Assertion providers | `prolog/rlm_assertion.pl` | `assertion_provider/6` (host), `assertion_validate/3`, `assertion_registry_validate/2` |
| Evidence model | `prolog/rlm_evidence.pl` | `evidence_policy_normalize/2`, `evidence_policy_accepts/3`, `observation_normalize/2` |
| Strategy composition | `prolog/rlm_spec_strategy.pl` | `spec_strategy_bind/5`, `spec_strategy_execute/5`, `spec_strategy_workflow_run/3` (direct/typed_plan + bounded repair) |
| Direct native loop | `prolog/rlm_direct.pl` | `rlm_direct/4`, `rlm_direct_async/4`, `rlm_direct_model_step/10`, native ops `spec_*`/`typed_plan_execute` |
| Typed plan IR | `prolog/rlm_plan.pl` | `plan_parse/2`, `plan_validate/4`, `plan_execute/4`, `plan_run/5`, `default_plan_budget/1` |
| Recursion policy | `prolog/rlm_recursion_policy.pl` | `recursion_route/3`, `recursion_guard/5`, `recursion_signals` dict |
| Context compiler | `prolog/rlm_prompt_compiler.pl`, `rlm_context_budget.pl` | `prompt_compile/4`, `context_pack/4`, `compiled_context{}` |
| Parser substrate | `prolog/rlm_tree_sitter.pl`, `rlm_project_source.pl` | `ts_*` FFI, grammar/file/language registries, `parser_for_file/3` |
| Durable graph state | `prolog/rlm_graph.pl`, `rlm_graph_persist.pl` | `graph_compile/4`, `graph_run/4`, `graph_checkpoint/3`, `graph_resume/6` |
| Project plan vocabulary + ready-state | `prolog/rlm_plan_graph.pl` (rage/288 slice) | `plan_graph_parse/2`, `plan_graph_validate/4`, `plan_graph_ready/3`, `plan_graph_run/5` |

Not yet implemented anywhere (confirmed by survey): intent
parsing/classification, `plan_seed_from_spec/3` derivation, plan-to-spec
compatibility validation, project retrieval/write/validation engines over
normalized references, symbol extraction on top of the tree-sitter FFI
(#96–#99), ready-state derivation in durable form, known-failure knowledge,
and a long-horizon research/design KB. Every "target" below designates one of
these gaps; every "exists" cites the table above.

## 1. Corrected authority flow (primary correction)

The refined flow is:

```text
USER / MODEL SEMANTICS
        |
        v
      INTENT                 (typed features + candidate intents; model
        |                     annotations are model_claim until validated)
        v
       SPEC                   (model may draft; host validates)
        |
        v
   VALIDATE SPEC              (first-class HARD GATE, environment-aware)
        |
        +-- invalid --> structured diagnostics (spec_fault list) / repair
        |               (repair edits the SPEC SOURCE, never a plan)
        v
VALIDATED / FROZEN SPEC          (frozen_spec{ref:spec_ref{series,version,fingerprint}})
        |
        v
   PLAN COMPILER                (plan_seed_from_spec/3, host-deterministic;
        |                        accepts ONLY a fingerprint-checked frozen_spec{})
        v
 INITIAL PLAN KB                 (plan_seed -> plan_graph steps/edges)
        |
        v
EXPERT-DRIVEN EXECUTION          (ready-step loop; bounded model/expert work)
        |
        v
 STATE / EVIDENCE UPDATE         (observations, effects, plan-state transitions)
        |
        v
 SPEC VALIDATION                 (spec_verify/4 over collected observations)
        |
        +-- unmet --> replan (same frozen ref) or continue
        v
      FINAL
```

Hard-gate invariants:

- G1. A PLAN MUST NOT be seeded from anything but a frozen spec whose
  fingerprint re-verifies (`spec_fingerprint/2`, tamper check already in
  `normalize_frozen_spec/2`). Seeding from a parsed-but-unvalidated source,
  from diagnostics, or from a stale artifact is a fault, never a fallback.
- G2. Validation is a first-class gate, not a logging step:
  `spec_source_compile/4` already orders normalize → validate → freeze; the
  refinement makes validation environment-aware (Section 4) and
  diagnostics-complete (all faults collected, not fail-fast).
- G3. Model-authored SPEC text and model-authored PLAN text are both inert
  data until the corresponding validator accepts them. Neither can widen
  authority, invent vocabulary, or bypass the other's gate.
- G4. Repair after failed SPEC validation produces a new SPEC source version;
  repair after failed verification during execution (strategy workflow
  repair node, bounded by `max_repairs`) keeps `spec_ref` unchanged. The two
  repair loops are distinct and must not be conflated.
- G5. FINAL requires a `verification_report{status:passed}` for the bound
  frozen spec; a completed plan with unmet requirements is not final.

## 2. Execution modes (direct mode stays first-class)

Three modes exist; all are first-class and host-selectable:

| Mode | Existing substrate | When |
|---|---|---|
| `direct` | `rlm_direct/4` native loop with contextual compilation | bounded, single-session, conversational or small bounded tasks; no durable multi-step state needed |
| `symbolic` | `spec_strategy` `typed_plan` mode over `rlm_plan` (+ project plan-graph ops) | multi-step, durable state, dependencies, capability-scoped experts, spec verification |
| `recursive_symbolic` | symbolic mode with `rlm/3` subplans + `rlm_recursion_policy` routes (`recursive_rlm`, `delegated_subagent`) | high context pressure / branch diversity with admitted depth budget |

Selection is host policy (Section 17). A caller may always pin the mode
explicitly (`strategy(Mode, Payload)` already accepts this). Nothing in this
design forces ordinary model interaction through planning.

## 3. SPEC grammar (design target D1)

The base language is the merged closed symbol set of `rlm_spec_lang`
(`spec(Forms)`, `schema_version/1`, `subject/1`, `require/2,3`,
`optional/2,3`, `invariant/1`, `output_contract/1`, `provenance/1`,
`assertion/2,3`, `evidence_policy/1` as requirement option) with its
desugaring, closed-data and executable-shape checks. The refinement adds the
minimal delta needed to express WHAT must become true without encoding
strategy:

| New symbol | Shape | Desugars to (normalized spec) | Purpose |
|---|---|---|---|
| `input/2` | `input(Name, InputType)` | new normalized field `inputs:[spec_input{name,type}]` | declares required execution inputs; missing at validate time → `missing_input(Name)` |
| `artifact/2,3` | `artifact(Id, Kind)` or `artifact(Id, Kind, Options)` | new normalized field `artifacts:[spec_artifact{id,kind,options}]` | expected artifact contract; obligations for the plan compiler and validation engine |
| `forbidden/1` | `forbidden(Effect)` | `invariant(forbidden_effect(Effect))` + normalized `forbidden:[Effect]` | forbidden effects; contradicts conflicting requires (Section 5) |
| `ordering/2` | `ordering(ReqA, ReqB)` | new normalized field `relations:[relation{type:ordering, from, to}]` | requirement A must be established before B; feeds plan-seed edges |
| `conflicts/2` | `conflicts(ReqA, ReqB)` | `relations:[relation{type:conflict, from, to}]` | A and B cannot both be required; validate-time contradiction |
| `evidence_policy/1` (spec level) | singleton, like `schema_version/1` | default policy; requirement-level option overrides | spec-wide evidence floor |

Deliberately NOT added (prompt seeds, reconciled to existing forms):
`goal(...)` → `subject/1` is the goal; `validate(...)` → a `require/2,3` with
an assertion whose provider has an observer IS the validation obligation;
`success(...)` → all `required` requirements passed + `output_contract`
satisfaction (this is exactly `spec_verify/4` semantics); `constraint(...)` →
`invariant/1`; `evidence(...)` → `evidence_policy/1`. Two names for one
concept would double the vocabulary for zero authority.

`InputType` and `Kind` are typed atoms from closed domains (Section 4).
Example (target shape, all inert data):

```prolog
spec(
    updateFoo,
    [
        subject(update(symbol(foo))),
        schema_version(1),
        input(base_revision, revision_ref),
        require(remote_synchronized, assertion(remote_state, in_sync(origin))),
        require(project_indexed,     assertion(project_index, current)),
        require(foo_satisfies_x,     assertion(symbol_semantics, satisfies_x(symbol(foo))),
                [evidence_policy(evidence_policy{freshness:current})]),
        ordering(remote_synchronized, foo_satisfies_x),
        invariant(preserve_public_api),
        forbidden(delete(file('src/foo.py'))),
        artifact(test_report, test_report),
        evidence_policy(evidence_policy{source_classes:[trusted_runtime, external_observation]}),
        provenance(_{author:"design", ticket:"290"})
    ]
).
```

## 4. SPEC type system (design target D2)

Three tiers, all checked before freeze:

1. **Structural types** (exists): closed symbol/arity table, singleton rules,
   unique requirement ids, one `subject/1`, desugaring order,
   `safe_source_data/1` + forbidden-functor blocklist, ground `closed_data/1`.
2. **Argument types** (target): per-symbol closed domains. Key domains:
   - `symbol_ref`: `symbolRef{name(A), kind(K), owner(O)?, arity(N)?, signature(S)?}` with `K ∈ {function, predicate, method, class, module, type, variable}` (Section 10);
   - `revision_ref`: Section 11 grammar;
   - `path_ref`: `file(Path)`, `dir(Path)` with path patterns kept as inert atoms (no `open/1`-shaped terms; forbidden-functor blocklist already rejects them);
   - `effect`: closed effect terms `delete(Ref)`, `write(Ref)`, `rename(From,To)`, `run(Command)`, `network(Host)`;
   - `assertion_kind` / `capability` / `artifact_kind` / `input_type`: registered atoms, validated against the assertion registry / environment (below).
3. **Reference types** (target): every id mentioned must resolve. Requirement
   ids in `ordering/2`, `conflicts/2` resolve within the spec; `input` names
   resolve against the validation environment's declared inputs;
   `assertion(Kind, _)` kinds resolve in the host assertion registry;
   capabilities resolve in the environment capability set. Unresolved
   references are diagnostics, not exceptions (Section 5).

The normalized spec gains fields `inputs`, `artifacts`, `relations`,
`forbidden` alongside existing `requirements`, `invariants`,
`output_contract`, `provenance`; the frozen fingerprint covers all of them
(canonicalization already sorts dict pairs).

## 5. validateSpec: the hard gate (design target D3)

Target signature (extends the existing `spec_validate/3`):

```prolog
validateSpec(+Spec, +Environment, -Outcome)
% Outcome = ok(validated_spec{normalized, diagnostics:[]})
%         | error(spec_error{phase:validate, kind:spec_rejected,
%                            diagnostics:[spec_fault(...)], message:"..."})
```

`Environment = spec_validation_environment{capabilities:[...], inputs:[...],
assertion_registry, project_state}` is trusted host data. Validation runs
normalize → structural checks (existing) → type checks → reference checks →
semantic checks, collecting ALL diagnostics (only parse errors abort early):

| Check | Diagnostic (`spec_fault/1` detail) | Status |
|---|---|---|
| schema/arity/parse, single term, closed ground data, executable-shaped data, duplicate ids/singletons, spec-lang cycles | existing `spec_lang_fault(...)` family | exists |
| unknown assertion kind | `unknown_assertion_kind(Kind)` | target |
| missing capability for a requirement's assertion | `missing_capability(Cap)` | target |
| requirement conflicts with `forbidden/1` or another require via `conflicts/2` | `contradiction(Req, Offender)` | target |
| provably unsatisfiable requirement (e.g. assertion requires a mechanism the environment lacks) | `impossible_requirement(Req, Reason)` | target |
| dangling `ordering/2`, `conflicts/2`, `artifact/2,3`, `input/2` references | `unknown_reference(Ref)` | target |
| declared `input/2` absent from environment | `missing_input(Name)` | target |
| `output_contract` violates its typed domain | `invalid_output_contract(Reason)` | target |
| two constraints mutually unsatisfiable | `incompatible_constraints(A, B)` | target |
| forbidden effect equals a required effect | `forbidden_effect_conflict(Effect, Req)` | target |
| cycle among `ordering` relations (ordering cycles are invalid; `dependsOn` plan cycles remain a PLAN concern) | `cycle(ReqIds)` | target |
| no assertion provider supplies a validator/observer for a requirement | `no_validation_mechanism(Req)` | target |

Diagnostics are structured data (`spec_fault(Detail)` inside
`spec_error{...}`, same style as `spec_lang_error{detail:spec_lang_fault(_)}`)
— prose `message` fields are display-only, never authoritative. Repair loop:
model proposes a patched SPEC SOURCE (candidate, `model_claim` provenance) →
`validateSpec` again → host freezes on empty required-diagnostics. A plan may
never be the repair vehicle for an invalid spec (G4).

## 6. Frozen Spec semantics (design target D4)

Frozen identity already exists: `frozen_spec{schema_version, ref:
spec_ref{series, version, fingerprint}, subject, requirements, invariants,
output_contract, provenance}`, publish/resolve with strictly increasing
versions, fingerprint recomputation + tamper fault, changed-requirement = new
version. The refinement adds gate-ordering semantics:

1. Source → normalize → `validateSpec(+Source, +Environment, _)` (zero
   required diagnostics) → `spec_freeze/3` → optional `spec_publish/5`.
2. `plan_seed_from_spec/3` accepts only a value for which
   `spec_fingerprint(Frozen, F)` succeeds and, when the seed is resumed from
   durable state, the persisted fingerprint matches.
3. Execution-time repair (strategy workflow `repair` node) keeps `spec_ref`;
   re-planning (Section 8) targets the same ref; changing acceptance requires
   a new spec version (existing publish discipline).

## 7. SPEC → PLAN compiler (design target D5)

```prolog
plan_seed_from_spec(+FrozenSpec, +PlanningContext, -Outcome)
% PlanningContext = planning_context{capabilities, environment, project_state,
%                                    known_symbols, retrieval_available}
% Outcome = ok(plan_seed{plan_id, spec_ref, steps, edges, obligations,
%                        capabilities, unresolved})
%         | error(plan_graph_error{phase:seed, kind:seed_fault(...), ...})
```

Host-deterministic derivation rules (no model involvement):

- every required requirement with an observing assertion → one `validate`
  obligation step (grouped when the same assertion kind + scope allows it);
- `artifact/2,3` → produce-or-verify obligation steps (verify step references
  the artifact id);
- `ordering(ReqA, ReqB)` → edge from A's establishing steps to B's;
  requirement → step mapping recorded in the seed;
- `forbidden/1` → plan-level constraints carried into
  `plan_validate_against_spec` (Section 9), not steps;
- spec-level + per-requirement evidence policies → obligation step budgets
  (freshness/coherence propagate to observation steps);
- capabilities: intersection of environment-granted capabilities and
  capabilities implied by requirement assertions → seed capability set;
  anything implied but not granted → `unresolved` entry
  (`unresolved_goal{kind:capability, detail}`), never a step;
- inputs declared by the spec and absent from `PlanningContext` →
  `unresolved_goal{kind:input, detail}`.

The seed is a starting symbolic structure, not the whole plan: it feeds
`plan_graph_parse/2` → `plan_graph_validate/4` unchanged, and the live loop
may add/refine steps via validated plan patches. Model-proposed decompositions
are candidates with fresh validation, never direct mutations.

## 8. PLAN grammar (design target D6)

Two layers, one authority chain:

1. **Execution IR** (exists, merged): the `rlm_plan` closed AST
   (`context/3`, `model/4`, `rlm/2`, `tool/3`, `parallel/2`, `retry/3`,
   `checkpoint/1`, `final/1`; expressions `literal/1`, `input/1`, `var/1`,
   `field/2`, `list/1`, `object/1`; `spawn_agent/3` desugars to a
   `tool(spawn_agent, ...)` step). Model output may be plan terms or one JSON
   object; never `read_term` execution.
2. **Project plan vocabulary** (rage/288 slice, inert step data desugaring to
   layer 1): the closed op set with typed arguments:

| Op | Typed args (exact keys) | Capability | Expert intent | Desugars to |
|---|---|---|---|---|
| `sync_remote` | `remote(atom)` | `project(sync)` | source_control | `tool(git_sync, literal(args))` |
| `index` | `scope(index_scope)` | `project(read)` | project_retrieval | `tool(project_index, ...)` |
| `search` | `pattern(atom)`, `scope(index_scope)` | `project(read)` | project_retrieval | `tool(project_search, ...)` |
| `locate` | `symbol(symbol_ref)` | `project(read)` | project_retrieval | `tool(project_locate, ...)` |
| `read` | `source(source_ref)` | `project(read)` | project_retrieval | `tool(project_read, ...)` |
| `diff` | `left(diff_endpoint)`, `right(diff_endpoint)` | `project(read)` | project_retrieval | `tool(project_diff, ...)` |
| `edit` | `target(edit_target)`, `change(change_spec)`, `satisfies(req_id)?` | `project(write)` | project_write | `tool(project_edit, ...)` |
| `create` | `path(path_ref)`, `content(content_ref)` | `project(write)` | project_write | `tool(project_create, ...)` |
| `delete` | `target(delete_target)` | `project(write)` + authority tier | project_write | `tool(project_delete, ...)` |
| `run` | `command(command_spec)` | `project(run)` (host-defined) | project_run | `tool(project_run, ...)` |
| `validate` | `spec(spec_ref)` | `project(validate)` | project_validation | observe + `spec_verify/4` steps |
| `delegate` | `spec(agent_spec)`, `capabilities([cap])` | existing delegation authority | delegation | `spawn_agent/3` |

`source_ref` = `symbolRef/1 | span/1 | path/1 | revision/1`; `edit_target` =
`symbolRef/1 | span/1`; `diff_endpoint` = Section 11 grammar. Plans may be
written in Prolog term syntax or JSON (both already supported by
`plan_graph_parse/2`); conceptual shape:

```prolog
plan([
    sync_remote(origin),
    index(project),
    locate(symbolRef{name(foo), kind(function)}),
    diff(symbol(foo), revision(remote('origin','main'))),
    edit(symbol(foo), change(satisfy(updateFoo)), satisfies(updateFoo)),
    validate(updateFoo)
]).
```

## 9. PLAN schema validation (design target D7)

Base validation exists twice over: `rlm_plan` whole-plan validation (closed
vocabulary, single final, binding discipline, allow-listed selectors,
capability subset, recursive estimate, budget fit) and the plan-graph slice
(structure, duplicates, unknown/ghost dependencies, cycles, vocabulary-before-desugar,
argument shapes, per-op capability, expert registry preflight, aggregate
budget, exact per-op key sets). The refinement adds one deterministic pass:

```prolog
plan_validate_against_spec(+ValidatedGraph, +FrozenSpec, +Environment, -Outcome)
```

Checks (all fail-closed, structured `plan_graph_error{kind:spec_compat(...)}`):

- every `edit/create/delete` step is justified: its `satisfies(req_id)`
  resolves to a required requirement, or it produces a declared artifact;
  otherwise `unjustified_mutation(StepId)`;
- step effects ∩ `forbidden/1` effects → `forbidden_effect_in_plan(StepId, Effect)`;
- `validate` steps reference the bound `spec_ref` (fingerprint match) →
  otherwise `foreign_spec_reference(StepId)`;
- plan capability set ⊆ (spec-implied ∩ host-granted) →
  `capability_widen(StepId, Cap)` (model output cannot widen authority);
- seed obligations coverage: each seed obligation is either still present or
  explicitly resolved by an accepted patch → `dropped_obligation(ReqId)`;
- budget fit under the aggregate plan-graph budget (exists).

Model plan patches are typed data: `plan_patch{op:add|remove|replace,
step:Step, edges:[Edge], reason, provenance:model_claim}`. A patch is applied
only after re-running the full validation chain (plan schema +
`plan_validate_against_spec`). Readiness, ordering, and acceptance never come
from the model.

## 10. Dependency representation (design target D8)

Exists in the plan-graph slice and is the target representation:
`plan_graph{steps:[step{id, op, args, bind?, requires:[ReqId]}], edges:[graph_edge{step, requires}]}`,
edges derived from dependency-merged steps (ghost/duplicate `depends_on`
rejected), acyclicity via three-color DFS, `ready_step/3` deriving runnable
steps (`completed` prerequisites only), terminal `abandoned` on abort, no
silent retry. SPEC `ordering/2` relations map to seed edges; the model can
only propose edges through validated patches. Invariant: **LLM proposes plan
structure; Prolog owns plan state and readiness.**

## 11. Plan-state representation (design target D9)

Durable form follows the `rlm_graph_persist` pattern:

```prolog
plan_kb_record(plan_id:atom, spec_fingerprint:atom, snapshot:any).  % one per plan, replaced
plan_kb_event_record(plan_id:atom, sequence:integer, event:any).    % append-only replay
```

`snapshot` carries steps/edges/status map/result map/aggregate budget.
Resume requires fingerprint match with the bound frozen spec (stale plan KB
against a new spec version is refused, forcing re-seed). Step states:
`pending | running | succeeded | failed | abandoned`; `abandoned` is
terminal; externally effectful steps stay subject to the durable effect
boundary (#53/#79): process restart must not implicitly resubmit an admitted
effect attempt; transport failure remains conservative/indeterminate.

## 12. Normalized references (design target D10)

```prolog
symbolRef(name(Name), kind(Kind), owner(Owner)?, arity(Arity)?, signature(Sig)?)
sourceSpan(file(Path), bytes(Start, End))
sourceSpan(file(Path), bytes(Start, End), point(StartLine:StartCol, EndLine:EndCol))
```

`Kind ∈ {function, predicate, method, class, module, type, variable, rule}`.
Plans reason in `symbolRef` terms; `sourceSpan` and byte offsets are
indexer-internal projection:

```text
language parser/indexer (tree-sitter grammars; prolog = swi_native)
        -> normalized project index (project_kb provenance class)
        -> symbolRef resolution (unresolved | ambiguous | unsupported | ok)
        -> sourceSpan
```

The tree-sitter FFI and grammar/file/language registries already exist; symbol
extraction is the #96–#99 gap. Languages without an available grammar resolve
to `unsupported` (a diagnosable state), never to a guessed span.

## 13. Project retrieval engine + diff semantics (design targets D12/D13)

Module target `rlm_project_index` exposing a trusted execute ABI (canonical
direction `*_execute -> Future -> synchronous await`, per the async invariant):

```prolog
project_index_execute(+Op, +Context, +Options, -Outcome)
% Op in index(scope), locate(symbolRef), search(pattern, scope),
%            read(source_ref), diff(left_endpoint, right_endpoint)
```

Results are normalized dicts with observation provenance
(`rlm_observation{}` shapes reuse the evidence module). Diff endpoints
(language-independent grammar; exact typed set):

```prolog
working_tree | index_stage | commit(Sha) | branch(Name) | remote(Remote, Branch)
artifact(Ref) | symbol_version(symbolRef, N) | span(sourceSpan) | candidate(Id)
```

`diff(A, B)` resolves both endpoints through the index and returns
`diff_report{unified, hunks, symbol_changes:[symbol_change{symbol, before, after, status}]}`.
`diff(symbol(foo), revision(remote('origin','main')))` is the intended
conceptual call. No language-specific syntax ever appears in plan terms.

## 14. Project write engine (design target D14)

Module target `rlm_project_write`:

```prolog
project_write_execute(+Op, +Context, +Options, -Outcome)
% Op in edit(target, change), create(path_ref, content_ref),
%            rename(source_ref, dest_ref), delete(target)
```

Gate order per operation (no step may reorder these):

1. plan-graph validation (op known, args typed, dependency satisfied);
2. capability validation (`project(write)`; `delete` additionally requires
   its authority tier through the existing #53 authority boundary);
3. durable effect attempt admission + dispatch intent (#79 effect boundary —
   file mutations are external effects; retries are new linked attempts);
4. SPEC constraint check: effect ∩ `forbidden/1` → reject before dispatch;
5. adapter boundary → authoritative observation (post-write index refresh,
   evidence refs) or conservative uncertainty.

Writes land in the working tree/index/branch; protected refs (e.g. `main`)
require explicit host authority and are never implied by plan validation.

## 15. Project validation engine (design target D15)

`validate(spec_ref)` steps route through the existing observe + `spec_verify/4`
machinery. Additional assertion kinds become host assertion providers
(`assertion_provider/6` registry; validators/observers are trusted host
closures): `tests_pass`, `build_ok`, `lint_clean`, `schema_valid`,
`static_clean`, `diff_clean`, `artifact_exists(Id)`, `forbidden_absent(Effect)`,
`spec_invariant(Invariant)`. Each returns `rlm_observation{}` evidence;
`evidence_policy_accepts/3` remains the single acceptance authority. PLAN
issues `validate(spec001)`; the engine decides mechanism, order, and evidence.

## 16. Expert mapping + context compiler integration (design targets D16/D17)

Expert selection is data-driven, not a frozen taxonomy:

```prolog
expert_intent(sync_remote, intent(source_control)).
expert_intent(index, intent(project_retrieval)).
expert_intent(locate, intent(project_retrieval)).
expert_intent(read, intent(project_retrieval)).
expert_intent(diff, intent(project_retrieval)).
expert_intent(edit, intent(project_write)).
expert_intent(create, intent(project_write)).
expert_intent(delete, intent(project_write)).
expert_intent(run, intent(project_run)).
expert_intent(validate, intent(project_validation)).
expert_intent(delegate, intent(delegation)).
```

Facts are registered/validated by the host (plan-graph preflight already
verifies the expert registry before first execution). Per ready step the
runtime compiles a bounded bundle with the existing compiler:

```text
ready_step -> expert_intent(Op) -> expert capability set
           -> prompt_compile(Catalog,
                 prompt_input{text: step task + linked observations,
                              selected: expert units},
                 [capabilities(ExpertCaps ∩ PlanCaps ∩ SpecCaps), pack(true)])
           -> compiled_context{tool_schemas, context_units, token_ledger}
           -> native model step (rlm_direct_model_step/10 handler)
           -> observation/effect -> plan-state transition
```

New convention: an "expert unit" is a prompt-compiler catalog unit tagged
with the expert intent; the frozen-spec excerpt relevant to the step
(requirement text, forbidden effects) is compiled as a `derived` trust-class
unit. The model sees only its expert's public API; capability narrowing never
widens across the loop.

## 17. Intent system + strategy selection (design targets D17/D18)

Intent layer (target `rlm_intent`):

```prolog
intent_parse(+Request, +IntentContext, -Outcome)
% Outcome = ok(intent_features{tokens:[...], entities:[entity(Kind, Value, Span)],
%                              numbers, repo_refs, symbol_refs, commands,
%                              confidence, ambiguous:[...]})
%         | error(intent_error{phase, kind:...})
intent_candidates(+Features, +IntentContext, -Candidates)
% Candidates = [candidate_intent{kind, features_used, confidence}]
```

Entity kinds: `number/1`, `repo_ref/1`, `symbol_ref/1`, `path_ref/1`,
`command/1`, `revision_ref/1`, plus word/typed tokens. Token co-occurrence
(`token(review)`, `token(pr)`, `number(286)`) contributes evidence toward
candidate kinds such as `review_pr(286)` but never alone decides it.
Model-produced semantic annotations are candidate facts with `model_claim`
provenance; host validation rules (typed entity resolution — a PR number must
resolve in the repo context, a symbolRef must resolve or be explicitly
allowed as new) decide admission. Multiple intents, confidence, and explicit
ambiguity are first-class outputs; ambiguity requires user/model
disambiguation before SPEC drafting proceeds.

Intent feeds three consumers: SPEC drafting (model proposes spec source;
Section 5 gate applies), strategy selection (below), and plan patches
(Section 9).

Strategy selection (target `strategy_select/3`, extending
`spec_strategy_bind/5` callers):

```prolog
strategy_select(+TaskFeatures, +SelectionContext, -Mode)
% Mode in {direct, symbolic, recursive_symbolic}
```

Deterministic decision table over existing recursion signals
(`task_complexity`, `context_pressure`, `uncertainty`, `branch_diversity`,
budget availability) plus intent-derived features (entity count, command
presence, durable-state requirement, verification requirement):

| Condition (host-evaluated) | Mode |
|---|---|
| explicit caller mode given | that mode |
| bounded single-session task; no durable state; low complexity signals | `direct` |
| multi-step, dependencies, artifacts, spec verification needed | `symbolic` |
| symbolic + high context pressure/diversity + admitted recursion depth | `recursive_symbolic` |

`recursive_symbolic` is not a new runtime: it is symbolic mode whose subplans
use `rlm/3` with `rlm_recursion_policy` route selection
(`recursive_rlm`, `delegated_subagent`) under existing depth/fingerprint/progress
guards. The model may suggest a mode as a candidate; host policy decides.

## 18. λ-RLM / RLM combinator mapping (design target D19)

Mapping onto the plan architecture (no λ-RLM syntax is reproduced):

| λ-RLM concept | Becomes | Evidence/target |
|---|---|---|
| task classification | intent features + strategy table | Section 17 |
| strategy selection | `strategy_select/3` | Section 17 (exists partially: caller-pinned modes) |
| split | `context_partition/4` for context; independent ready steps / `parallel/2` for work | exists (context ops, plan combinator); plan-graph fan-out target |
| map | `context_map/4`; `parallel` subplans | exists |
| filter | allow-listed context reducer `filter(Predicate)` (new closed transform) | target, follows `context_map` admission pattern |
| reduce | `context_reduce/4` | exists |
| recursive solve | `rlm/2` subplan + `recursive_rlm` route | exists (policy + runtime) |
| leaf solve | direct `model/4` step or `tool/3` step via expert | exists |
| recursion thresholds | `recursion_policy{max_recursion_depth, min_progress, cost_weight, ...}` + `recursion_guard/5` fingerprints | exists |
| cost/context bounds | `plan_budget{}` netting + `completion_budget{}` child netting (native session path) | exists |
| termination | spec verification pass (G5) + no-progress guard + budget exhaustion → structured abort | exists (verify, guards, plan-graph abort) |
| when NOT to recurse | `deterministic_context` route preference; low `task_complexity`/`branch_diversity` → stay direct | exists in route ranking; surfaced in strategy table |

Direct mode remains the default when none of the durable-state, dependency,
or verification triggers fire.

## 19. Long-horizon Prolog control (design target D20)

The working instance for this refinement is
`research/spec-plan-refinement-kb.pl`; the generalized schema:

```prolog
kb_task(Id, Kind, Title, Status).        % Status in pending|in_progress|done
kb_depends(Id, DependencyId).
kb_evidence(Id, Reference).              % file:line / artifact ref
kb_decision(Id, DecisionId, Summary, Status).   % candidate | validated
kb_open_question(Id, Question).
kb_blocked_by(Id, Dep, Why).
kb_ready(Id), kb_remaining(Id), kb_dependency_closure(Id, Deps), kb_next(Id).
```

Statuses move via explicit host operations (`kb_mark/2`,
`kb_validate_decision/2`); only `validated` decisions are authoritative
planning knowledge (provenance `project_kb`/`trusted`, not `model_claim`).
The model queries the KB (`kb_next/1`) to pick the next research/design task;
the full task graph is never carried in prompt context. Durable form follows
the plan-KB record pattern (Section 11) with the same fingerprint discipline.

## 20. Failure knowledge (design target D21)

Preserves the PR #290 flow with explicit authority gates:

```text
execution failure -> durable failure artifact (evidence refs, structured cause)
  -> retrieval: symbolic match (known_failure/3) first; embedding similarity as
     candidate evidence only (trust class derived)
  -> candidate constraint (candidate status)
  -> validation against current environment + approval
  -> trusted planning knowledge (validated status)
```

```prolog
known_failure(Property, Context, Reason).
reject(Candidate, Reason) :-
    candidate_property(Candidate, Property),
    candidate_context(Candidate, Context),
    known_failure(Property, Context, Reason).
```

Rejection happens before execution of the candidate step. Similarity alone
never becomes authority (trust-class rule); an embedding hit without a
validated rule is a lead, not a constraint.

## 21. End-state walkthrough (target behavior)

Given the Section 3 example spec: `spec_source_normalize` →
`validateSpec(Source, Env, ok(...))` (all diagnostics empty; capabilities
present; inputs resolved) → `spec_freeze/3` →
`plan_seed_from_spec(Frozen, Ctx, ok(Seed))` with steps
`[sync_remote, index, observe/verify ×3, artifact_verify(test_report)]` and
edges from `ordering/2` → model proposes the Section 8 plan (candidate,
`model_claim`) → `plan_graph_parse` → `plan_graph_validate` →
`plan_validate_against_spec` (mutations justified by `satisfies(updateFoo)`;
no forbidden effects; capabilities unchanged) → ready-step loop with
expert-scoped compilation and native model steps → observations collected →
`spec_verify/4` → `verification_report{status:passed}` → FINAL. Any failed
verification routes to bounded repair with `spec_ref` unchanged; any failed
spec validation routes to spec-source repair before any plan exists.

## 22. Open questions

- Q1: `run/1` command specifications: closed allow-list form vs host-registered
  command kinds (recommend the latter; command text never plan-controlled).
- Q2: `symbol_version/2` retention policy for historical symbol snapshots.
- Q3: grouping granularity for validation obligations (per requirement vs per
  assertion kind) — affects step counts; decide during slice S3 with the
  aggregate budget in hand.
- Q4: intent feature extraction for non-English requests (defer; feature
  schema is language-agnostic).

## 23. Implementation dependency graph (design target D22)

Implementation happens in separately-gated slices; nothing here is merged by
this document:

```text
S1 spec-language delta + environment-aware validateSpec + diagnostics
   (rlm_spec_lang/rlm_spec; gate G2)                     [no deps]
S2 reconcile plan-graph slice onto current main (plan JSON args,
   native session handlers, budget netting)               [no deps]
S3 plan_seed_from_spec + plan-KB persistence/resume       [S1, S2]
S4 plan_validate_against_spec + typed plan patches        [S2, S3]
S5 project index engine: symbol extraction (#96-#99), locate/read/diff
   endpoints + resolution states                          [S2]
S6 project write engine via durable effect boundary       [S5]
S7 validation engine assertion kinds (tests/build/lint/...) [S5]
S8 expert mapping catalog + expert-scoped context compilation [S3, S5, S6]
S9 intent system + strategy_select mode chooser           [S8]
S10 long-horizon KB + failure-knowledge durable flows     [S3]
```

Each slice lands with TDD tests, deterministic-suite greenness, and doc
updates per repository discipline; slices touching external effects require
the effect-boundary conformance checks.
