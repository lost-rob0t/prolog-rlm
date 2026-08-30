# SPEC / VALIDATE / PLAN architecture (rewrite of the PR #290 design)

Status: design record. This document completely replaces the previous
PR #290 refinement, which failed adversarial review with BLOCKER-level schema
contradictions (a second `spec/2` root, two incompatible diff grammars,
undefined argument types such as `change_spec`/`content_ref`/`delete_target`,
and a `signature` field that silently conflated arity) and with a missing
execution dataflow (dependency edges without typed bindings).

This rewrite is grounded in a fresh inventory of merged `main`. Every concept
is classified `IMPLEMENTED` (exists merged), `UNMERGED` (exists on a branch;
adoption is an explicit design decision), or `NEW DESIGN TARGET` (does not
exist anywhere). The executable authority for the normative grammars in this
document is `scripts/design_gate.pl`, which validates the examples in this
document against the real merged parsers rather than copies of them.

Lifecycle:

```text
INTENT
   ↓
SPEC (model may draft; inert data)
   ↓
VALIDATE SPEC (hard gate, trusted assertion registry)
   ↓
FROZEN SPEC (spec_ref{series, version, fingerprint})
   ↓
PLAN (closed op vocabulary + typed dataflow; inert data)
   ↓
PLAN KB (validated, durable, bindings included)
   ↓
EXPERT EXECUTION (bounded local loops; effect boundary for external effects)
   ↓
OBSERVATIONS / STATE (trusted observers, normalized evidence)
   ↓
SPEC VERIFY (pure reconciliation over observations)
   ↓
FINAL (verification_report{status:passed} or rejected)
```

Hard-gate invariants carried forward:

- G1. Plans are seeded only from a frozen spec whose fingerprint re-verifies
  (`spec_fingerprint/2` + `normalize_frozen_spec/2` tamper check).
- G2. SPEC validation is a first-class gate, not a logging step.
- G3. Model-authored SPEC text and model-authored PLAN text are inert data
  until the corresponding validator accepts them. Neither can widen authority,
  invent vocabulary, or bypass the other's gate.
- G4. SPEC-source repair (invalid SPEC) and execution repair (failed
  verification) are distinct loops. SPEC repair edits SPEC source; execution
  repair keeps the same frozen ref and may only change HOW.
- G5. FINAL requires `verification_report{status:passed}` for the bound frozen
  spec. A completed plan with unmet required requirements is not final.

---

## 1. Authority rules (unchanged, restated normatively)

```text
SPEC defines WHAT must become true.
PLAN defines HOW to attempt it.
LLM performs semantic reasoning and generation.
Experts execute bounded domain-specific work.
Prolog owns validation, authority, dependencies, readiness,
capabilities, state, budgets, persistence, acceptance.
Observers collect real evidence.
Verification decides whether the Frozen SPEC is satisfied.
```

- Model output is inert data. SPEC never grants executable authority.
- A requirement involving network, filesystem, process, Git, credentials, or
  any other effect does NOT grant that effect. Only trusted host capability
  configuration grants execution authority (`rlm_tool` capability shapes;
  `rlm_authority` tiers `approve_diff < allow_once < allow_session <
  dangerous`).
- Tool/schema availability is separate from capability possession.
- Expert capability mappings state requirements; they never grant anything.

## 2. Inventory and classification

### 2.1 IMPLEMENTED (merged `main`)

| Substrate | Module | Key contracts |
|---|---|---|
| SPEC authoring language | `prolog/rlm_spec_lang.pl` | root `spec(Forms)`; closed structural forms; desugaring; forbidden-functor blocklist; closed ground data |
| Spec normalize/validate/freeze/publish/resolve | `prolog/rlm_spec.pl` | `frozen_spec{ref:spec_ref{series,version,fingerprint}}`; SHA-256 semantic fingerprint; monotonic publish versions; tamper check |
| Trusted assertion registry | `prolog/rlm_assertion.pl` | `assertion_provider(Kind, SchemaVersion, Validator, Evaluator, Observer, Metadata)`; no public registration path for model data |
| Evidence model | `prolog/rlm_evidence.pl` | `evidence_policy{required_evidence, source_classes, trust_classes, freshness, coherence, state_ref}` with narrowing; `rlm_observation{...}`; statuses incl. `indeterminate/1`; trust classes `trusted/observed/model_claim/derived/unresolved` |
| Pure verification + observation ABI | `prolog/rlm_verify.pl` | `spec_verify/4` (pure), `spec_observe/5`, `spec_observe_async/5`, `spec_observe_execute/5`; verifier/collector identity binding; coherence enforcement |
| Typed plan runtime | `prolog/rlm_plan.pl` | closed AST `context/3, model/4, rlm/2, tool/3, parallel/2, retry/3, checkpoint/1, final/1`; expressions `input/1, var/1, field/2, literal/1, list/1, object/1`; capability subset validation; `plan_budget` |
| Structured outcomes + bounded repair | `prolog/rlm_outcome.pl` | `plan_outcome/5`, `plan_repair/6` |
| Durable graph orchestration | `prolog/rlm_graph.pl`, `prolog/rlm_graph_persist.pl` | declarative node/edge specs; SWI persistency checkpoints + event history; resume |
| Spec workflow composition | `prolog/rlm_spec_workflow.pl` | prepare→execute→observe→verify→repair→finish; `spec_plan_bind/4`; graph id includes frozen fingerprint |
| Recursion/routing policy | `prolog/rlm_recursion_policy.pl` | route `direct_continuation` vs symbolic routes; recursion guard/fingerprints |
| Project/source registry | `prolog/rlm_project_source.pl` | Project/File/Language records; language evidence; parser selection; epistemic identities only |
| Tree-sitter FFI | `prolog/rlm_tree_sitter.pl` | native parse ABI; grammar loading is operator-only |
| Authority tiers | `prolog/rlm_authority.pl` | `approve_diff < allow_once < allow_session < dangerous`; pending approvals; no `yolo` |
| Durable effect boundary | `prolog/rlm_effect*.pl` | normalized fingerprint → admission → `dispatching` → authoritative observation or conservative indeterminate; idempotency keys; no implicit resubmission |
| Capability model | `prolog/rlm_tool.pl` | `capability_shape` incl. `tool(Name), network(Name), filesystem(Name), process(Name), model(Name), mcp(Name)`; narrowing only |
| Durable artifacts | `prolog/rlm_artifact.pl` | content-addressed store used by spec publish/resolve |
| Result acceptance | `prolog/rlm_result_accept.pl` | proof-carrying child acceptance; evidence-bound verifier outcomes |
| Structured outcome vocabulary | `prolog/rlm_outcome.pl` | one serializable outcome surface |

### 2.2 UNMERGED — adoption is an explicit design decision

