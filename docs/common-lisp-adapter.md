# Common Lisp adapter

The Common Lisp adapter is a process client for the canonical Prolog runtime.
It does not reimplement RLM semantics in Lisp and does not share mutable SWI
state through FFI.

## Boundary

The client starts a long-lived SWI-Prolog child process running
`rlm_common_lisp_bridge`.  The bridge accepts framed requests and only permits
direct calls to predicates that are exported from already-loaded modules named
`rlm` or `rlm_*`.

That gives Common Lisp access to the public RLM surface while preserving module
boundaries.  Conjunctions, module-qualified goals, and arbitrary system
predicates are rejected by the bridge.

Returned Prolog values are represented as opaque `prolog-term` objects.  They
can be passed directly into later calls without lossy JSON conversion.  This is
important for runtime handles such as tool registries, futures, agents, graph
backends, and structured RLM dictionaries.

## Loading

From the repository:

~~~lisp
(require :asdf)
(asdf:load-asd #P"lisp/prolog-rlm-cl.asd")
(asdf:load-system "prolog-rlm-cl")
~~~

Then:

~~~lisp
(prolog-rlm:with-rlm (rlm :root #P"/path/to/prolog-rlm/")
  (prolog-rlm:call-rlm
   rlm
   "rlm_version"
   (list (prolog-rlm:var "Version"))))
~~~

## Symbolic tools

`rlm_symbolic_tool` turns a deliberately closed expression language into
ordinary read-only RLM tools.

The program is data.  It is interpreted by a code-owned Prolog handler and is
never meta-called.

Supported conditions:

- `and`, `or`, `not`
- `eq`, `neq`
- `lt`, `lte`, `gt`, `gte`
- `in`
- `present`

Supported expressions:

- `const`
- `field`
- `path`
- `add`, `sub`, `mul`, `div`
- `min`, `max`

Result templates may contain `expr(Expression)` leaves.

A symbolic tool must have `effect:read`.  Registration rejects any symbolic
program attached to an effectful schema.  Invocation still passes through the
normal `rlm_tool` argument schema, capability check, authority check, timeout,
result schema, and output-size limit.

Example:

~~~lisp
(let* ((registry (prolog-rlm:create-tool-registry rlm))
       (program
         (prolog-rlm:sym-program
          (list
           (prolog-rlm:sym-rule
            (prolog-rlm:sym=
             (prolog-rlm:sym-field :segment)
             (prolog-rlm:sym-const "edu"))
            (prolog-rlm:pdict :discount 0.30d0)))
          (prolog-rlm:pdict :discount 0.0d0))))
  ...)
~~~

The example happens to encode a 30% education discount, but the adapter has no
StarIntel-specific pricing policy baked into it.

## Security notes

`raw-term` is a trusted-host escape hatch.  Do not build raw terms by
concatenating untrusted user or model text.  Prefer `var`, `pdict`,
`pcompound`, and the symbolic constructors, all of which render closed terms.

Symbolic programs cannot name Prolog predicates or grant capabilities.  Tool
visibility remains the prompt compiler's job; tool execution remains the
canonical registry/authority runtime's job.
