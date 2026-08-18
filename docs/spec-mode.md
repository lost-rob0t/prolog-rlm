# SPEC mode

SPEC mode is the declarative authoring surface for first-class Specs.

Its job is deliberately narrow:

```text
requirements -> SPEC source -> canonical Spec -> validate -> freeze
```

It does not plan, execute tools, edit state, collect observations, repair a run,
or silently rewrite requirements. A caller may stop after freezing and use
`prolog-rlm` purely as a specification system.

The implementation lives in `prolog/rlm_spec_lang.pl` and compiles into the
canonical `rlm_spec` representation. It does not introduce a second Spec IR.

## Structural vocabulary

The source language is closed. Its structural forms are:

| Form | Meaning |
| --- | --- |
| `spec/1` | root containing the ordered source forms |
| `schema_version/1` | source schema version, default `1` |
| `subject/1` | domain-neutral thing being specified |
| `require/2`, `require/3` | required assertion |
| `optional/2`, `optional/3` | inspectable assertion that does not reject the Spec alone |
| `invariant/1` | declarative invariant data |
| `output_contract/1` | declarative output/result contract |
| `provenance/1` | Spec or requirement provenance |
| `assertion/2`, `assertion/3` | trusted registered assertion kind plus arguments |
| `evidence_policy/1` | requirement option that may narrow evidence requirements |

`require/3` and `optional/3` accept a list containing at most one
`evidence_policy/1` and at most one `provenance/1`.

Requirement IDs are explicit and unique. List position is not requirement
identity.

## Tiny example

```prolog
spec([
    subject(dataset(people)),
    require(
        enough_people,
        assertion(
            record_count,
            _{dataset:people, minimum:3}
        )
    )
]).
```

The grammar does not know what `record_count` means. A trusted assertion
provider owns its argument validator, pure evaluator, optional observation
collector, evidence policy, and stable verifier identity.

## Software/project example

```prolog
spec([
    subject(project(prolog_rlm)),

    require(
        spec_module_exists,
        assertion(
            project_module_exists,
            _{module:rlm_spec}
        )
    ),

    require(
        freeze_api_exists,
        assertion(
            project_symbol_exported,
            _{module:rlm_spec, symbol:spec_freeze/3}
        )
    ),

    invariant(spec_identity_is_immutable),
    output_contract(_{verification:structured})
]).
```

`project_module_exists` and `project_symbol_exported` are examples of assertion
kinds for a future project semantic provider. They are not core grammar forms.
The eventual project parser/indexer should populate canonical project knowledge;
trusted assertion providers then query that knowledge. SPEC itself does not
regex or parse source files.

## Non-software example

```prolog
spec([
    subject(dataset(people)),

    require(
        enough_records,
        assertion(
            record_count,
            _{dataset:people, minimum:100}
        )
    ),

    optional(
        preferred_schema,
        assertion(
            dataset_field_set,
            _{dataset:people, fields:[name, city, age]}
        )
    )
]).
```

The same grammar can describe a project, dataset, service, document, research
question, graph, deployment, or another domain admitted by trusted providers.
Domain neutrality comes from generic structure plus typed semantic providers,
not from throwing every concept into one untyped fact bucket.

## API

Discover the language and registered assertion kinds with:

```prolog
spec_language_catalog(+Registry, -Outcome).
```

The catalog contains the fixed structural symbols and the sanitized assertion
catalog. Assertion entries may include declarative `argument_schema` metadata so
an LLM or host UI can construct valid arguments. The catalog does not expose
validator, evaluator, or observer closures.

Normalize source without validating provider semantics:

```prolog
spec_source_normalize(+Source, -Outcome).
```

Compile directly to a Frozen Spec:

```prolog
spec_source_compile(+Source, +Registry, +FreezeOptions, -Outcome).
```

Compilation composes the existing canonical path:

```text
SPEC source
  -> source normalization/desugaring
  -> rlm_spec normalization
  -> trusted assertion/Spec validation
  -> rlm_spec freeze
  -> Frozen Spec / SpecRef
```

Example:

```prolog
spec_source_compile(
    Source,
    Registry,
    [series(my_task), version(1)],
    ok(FrozenSpec)
).
```

Changing semantic requirements changes the Frozen Spec fingerprint. A changed
requirement is a new Spec version, not a repair mutation.

## Source safety

SPEC source is Prolog-shaped declarative data. It is never consulted or called.
The language accepts a `spec(...)` term directly or parses one term from text,
then validates it through a closed structural grammar.

Executable-shaped forms such as directives, `call/1`, `consult/1`, dynamic
assertion/retraction, process creation, shell execution, module loading, or I/O
operations are rejected when smuggled into authoring data. More importantly,
there is no execution path from source terms to `call/1` in the first place.

Model/project data may select a registered assertion kind. It cannot install a
validator, evaluator, observer, or arbitrary callable.

## Requirements, invariants, and assertions

A requirement is independently verifiable desired state. If an invariant must
be checked against observations, express its checkable part as a normal
requirement backed by a trusted assertion kind.

`invariant/1` itself is declarative data. It never becomes executable merely
because the term resembles Prolog.

Required requirements compile to severity `required`; optional requirements
compile to severity `optional`. They share the same verification machinery.

## Relationship to TaskIR

The dependency direction remains:

```text
SPEC source
    |
    v
Frozen Spec S1
    |
    +--> TaskIR references S1
    +--> Plan binds to S1
    +--> Verify evaluates S1
```

TaskIR may later own execution context, discovery requirements, preferences,
allowed mutations, continuation policy, and model-targeting information. It
must not become a second canonical owner of S1's acceptance requirements.

## Relationship to Verify

SPEC mode ends at desired state. Verification is separate:

```text
Frozen Spec + supplied observations -> Verify
```

Observation collection is also separate. Planning and execution are optional.
Keeping these classes separate is what lets the same Spec survive replanning,
repair, new observations, and future project-KB snapshots without quietly
changing the goalposts.