| Substrate | Branch | Decision |
|---|---|---|
| `prolog/rlm_plan_graph.pl` closed project-op vocabulary, ready-step executor, `symbol_ref`/`source_span` contracts, contract script, tests | `rage/288-spec-plan-graph-executor` | **ADOPT AS BASE** for the PLAN layer (Section 6). The reconciliation implementation slice owns every delta listed in Section 6.4. |
| `prolog/rlm_direct.pl` bounded provider-native direct loop; `prolog/rlm_native_tool.pl`; `rlm_direct_model_step/10` as the `rlm_plan` `model_step_handler` | `docs/spec-seeded-symbolic-plans` (PR #290 branch) | **ADOPT** as the native model-session provider for expert inner loops and direct mode. Merging it is its own slice (S10). |
| `prolog/rlm_plan.pl` native `model_step_handler` hook with `charge_native_model_execution/2` charge-back (merged `rlm_plan` has neither; `git show main:prolog/rlm_plan.pl`) | same branch | **ADOPT via S10** together with `rlm_direct_model_step/10`: the branch-only hook is UNMERGED-adoption surface, not merged-main capability. |
| `prolog/rlm_tool.pl` extra `capability_shape(spec/1)` and `capability_shape(plan/1)` shapes (merged `rlm_tool` has neither) | same branch | **ADOPT via S10** as part of the strategy adoption slice; until merged, capability data using these shapes is validated against this checkout's modules, not merged main. |
| `prolog/rlm_spec_strategy.pl` strategy bind/execute with modes `direct` and `typed_plan` | same branch | **ADOPT** with one normalization boundary (Section 7.1). |

### 2.3 NEW DESIGN TARGETS (exist nowhere today)

intent classification; typed expert dataflow bindings; expert contracts;
`edit_action` schema; iterative coding-expert loop state; assertion-kind packs
for language/symbol/build/test/TDD/HTTP/network; normalized HTTP observation;
`plan_validate_against_spec/4`; plan patches + replan safety; durable plan KB
with bindings; evidence-gated research KB completion; the design gate itself.

## 3. Canonical SPEC language

### 3.1 Decision: the merged grammar IS the grammar

The canonical SPEC source grammar is the merged `rlm_spec_lang` grammar,
unchanged. Root: `spec(Forms)` with `Forms` a list of:

| Form | Arity | Role | Singleton |
|---|---|---|---|
| `schema_version(V)` | 1 | metadata, positive integer | yes (default 1) |
| `subject(S)` | 1 | required, ground closed data | yes (required) |
| `require(Id, Assertion)` / `require(Id, Assertion, Options)` | 2–3 | required requirement | n/a |
| `optional(Id, Assertion)` / `optional(Id, Assertion, Options)` | 2–3 | inspectable requirement | n/a |
| `invariant(D)` | 1 | declarative invariant data (never executed) | no (append) |
| `output_contract(C)` | 1 | declarative output shape | yes |
| `provenance(P)` | 1 | dict provenance | yes (both spec and requirement level) |
| `assertion(Kind, Args)` / `assertion(Kind, Version, Args)` | 2–3 | trusted registered assertion kind + closed ground args | n/a |
| `evidence_policy(P)` | 1 | requirement option (max one per requirement) | yes per requirement |

Merged rules stay in force: unique requirement ids, `subject` required,
requirements non-empty, executable-shaped functors rejected
(`:-`, `call`, `catch`, `assertz`, `open`, `process_create`, `,`, `->`, …),
all data ground and acyclic, assertion kinds must resolve in the host registry
at `spec_validate/3` time, evidence policies narrow (never widen).

Consequences:

- There is **no** `spec(Id, Forms)` root. Spec identity belongs to
  `frozen_spec.ref = spec_ref{series, version, fingerprint}` only.
- There are **no** new top-level structural forms — not `ordering/2`,
  not `forbidden/1`, not `artifact/2`, not `input/2`. Domains are expressed
  as typed trusted assertions (Section 4). Rationale: the merged desugaring,
  fingerprinting, and validation already cover identity, singletons, and
  closed data; new top-level forms would fork the grammar to express what
  assertion argument schemas express more precisely, and would require a
  fingerprint-format migration for zero added authority.
- SPEC-level cross-requirement ordering is deliberately NOT a SPEC concept:
  SPEC states WHAT; PLAN states WHEN (dependencies). Process invariants such
  as RED-before-GREEN are encoded inside the `tdd_evidence` assertion
  contract (Section 9), not in SPEC structure.

### 3.2 Validations environment

Validation remains `spec_source_compile/4` (normalize → validate → freeze).
Environment-awareness lives in the trusted assertion providers: each
provider's `validator/1` checks its argument schema, and each provider's
`evidence_policy/1` metadata states the evidence floor for that kind.
Anything the environment cannot observe is a validation-time diagnostic from
the provider validator (e.g. unknown toolchain kind), not a deferred runtime
surprise.

### 3.3 SPEC input declarations and the input mapping table

SPEC may declare execution inputs *inside assertion argument schemas* as
ground data: an `input_decl{name, type, required}` list plus `input(Name)`
marker terms at value positions. These are inert references that the runtime
must bind; they grant nothing.

The five input layers are distinct and never conflated:

| Layer | Form | Owner | Binding time |
|---|---|---|---|
| SPEC input declaration | `input_decl{name,type,required}` + `input(Name)` markers inside assertion args | frozen spec data | declared at validate |
| runtime PLAN input | graph execution input dict keys | host at `plan_graph_execute/5` | plan start |
| expert input | resolved op args term (expr leaves substituted) | plan-graph executor | step admission |
| HTTP request body | built by the trusted observer from `body_contract` + fixtures/inputs | trusted observer | observation time |
| LLM prompt input | context-compiler projection of expert context | expert context compiler | model session start |

Mapping rules:

1. A SPEC `input(Name)` marker is satisfied iff the runtime PLAN input dict
   has key `Name` (checked by `plan_validate_against_spec/4`, Section 11).
2. Expert input substitution takes precedence over raw inputs; both must be
   closed ground data after substitution.
3. HTTP request bodies are constructed by the observer exclusively from
   `body_contract` + `fixtures` + bound inputs; prompt projections are
   derived views and never authoritative.
4. Model output is never an input layer. It is a bound result value that must
   pass an expert input schema (Section 8.3) before any expert consumes it.

## 4. SPEC domains via trusted assertion kinds

All domain requirements below are `require/2,3` entries whose assertion kind
is registered by a trusted host provider pack. Each kind defines: exact
argument keys and types (validated by `validator/1`), an optional observer
(`Observer` callable with a declared observation capability), and a pure
`evaluator/3` that reconciles `rlm_observation` payloads against the declared
contract. Every argument type referenced below is defined in Section 5.

### 4.1 Project / language requirements

| Kind | Args (exact keys) | Observation |
|---|---|---|
| `file_language` | `path`, `language` | parse result from `rlm_project_source` language evidence + tree-sitter parse status |
| `parses_as` | `path`, `language` | tree-sitter parse with zero error nodes |
| `toolchain_version` | `kind`, `constraint` | toolchain probe observation |
| `project_language` | `language`, `min_files` | per-file language census |

`project must build under SBCL >= N` = `build_ok` (Section 4.3) with
`toolchain{kind:sbcl, version_constraint{min:"N"}}`. `module Y must be
Prolog` = `file_language`. None of these grant read/write authority; their
observers require `filesystem(observation)` at most.

### 4.2 Source / symbol requirements

| Kind | Args | Verifies |
|---|---|---|
| `symbol_exists` | `symbol`, `occurrence?` | named symbol exists (kind-aware) |
| `symbol_kind` | `symbol`, `expected` | symbol has expected kind |
| `symbol_arity` | `symbol`, `arity` | symbol has expected arity (integer concept) |
| `symbol_signature` | `symbol`, `signature` | structured signature matches (distinct from arity) |
| `symbol_owner` | `symbol`, `owner` | symbol belongs to expected owner/scope |
| `symbol_absent` | `symbol` | symbol does not exist |
| `public_api_compatible` | `baseline`, `policy`, `scope?` | public API compatible with baseline revision |
| `symbol_behavior` | `symbol`, `evidence` | required behavior is tested by a trusted test (never a model claim) |

`symbol_exists` / `symbol_kind` / `symbol_owner` / `symbol_arity` /
`public_api_compatible` observers read through the project index (S2,
Section 13) and the source tree. The merged capability model is closed over
`rlm|parallel|retry|checkpoint|tool|context|model|graph|persistence|network|
filesystem|process|mcp` — there is no `project/1` shape — so index-backed
symbol observers require `filesystem(observation)` at most, exactly as
declared in the gate's provider-pack side table
(`observer_required_capabilities/2`), which covers every registry kind,
including `record_count` and `public_api_compatible`. A dedicated
index-observation capability (e.g. `index(observation)`) is a NEW DESIGN
TARGET for S2: it must be added to the merged capability model before any
observer can declare it; until then index reads are `filesystem(observation)`.
`symbol_behavior` composes `behavior_tested` evidence: the referenced test
must exist, pass, and cover the symbol per host static coverage analysis.
No observer capability ever implies project-write authority.

### 4.3 Build requirements

| Kind | Args | Verifies |
|---|---|---|
| `build_ok` | `target`, `toolchain`, `configuration?`, `artifact?`, `warnings?`, `exit_status?` | project/target builds under the declared toolchain with declared constraints |

Semantics: `target = all | target_id`; `exit_status` defaults to 0;
`warnings = any | none | below(N)`; `artifact` asserts identity/type/path of
a produced artifact. The build observer runs the build in an isolated scratch
output directory. It requires `process(observation)` + `filesystem(observation)`
and never modifies project files: **observation capability ≠ project-write
authority.**

### 4.4 Test requirements

| Kind | Args | Verifies |
|---|---|---|
| `test_passes` | `scope = all | suite(A) | test(T)` | suite/test/suite+test passes |
| `test_exists` | `test`, `kind` | a regression/unit/integration/property test exists |
| `behavior_tested` | `symbol`, `test` | the declared behavior of a symbol is exercised by the test (host static coverage) |
| `negative_test_exists` | `test`, `behavior` | an error-path/negative test exists |
| `tdd_evidence` | Section 9 | RED → edit → GREEN evidence pair |

### 4.5 HTTP / networking (first-class)

HTTP requirements are typed assertion contracts, not `network(Host)` flags
and not bare `assertion(http_status, 200)` scalars. See Section 10 for the
full contract, observation, and authority model.

## 5. Canonical reference grammar (one hierarchy)

A named semantic symbol and an arbitrary syntax node are different things.
One normalized reference model serves SPEC assertions, PLAN ops, index
results, and diff endpoints:

```prolog
path_ref      := Atom                    % project-relative, no '..' segments
source_span   := source_span{file:path_ref, start_byte:>=0, end_byte:>=0}
                                        % start_byte =< end_byte
syntax_ref    := syntax_ref{file:path_ref, node_type:atom,
                            start_byte:>=0, end_byte:>=0}
                                        % a source_span + parser node_type
symbol_ref    := symbol_ref{name:atom, kind:symbol_kind,
                            arity?:>=0, owner?:atom,
                            occurrence?:definition|reference|any}
symbol_kind   ∈ {function, method, constructor, predicate, rule, macro,
                 operator, class, field, property, type, module, annotation}
revision_ref  := head | working | committed(Sha) | branch(Name)
               | remote(Name, Branch)
value_type    := any | integer | string | boolean | number | object | array | null
               | registered language type atom
signature     := signature{params:[value_type], returns?:value_type}
```

- `symbol_ref` — *named semantic symbol* resolved through the project index.
  `arity` is the count of parameters/clauses and is the only integer concept;
  `signature` is a structured value used only inside `symbol_signature`
  assertion args. They are never conflated.
- `syntax_ref` — arbitrary parser/AST node: a span plus parser-specific
  `node_type`. Tree-sitter node types are language-adapter metadata beneath
  the normalized contract; they never appear as plan op names or SPEC kinds.
- `source_span` — byte range only.
- Languages without a grammar resolve to `unsupported` (a diagnosable state),
  never a guessed span. The bounded 13-atom `symbol_kind` set avoids a
  universal enumeration; language adapters map their constructs onto it or
  report `unsupported`.

Diff sides (ONE grammar; symbols are not direct diff endpoints — they resolve
first through the index to source snapshots/spans):

```prolog
diff_side  := path(path_ref) | ref(symbol_ref(SymbolRefDict))
            | span(source_span) | revision(revision_ref)
```

The `ref/1` side wraps a `symbol_ref/1` term whose argument is the
`symbol_ref` dict itself (`ref(symbol_ref{...})` in plan data). Plan data is
parsed by the BASE module under a groundness requirement, so every dict in
plan terms must carry a bound tag (`symbol_ref{...}`, `source_span{...}`);
anonymous-tag dicts (`_{...}`) are NOT ground and are rejected by the parser.

`diff(A, B)` resolves both sides through the retrieval engine and returns a
normalized `diff_report{unified, hunks, symbol_changes}`. `path` sides are
resolved in the working tree; `ref`/`span` sides resolve to their containing
file+range at the step's snapshot; `revision` sides resolve to the snapshot of
that revision.

## 6. Canonical PLAN language

### 6.1 Two layers, one authority chain

1. **Execution IR (IMPLEMENTED)**: the merged `rlm_plan` closed AST.
2. **Project plan graph (BASE = rage/288)**: inert step/dependency data that
   desugars mechanically into layer 1. Model output may be Prolog term syntax
   or one JSON object; it is never read as executable Prolog.

### 6.2 BASE grammar (from `rage/288-spec-plan-graph-executor`, ADOPTED)

BASE = branch `rage/288-spec-plan-graph-executor` @ pinned commit
`71a10ae238dd0fa288005bf10892dc8d865ef2f3`. The gate resolves the BASE
through an explicit candidate list (pinned object id, `refs/heads/<branch>`,
`refs/remotes/origin/<branch>`, `refs/remotes/github/<branch>`) — a bare
branch ref does not resolve in canonical CI clones — and asserts the resolved
object equals the pinned id (`base_ref_resolvable` check). CI fetches the
branch non-fatally; the pinned id remains the authority.

```prolog
plan_graph(steps([step(Id, Op, Args, Bind), ...]),
           depends_on([depends_on(StepId, [ReqStepId, ...]), ...]))
```

JSON: `{"steps": [{"id", "op", "args", "bind"}], "depends_on": [{"step", "requires"}]}`.
Ids/binds are atoms and unique. Edges are derived from dependency entries;
ghost/duplicate dependencies rejected; acyclicity via three-color DFS;
`abandoned` is terminal state, never retry authorization; aggregate budget
feeds forward per step via the merged plan budget.

BASE op vocabulary with exact arg wrappers, required capability, effect class
(desugar target `tool(Op, literal(Args), Bind)` per ready step):

| Op | Args | Capability | Effect class |
|---|---|---|---|
| `sync_remote/1` | `sync_remote(op(A))` | `tool(sync_remote)` | external_effect |
| `index/1` | `index(scope(S))`, `S = all \| path(A)` | `tool(index)` | observation |
| `search/2` | `search(pattern(P), scope(S))` | `tool(search)` | observation |
| `locate/1` | `locate(symbol_ref(Ref))` | `tool(locate)` | observation |
| `read/1` | `read(path(A))` *(BASE; generalized by D6-3)* | `tool(read)` | observation |
| `diff/2` | `diff(L, R)`, sides per Section 5 | `tool(diff)` | observation |
| `edit/2` | `edit(target(T), content(C))` *(D6-2)* | `tool(edit)` | external_effect |
| `create/2` | `create(path(A), content(C))` *(D6-2)* | `tool(create)` | external_effect |
| `delete/1` | `delete(path(A))` | `tool(delete)` | external_effect |
| `run/1` | `run(command(argv([atom,...])))` *(D6-4)* | `tool(run)` | external_effect |
| `validate/1` | `validate(spec(fingerprint(A)))` | `tool(validate)` | orchestration |
| `delegate/2` | `delegate(task(A), caps(C))`, caps narrowed ⊆ plan caps | `tool(spawn_agent)` | orchestration |

Every type used above is defined: `A`/`P` atoms; `T ∈ path/1 | ref/1 | span/1`
(edit targets); `C` per D6-2; `Ref` a `symbol_ref` dict; `source_span` per
Section 5; caps are merged `rlm_tool` capability shapes with JSON decoding
restricted to `tool(Name)`. There is no `change_spec`, no `content_ref` as an
undefined atom, no `delete_target` beyond `delete(path(A))`, no `index_scope`
beyond `all | path(A)`, no `agent_spec` beyond `delegate(task(A), caps(C))`.
Two Section 5 features are DELTAS rather than BASE features, and the doc does
not claim them as BASE: `revision/1` diff sides (D6-9 — BASE `side_valid/1`
admits `path|ref|span` only) and the closed 13-atom `symbol_kind` set
(D6-10 — BASE symbol-ref decoding admits any non-empty atom kind). Both are
enforced at the D6 layer and owned by the reconciliation slices.

### 6.3 D6 DELTAS (each owned by the reconciliation slice)

- **D6-1 typed dataflow (`expr/1` leaves).** Any arg leaf position may be
  `expr(E)` where `E` is a term from the merged `rlm_plan` expression
  grammar restricted to the graph level:

  ```prolog
  graph_expr := input(atom) | field(graph_expr, atom)
              | literal(ground) | list([graph_expr]) | object([atom-graph_expr])
  ```

  `var/1` is reserved to the desugared `rlm_plan` layer (`final(var(Bind))`).
  Resolution is admission-time substitution by the plan-graph executor:
  `input(Name)` resolves from the execution input dict, else from the result
  of a *completed* step whose `bind == Name` (dependency closure required);
  `field/2` projects dict results (merged `resolve_expr` semantics). Dangling
  references are validation faults (`dangling_input`), as are references to
  steps outside the step's transitive dependency closure.
- **D6-2 typed write content.** `edit(target(T), content(C))`,
  `create(path(A), content(C))` with `C = literal(Text) | expr(E)` where the
  resolved value must be text or a valid `edit_action` dict (Section 8.3).
  Replaces BASE `replacement(A)` / `literal(L)`.
- **D6-3 read selector.** `read(source(S))` with
  `S = path(path_ref) | span(source_span) | ref(symbol_ref)` (JSON key
  `source` unchanged from BASE).
- **D6-4 structured command.** `run(command(argv([atom,...])))` — argv list,
  no shell strings, no ambient shell.
- **D6-5 obligation linkage.** Third optional graph component
  `plan_graph(steps(...), depends_on(...), obligations(...))` with
  `obligation(step:StepId, satisfies:ReqId)` records (JSON top-level
  `"obligations": [{"step", "satisfies"}]`). This is the ONLY
  plan↔SPEC-requirement linkage mechanism; op arities stay at BASE.
- **D6-6 `rename` is NOT a plan op.** It is an internal write-engine
  primitive: an atomic move executed by the write expert (single effect
  admission). Plan-visible rename would double the effect accounting for one
  logical change; compose it in experts instead.
- **D6-7 `generate` is NOT a plan op.** Model generation is owned by expert
  inner loops (Section 8.2). A plan-visible generate op would split budget
  authority between two schedulers.
- **D6-8 expert contracts + inner capabilities.** Every op maps mechanically
  to an expert (`plan_capability_required/2` from BASE). The expert registry
  supplies `expert_contract{}` records (Section 8.1) whose
  `inner_capabilities` (e.g. `model(P)` for write experts) must be a subset
  of environment-granted capabilities and are validated at preflight.
- **D6-9 revision diff sides.** BASE diff sides are `path|ref|span` only
  (`side_valid/1` in `rlm_plan_graph` has no `revision/1` clause). The D6
  grammar adds `revision(revision_ref)` sides (Section 5); reconciliation
  slice S3 owns revision resolution in the executor. Until S3 lands, a plan
  using revision sides validates at the D6 layer and is rejected by the
  unchanged BASE validator (`diff_revision_side` pins both directions).
- **D6-10 closed `symbol_kind` at reconciliation.** The BASE symbol-ref
  decoder accepts any non-empty atom `kind`; the D6 layer enforces the
  closed 13-atom `symbol_kind` set (Section 5) at graph validation
  (`symbol_kind_closed`), and S1's normalized reference layer carries the
  closed set forward.

### 6.4 Diff endpoint decision

Diff sides are **resolvable source selectors** (Section 5); symbols and syntax
nodes are not direct diff endpoints. `path` selects working-tree files;
`ref`/`span` resolve through the index; `revision` selects a snapshot
(`head`, `working`, `committed/1`, `branch/1`, `remote/2`). One grammar, no
prose wrappers outside it.

## 7. Execution strategies

### 7.1 Mode names — one normalization boundary

The conceptual strategies `direct`, `symbolic`, `recursive_symbolic` map to
runtime atoms through ONE normalization predicate owned by the adopted
`rlm_spec_strategy` slice:

```prolog
strategy_mode(direct, direct).
strategy_mode(symbolic, typed_plan).
strategy_mode(recursive_symbolic, typed_plan).   % + recursion policy routes
```

`typed_plan` is the canonical runtime atom (as in the UNMERGED
`rlm_spec_strategy`); `symbolic` and `recursive_symbolic` are interface
names. Nothing in the runtime claims unimplemented mode atoms: there is no
`symbolic` atom in runtime data, and recursion inside `typed_plan` is
admitted only through `rlm_recursion_policy` routes and guards.

### 7.2 Mode responsibilities

- `direct` — bounded single-session native loop (`rlm_direct/4`, UNMERGED);
  contextual compilation; no durable multi-step state.
- `typed_plan` — `rlm_plan` AST and/or adopted plan graph; durable state;
  capability-scoped experts; spec verification and bounded repair.
- `recursive_symbolic` — typed_plan plus admitted subplans/subagents
  (`rlm/2` steps, `delegate/2`, `rlm_recursion_policy` routes).

### 7.3 Continuous project-state readability across modes (hard requirement)

No mode may one-shot. Execution is a multi-run dialog between the model and
the harness, and in **every** mode the model must be able to read the CURRENT
project state at each exchange:

- `direct` — the native loop re-compiles provider-visible context per turn
  from the live conversation and project inputs (merged contextual
  compilation, bounded `rlm_context` projections); each model iteration sees
  freshly observed state, never a frozen snapshot.
- `typed_plan` — expert loops retrieve via host retrieval experts
  (`locate/search/read`) and the context compiler before each model proposal;
  plan-graph results and observations are bound and fed back into the same
  session, so the next proposal is made against observed changed state.
- `recursive_symbolic` — subplans/subagents receive bounded projections of
  the parent's CURRENT state view (never a stale copy) and return results
  that are re-projected into the parent's next exchange.

Continuity across runs and restarts is provided by the forward-projection
model of Section 12.3: the model-visible boundary message carries the covered
message-id range, and any prior range stays re-readable through bounded
context ops. RED-test obligations: S5 (expert loop observes changed state and
feeds it back before the next proposal), S10 (direct loop re-reads state
across provider turns), S11 (projection cursor + id range survive restart;
the model can still address prior project reads after resume).

## 8. Experts, dataflow, and the iterative coding loop

### 8.1 Expert contract (NEW)

Every expert is a host closure registered against a tool name; the contract
is trusted host data:

```prolog
expert_contract{op:Op/Arity,                       % mechanical mapping from plan_capability_required/2
                capabilities:[capability],          % REQUIRED, must ⊆ environment grants
                inner_capabilities:[capability],    % REQUIRED, expert inner-loop grants
                                                    % (e.g. model(P)); distinct from the
                                                    % op's own required capabilities; must
                                                    % ⊆ environment grants, checked at preflight
                input_schema:args_schema,           % resolved op args term shape
                output_schema:bind_schema,          % bound value shape
                effects:[observation|external_effect|orchestration],
                authority_tier:approve_diff|allow_once|allow_session|dangerous,
                model_policy:none | model_policy{provider:atom,
                                                 max_iterations:positive_integer},
                budget_policy:shared_step_budget,   % closed atom
                completion:[applied_and_observed],  % closed condition atoms
                failure:[blocked | failed]}         % closed condition atoms
```

Expert capability requirements never grant capabilities; the host checks them
against the environment before preflight admits the expert.

### 8.2 Iterative coding expert loop — ownership decision

The owning runtime boundary is the **expert pack executed inside the
desugared `rlm_plan` step**. The plan-graph executor owns macro scheduling
(ready-step admission, dependency state, aggregate budget, cancellation); the
expert owns the bounded local loop:

```text
retrieve current context (host retrieval tools)
→ model proposes next bounded action (native session via model_step_handler)
→ validate action against closed edit_action schema
→ apply/read/tool action (external effects only through the effect boundary)
→ observe changed state
→ feed observation to the same expert session
→ next model action …
→ completed | blocked(structured reason) | failed
```

Mechanically, the expert's inner loop runs as a nested `rlm_plan` execution
(validate + execute ABIs) whose capability set is
`[tool(Op) | expert_contract.inner_capabilities]` and whose steps may include
merged `model/4` steps — the native `model_step_handler` executes
provider-native sessions with charge-back into the shared step budget
(`charge_native_model_execution/2`). Both the handler hook and the charge-back
predicate are UNMERGED (§2.2): they exist on this branch's `rlm_plan.pl` and
are provided by UNMERGED `rlm_direct_model_step/10`; merged `rlm_plan` has
neither. Adoption is S10. Loop state:

| Aspect | Contract |
|---|---|
| loop state | step exec state (vars, model responses, remaining budget) + expert session record |
| bindings | step `bind` value = expert output per `output_schema` |
| budget | shared step budget (steps/model/tool/context/output bytes); no second scheduler |
| model-call limit | native session budget + `model_policy.max_iterations` |
| tool-call limit | step budget `tool_calls` |
| context budget | context compiler projection; bounded packed context |
| effect boundaries | file/process/network effects only via `rlm_effect_*` admission → dispatch → observe-or-indeterminate |
| checkpointing | `expert_checkpoint` events appended to the plan KB at iteration boundaries (bounded closed data) |
| completion | `completed(edit_result)` / `blocked(reason)` / `failed(reason)` |
| restart | resume from last expert checkpoint; admitted external effects are never resubmitted; model sessions may re-run (new linked calls, budget-charged) |

PLAN handles macro work/dependencies; the expert loop handles bounded local
iterative execution. There is exactly one scheduler (`rlm_async`); no
one-thread-per-Future designs are introduced.

### 8.3 `edit_action` — LLM output into the write expert (closed schema)

Model output destined for a write expert is bound as inert data and must pass
the write expert's input schema:

```prolog
edit_action{target: edit_target,                % ref(symbol_ref) | span(source_span)
            operation: replace | insert_before | insert_after | delete_block,
            content: text | none,               % required unless delete_block
            basis: revision_ref | none,         % source state the proposal was computed against
            satisfies: [requirement_id]}        % model_claim until verified by evidence
```

Flow: `locate` binds a `symbol_ref`; `read` binds source; the write expert's
model session produces a candidate `edit_action`; the expert validates it
(target resolvable in the current index, `basis` freshness checked, content
required per operation, `satisfies` ids resolve in the bound spec); only then
does the write engine admit the file mutation through the durable effect
boundary with a normalized fingerprint of
`(target, operation, content, basis)`. A changed payload is a new linked
attempt with fresh authority semantics.

Normative multi-step dataflow (expr leaves in italics resolve at admission):

```prolog
plan_graph(steps([
    step(find_foo, locate,
         locate(symbol_ref(symbol_ref{name:foo, kind:function, arity:2,
                                      occurrence:definition})),
         foo_loc),
    step(read_foo, read,
         read(source(span(expr(field(input(foo_loc), span))))),
         foo_src),
    step(patch_foo, edit,
         edit(target(ref(symbol_ref(symbol_ref{name:foo, kind:function,
                                               arity:2}))),
              content(expr(input(foo_src)))),
         foo_edit),
    step(check_spec, validate,
         validate(spec(fingerprint('spec-sha256-…'))),
         verified)
  ]),
  depends_on([depends_on(read_foo,   [find_foo]),
              depends_on(patch_foo,  [read_foo]),
              depends_on(check_spec, [patch_foo])]),
  obligations([obligation(step:patch_foo, satisfies:foo_behavior_x)]))
```

Here `read_foo` consumes the *exact bound output* of `find_foo`
(`field(input(foo_loc), span)`), and `patch_foo` consumes the bound source
text. The desugared form of each ready step remains the merged
`plan([tool(Op, literal(ResolvedArgs), Bind), final(var(Bind))])`.

## 9. TDD / RED-first evidence (separate from final SPEC)

The final SPEC describes acceptance; RED-first is a process invariant encoded
in one evidence contract:

```prolog
tdd_evidence (assertion kind, schema_version 1)
args: _{requirement: requirement_id,       % same-spec requirement id
        test: test_ref,                    % {suite, id} | path(path_ref)
        pre_revision: revision_ref,        % RED base  (e.g. head before work)
        post_revision: revision_ref}       % GREEN state (e.g. working)
```

Observer contract (requires `process(observation)` + `filesystem(observation)`,
writes only to isolated scratch):

1. Materialize `pre_revision` read-only; run the identified test →
   `red_observation{status, output_ref}`.
2. Materialize `post_revision` read-only; run the same test →
   `green_observation{status, output_ref}`.

The observer reports `status:passed` when COLLECTION completed (both runs
executed); the pure evaluator then reconciles the pair (merged `rlm_verify`
semantics: observation status gates only whether the evaluator runs).
Evaluator: `passed` iff `red.status == failed` **and** `green.status ==
passed` and both observations share the same test identity and fresh state
refs. A test that already passes at `pre_revision` yields
`indeterminate(evidence_not_red)`; missing or partial runs yield
`indeterminate(incomplete_tdd_evidence)`. The pair, not a model statement, is
the acceptance contract. The two revisions are identified by `revision_ref`
values carried in the assertion args; hosts pin the plan-start revision as
`pre_revision` (typically `head`) and the produced state as `post_revision`
(typically `working`). `edit`/`create` steps that implement the requirement
must record obligations (D6-5) so coverage ties the code change to the
evidence; only `edit`/`create` steps can satisfy a `tdd_evidence` obligation,
and the linkage is causal — the establishing step must be transitively
required by a `validate/1` step of the bound spec (Section 11).

## 10. HTTP / network model

### 10.1 `http_endpoint` assertion kind (NEW, schema_version 1)

```prolog
args: _{service: atom,
        request:  http_request_contract,
        responses: [http_response_contract]}        % ≥1, unique scenarios
```

**Request contract** (exact keys; unknown keys rejected by the validator):

```prolog
http_request_contract{method: get|post|put|patch|delete|head|options,
                      path: path_template,          % string with {name} templates
                      path_params: {name: integer|string|uuid|boolean},
                      query: [query_param{name, type, required}],
                      headers: [header_contract{name(lowercase atom),
                                                value?: string,
                                                forbidden?: boolean}],
                      content_type: media_type | none,
                      accept: [media_type],
                      body: body_contract | none,   % absent ⇒ empty body required
                      auth: auth_contract{scheme: bearer|basic|api_key|none,
                                          scope?: atom} | none,
                      inputs: [input_decl{name, type, required}],
                      fixtures: {name: body_value | schema},
                      idempotency: none | required}
```

Request bodies are typed schema references, never opaque strings:
`body_contract{type: json|form|text, schema: schema | schema_ref(Atom),
ref?: input(Name)}`. The closed inline `schema` vocabulary is
`{type: object|array|string|integer|number|boolean|null, properties?, required?,
items?, enum?, minimum?, maximum?, min_length?, max_length?}` or a
`schema_ref(Atom)` naming a host-registered schema.

**Response contract** (one per independently verifiable behavior):

```prolog
http_response_contract{scenario: valid_request | invalid_body | unauthenticated
                                     | forbidden | missing_resource | conflict
                                     | rate_limited | server_error,
                       status: exact(I in 100..599) | class(1xx|2xx|3xx|4xx|5xx),
                       headers: [header_contract],
                       body: body_contract | none,  % none ⇒ empty body required
                       location?: path_template,    % 201/3xx Location
                       cache?: no_store | no_cache | max_age(N),
                       pagination?: {kind: cursor|page_number, fields:[atom]}}
```

Scenario derivability (validated at assertion validate time):
`invalid_body` requires a request body schema; `unauthenticated` requires
`auth ≠ none`; `forbidden` requires `auth.scope`; `conflict` requires
`idempotency:required`; `missing_resource` requires non-empty `path_params`.
A non-derivable scenario is a validator fault. The observer reproduces each
negative scenario mechanically from the declared contract (strip auth, mutate
body to violate the schema, reuse the fixture for `conflict`, …);
`rate_limited`/`server_error` are passive (uninducible ⇒ `indeterminate`,
never silently passed).

Example — one endpoint, four behavioral requirements (201 / 400 / 401 / 409):

```prolog
require(create_user,
    assertion(http_endpoint, _{service:user_api,
        request:_{method:post, path:"/users",
                  content_type:"application/json", accept:["application/json"],
                  auth:_{scheme:bearer}, idempotency:required,
                  body:_{type:json,
                         schema:_{type:object,
                                  properties:_{name:_{type:string},
                                               email:_{type:string}},
                                  required:[name, email]}}},
                  inputs:[input_decl{name:user_payload, type:json, required:true}]},
        responses:[
            _{scenario:valid_request,   status:201,
              headers:[header_contract{name:location, value:"/users/{id}"}],
              body:_{type:json, schema:_{type:object,
                                        properties:_{id:_{type:integer}},
                                        required:[id]}}},
            _{scenario:invalid_body,    status:400,
              body:_{type:json, schema:_{type:object,
                                         properties:_{error:_{type:string}}}}},
            _{scenario:unauthenticated, status:401},
            _{scenario:conflict,        status:409}
        ]}))
```

### 10.2 Network protocol extension points

Additional trusted assertion kinds, each with closed arg schemas and
observers declaring `network(observation)`: `dns_resolves{name, expected?}`,
`tcp_reachable{host, port, timeout_ms}`, `port_listening{host, port,
protocol:tcp|udp}`, `tls_certificate{host, port, identity?, min_protocol?,
valid_window_days?}`, `http_redirect{request, max_hops}`, `websocket_upgrade{
url, subprotocol?}`, `sse_stream{url, min_events?, within_ms}`,
`latency_bound{…, p95_ms}`, `proxy_behavior{…, via}`,
`network_isolated{hosts}` (negative observation: requests must fail). None
are forced onto projects; all share the registry/evidence path of Section 4.

### 10.3 Network authority (closed mapping)

| Concept | Owner |
|---|---|
| network behavior required by SPEC | frozen assertion data only |
| network observation capability | `network(observation)` — required by the observer, declared in the trusted provider-pack side table (`observer_required_capabilities/2`), checked by host, NEVER added by spec compilation (the merged `assertion_provider/6` metadata schema is closed and carries no capability field) |
| network execution capability | `tool(sync_remote)` etc. for plan ops + durable effect admission + `rlm_authority` tier |
| network mutation/effect authority | effect boundary dispatch under an explicit tier; observation capability never implies it |

`SPEC requires HTTPS endpoint to return 200` does NOT imply arbitrary internet
access. Compiling such a spec leaves the host capability set unchanged; if the
observer lacks `network(observation)` the observation is
`indeterminate(policy_denied)`, not a pass and not a retry authorization.

### 10.4 Normalized HTTP observation

The observer returns an `rlm_observation` payload (merged evidence contract)
whose `value` is:

```prolog
http_observation{requirement_id, scenario, service,
                 request{method, resolved_url, resolved_path, query,
                         headers_ref, body_ref | bounded_inline},
                 status, response_headers_ref, body_ref | bounded_inline,
                 body_schema_result: match | mismatch(Detail) | not_checked,
                 redirect_chain:[url],
                 timing{connect_ms, ttfb_ms, total_ms},
                 tls{verified, identity, protocol} | none,
                 state_ref, freshness, provenance, evidence_refs}
```

Body representation: `body_ref` (artifact/evidence ref) preferred; bounded
inline only under a fixed byte cap; oversized ⇒ ref only. The pure evaluator
consumes this payload only. Model prose is never an HTTP observation: payloads
must carry `trust_class:observed` / `source_class:external_observation`; a
`model_claim` payload is rejected by the evaluator.

## 11. PLAN → SPEC compatibility (ONE canonical API)

```prolog
plan_validate_against_spec(+ValidatedPlanGraph, +FrozenSpec,
                           +Environment, -Outcome)
Environment = plan_environment{capabilities:[capability],
                               inputs:dict,
                               expert_registry:[expert_contract]}
```

There is exactly one predicate with this name and arity. Fail-closed checks
(structured `plan_graph_error{kind:spec_compat(...)}`):

1. `foreign_spec_reference` — every `validate/1` step fingerprint equals
   `FrozenSpec.ref.fingerprint`.
2. `dropped_obligation(ReqId)` — every **required** requirement whose
   assertion kind is declared `plan_established` by a trusted host mapping
   (S8's closed `requirement_establishment/2` table; e.g. `tdd_evidence`
   requires a code change; observation-only kinds like `build_ok`,
   `test_passes`, `http_endpoint` require none) must be covered by an
   `obligation(step:S, satisfies:ReqId)` where `S` is an establishing step
   for that kind — for `tdd_evidence` only `edit|create` qualify, since its
   evidence contract is a code change — AND `S` is causally connected to
   the bound spec's verification: a `validate/1` step carrying the frozen
   fingerprint transitively requires `S` in the dependency graph. A
   `validate/1` step VERIFIES the frozen spec; it never ESTABLISHES a
   requirement, so a patch cannot hide a dropped obligation behind a
   validate step, and a disconnected or no-op establishing step does not
   count.
3. `forbidden_effect_in_plan(StepId, Effect)` — step effect classes checked
   against the spec's invariant data; desugared invariants are stored
   UNWRAPPED (`forbidden_effect(Effect)` terms inside `invariants`).
4. `capability_widen(StepId, Cap)` — per-op capability requirements ⊆
   environment capabilities; `delegate/2` narrowing enforced (BASE).
5. `dangling_input(StepId, Name)` — expr `input(Name)` markers resolve from
   environment inputs or dependency-closure step binds (D6-1).
6. `unknown_expert(ToolName)` — expert registry preflight (BASE).
7. spec-declared `input_decl{name, required:true}` values must be present in
   `Environment.inputs` (`missing_spec_input(Name)`). Assertion arguments are
   normalized by the merged `canonical_data` pipeline, which retags every
   dict to `assertion_args`; compatibility checkers therefore match input
   declarations by their normalized key set (`name`/`type`/`required`),
   never by the authoring tag.

### 11.1 Replanning

A plan patch is typed data:

```prolog
plan_patch{op: add | remove | replace, step: Step,
           edges: [depends_on], obligations: [obligation],
           reason: atom, provenance: model_claim}
```

Application re-runs the full chain: parse → plan-graph validation →
`plan_validate_against_spec/4` against the **same** frozen spec. A patch may
change HOW, never WHAT: removing or replacing a step that is the sole
establisher of a required obligation fails with `dropped_obligation`, and
there is no "accepted patch" path around it. If acceptance requirements
change: new SPEC source → validate → freeze **new version** → new plan.
No plan authority weakens the frozen spec; the graph id/resume binding keeps
checkpoints spec-fingerprint-bound (merged `rlm_spec_workflow` rule).

## 12. Durability

### 12.1 Durable PLAN KB

Follows the merged `rlm_graph_persist` pattern (SWI persistency, one
checkpoint per run + append-only ordered events):

```prolog
plan_kb_record(plan_id:atom, spec_fingerprint:atom, snapshot:any).   % replaced per plan
plan_kb_event_record(plan_id:atom, sequence:integer, event:any).     % append-only
```

```prolog
plan_kb_snapshot{spec_ref, graph, statuses, results,
                 bindings,                 % bind-name → value (closed data)
                 expert_checkpoints, budget_remaining, position,
                 repair_count, failure_refs, evidence_refs,
                 effect_attempt_refs,
                 covers:[seq_lo, seq_hi]}  % covered event-sequence range (§12.2)
```

Events: `step_transition`, `expert_checkpoint`, `observation_ref`,
`effect_attempt_ref`, `patch_event{accepted|rejected, patch}`, `repair`.
Persisted bindings mean a restart cannot lose generated content a downstream
write expert needs. Resume rule: the stored `spec_fingerprint` must match the
bound frozen spec; a stale plan KB against a newer spec version is refused,
forcing re-seed. Restart mid-step: expert loops resume from their last
`expert_checkpoint`; effect attempts found in `dispatching` without an
observation stay conservatively `indeterminate` (merged effect rule) and are
never implicitly resubmitted. `abandoned` is terminal.

### 12.2 Forward projection, never compaction

Transcript and event logs are append-only and authoritative; context growth
is handled by advancing a projection cursor, never by rewriting history:

- the durable transcript keeps monotone message sequence ids (merged
  `rlm_conversation_persist` already assigns them), and provider-visible
  context remains a compiled projection of that transcript (removing a
  message from a context pack never removes it from the conversation);
- when the visible window exceeds its bound, the watermark advances and the
  model-visible boundary message becomes a bounded summary carrying the
  covered message-id range (`covers:[seq_lo, seq_hi]`);
- prior ranges remain addressable through bounded context ops
  (peek/search/slice by sequence), so earlier observations, bindings, and
  project reads can be re-read EXACTLY whenever verification, repair, or the
  model needs them — summaries are `derived_claim` over a `trusted_runtime`
  range and are always re-derivable;
- plan-KB snapshots carry the covered event-sequence range with the same
  semantics; snapshots are forward projections, never history rewrites;
- compaction-as-rewrite is therefore forbidden. The merged
  `rlm_conversation_warm` compaction producer is superseded in S11 by the
  forward-projection boundary; this resolves the former open question about
  event compaction policy.

This mechanism is what makes the multi-run model↔harness dialog of
Section 7.3 safe: the model can always read current project state, and can
always recover exact prior state by id range without trusting a lossy
summary.

### 12.3 Long-horizon research/design KB

`research/spec-plan-refinement-kb.pl` is the working control plane for this
design process. Hardened rules (implemented in the same slice as this
document):

- persisted state includes tasks, status, dependencies, evidence refs,
  decisions with validation state, open questions, provenance;
- `kb_task_done/1` requires status `done` **and** completion evidence
  (`kb_evidence/2`) or a validated decision (`kb_decision/4` in state
  `validated`). A bare `status(done)` fact is not authoritative;
- the design gate checks KB consistency (no evidence-free `done`, no
  candidate-only decisions treated as validated, dependency closure sound).

## 13. Implementation dependency DAG

Slices are ordered after the architecture. Each slice carries RED tests →
implementation → GREEN validation. Provided/consumed APIs are matched
mechanically by the design gate (no cycles, no ghosts, no missing provider
edges).

| Slice | Provides | Consumes | Depends on |
|---|---|---|---|
| S0 | plan-graph BASE (`rlm_plan_graph` unmodified) | `rlm_plan`, `rlm_tool`, `rlm_async` | — (merge rage/288) |
| S1 | `rlm_project_reference` (Section 5 grammar normalization/validation) | — | S0 |
| S2 | project index/retrieval engine: symbol extraction, locate/search/read/diff execute ABI + observations | `rlm_project_source`, `rlm_tree_sitter`, `rlm_evidence` | S1 |
| S3 | diff sides incl. `revision/1` resolution | S1, S2 | S2 |
| S4 | write engine: `edit_action` application, effect-boundary integration | `rlm_effect_*`, `rlm_authority`, S1 | S1 |
| S5 | D6 deltas: expr dataflow, content/obligations, expert contracts + inner capabilities | S0, S2, S4 | S4 |
| S6 | assertion provider pack: language/build/test/symbol/TDD | `rlm_assertion`, S1, S2, S3 | S5 |
| S7 | HTTP/network provider pack + normalized observation | `rlm_assertion`, `rlm_evidence` | S5 |
| S8 | `plan_validate_against_spec/4` + patches + replan safety | S0, S5, `rlm_spec` | S6 |
| S9 | durable plan KB (bindings, checkpoints, resume) | S0, S5, `rlm_graph_persist` | S5 |
| S10 | strategy adoption: merge `rlm_direct`/`rlm_spec_strategy`; expert-loop `model_step_handler` wiring | S5, `rlm_plan` native handler | S5 |
| S11 | `rlm_spec_workflow` integration; forward-projection context boundary (id-ranged summaries, superseding `rlm_conversation_warm` compaction); docs, roadmap reconciliation | S6–S10 | S10 |

Networking providers (S7) depend on the assertion/evidence substrate
(IMPLEMENTED), not on project write (S4). Write (S4) depends on normalized
target resolution (S1). Expert dataflow (S5) exists before any expert that
consumes generated outputs (S6/S7 consumers, S10 wiring). Durable execution
(S9) persists bindings before long-horizon resume is claimed (S11).

RED-test highlights per slice: S0 — adopted rage/288 suite; S1 — reference
grammar counterexamples; S2 — symbol resolution unresolved/ambiguous cases;
S4 — duplicate-edit effect admission (externally observable counter);
S5 — two-step bind/consume round trip; S6 — fresh SWI process tdd_evidence
fixture (real failing→passing test, red observation proven externally); S7 —
malformed contract rejections + capability-absent observation refusal; S8 —
obligation-drop rejection; S9 — fresh-process restart with a bound generated
edit; S10 — native session budget charge-back under the step budget.

## 14. Design gate

`scripts/design_gate.pl` (deterministic; no model/API/network calls) replaces
the presence-only #288 contract script. It validates the normative design
through real implementations and currently runs 47 checks in 10 groups:

- **spec_grammar_checks (10)** — the normative SPEC examples (dataset,
  language+symbol+build+test domain, TDD, HTTP endpoint) compile through the
  real `spec_source_compile/4` with a gate host registry implementing the
  Section 4/10 argument schemas; the BLOCKER counterexamples from the failed
  PR #290 design (`spec/2` root, unknown form, wrong form arity, duplicate
  ids, executable-shaped data, unknown assertion kind) are rejected by the
  real merged parser.
- **plan_base_checks (7)** — BASE plan graphs parse and validate through the
  ADOPTED `rlm_plan_graph` module; unknown op, delete-with-four-args,
  malformed symbol ref, capability denial, delegate widening, and JSON
  unknown-capability counterexamples are rejected by its real validator.
- **d6_delta_checks (5)** — the D6 grammar (expr leaves, read selector, edit
  content, obligations) validates through the gate checker; dangling input,
  non-grammar expr (`expr(call(...))`), shell-string command, and ghost
  obligation counterexamples are rejected.
- **dataflow_checks (1)** — the full typed dataflow round trip: the locate
  step executes through the MERGED `rlm_plan` ABI, binds `foo_loc`; the read
  step resolves `field(input(foo_loc), span)` to that exact span, executes,
  binds source text; the resolved edit carries the bound content — proving
  step A output is consumed by step B through the declared grammar.
- **capability_safety_checks (4)** — compiling an HTTP-required spec produces
  an outcome containing no capability-shaped term (closed merged
  `rlm_tool` capability model as oracle) and leaves the environment
  capability set unchanged; a registry provider whose metadata attempts a
  `capability` field is rejected by the real merged `rlm_assertion`
  normalization (with a clean twin proving the attribution); observing
  without `network(observation)` drives the real capability-gated observer
  through `spec_observe_execute/5` and lands as a conservative
  `indeterminate(policy_denied)` evidence payload — never a pass — with
  `spec_verify/4` reporting rejected, and the granted twin proves the
  refusal branch is computed, not pre-set.
- **replan_safety_checks (5)** — `plan_validate_against_spec_gate` accepts
  the obligation-preserving graph; rejects a patch removing the sole
  obligation-establishing step (`dropped_obligation`) even though the
  validate step remains; rejects foreign spec fingerprints, missing required
  SPEC inputs, and steps hitting `forbidden_effect` invariants.
- **tdd_evidence_checks (4)** — the evaluator directly (red-failed +
  green-passed ⇒ passed; red-passed ⇒ `indeterminate(evidence_not_red)`) and
  through the REAL `spec_verify/4` pipeline with registry identity binding
  (passed ⇒ report passed; not-red ⇒ report rejected).
- **http_contract_checks (4)** — status 700, status class 6xx, non-derivable
  conflict (idempotency stripped), and body-without-schema are rejected by
  the designed schema.
- **edit_action_checks (5)** — `edit_action` accepted/rejected cases;
  expert contract accepted; capability widening rejected.
- **durability_checks + kb_dag_checks (3)** — a `plan_kb_snapshot` with a
  bound generated edit survives a real persistency round trip
  (`rlm_graph_persist`); the research KB discipline check (no evidence-free
  done, no ghost deps, no cycles, candidate decisions not counted as
  validated); the S0–S11 slice DAG check (no cycles, no ghosts, S0 root).

CI: the gate runs as a deterministic step in the canonical GitHub Actions
workflow (`ci.yml`, after research-approval validation; no paid model calls).
Engineering notes from building it, now encoded as gate checks: SWI
partial-key dict patterns never unify with full dicts (use `get_dict/3`);
clause-level variable sharing between check goals silently compares one
check's binding against the previous check's (every check goal must be a
self-contained helper predicate); anonymous dict tags (`_{...}`) are fresh
variables, so they are not ground (plan data and evidence payloads must use
bound tags); and outcome-style predicates must be called with a fresh
variable, then matched (direct `error(_)` unification fails against
cut-committed alternatives).

## 15. Open questions

1. Snapshot materialization for `tdd_evidence` pre-revisions on large
   repositories (checkout vs. overlay) — performance envelope to be measured
   in S6.
2. `schema_ref` registry governance for HTTP schemas (who registers, review
   path) — owner decision needed before S7.
3. Bounded inline representation cap for HTTP bodies (default 4096 bytes) —
   confirm with operator input.
4. Whether `public_api_compatible` needs per-language visibility rules beyond
   the 13-atom kind set — revisit after S2 extraction lands.

(The former plan-KB compaction question is resolved by Section 12.2:
forward projection with injected id ranges; compaction-as-rewrite is
forbidden.)
