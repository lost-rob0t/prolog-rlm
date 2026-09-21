# File-local Lisp and Prolog structure

`rlm_source_structure:source_structure(Language, SourceString, Outcome)` is a
bounded, non-evaluating inspection API. Languages are `prolog` and
`common_lisp`. It returns definitions, declarations, syntactic references,
diagnostics, and the SHA-256 of the exact UTF-8 source. Definition spans use
zero-based Unicode character offsets with an exclusive end, **not byte spans**.

Prolog uses SWI `read_term/3` without consulting the source. It reports module
declarations, individual predicate clauses, DCGs (runtime arity includes the
two difference-list arguments), and syntactic calls including module-qualified
control bodies. Directives and quasi-quotation handlers are never executed.
Custom operator, conditional, encoding, and reader-flag directives stop
inspection with `status:incomplete`; a trusted project parser is needed to
interpret their effect. It does not apply term/goal expansion, infer meta-call
targets, perform xref execution, or prove determinism/types.

The Common Lisp fallback reader recognizes lists, strings, line/nested block
comments, quote/backquote/comma forms, function quotes, characters, symbols,
package declarations, and ordinary defun/defmacro/defmethod/defgeneric and
variable definitions. `defpackage` exports and used packages are reported.
It never invokes a Lisp reader or evaluates `#.`. Unsupported dispatch readers
(including feature conditionals) and escaped symbols return incomplete
inspection. A complete parse means supported structural syntax, not successful
Common Lisp compilation. Macro expansion, readtables, inheritance, method
specializers, full lambda-list arities, imported symbol resolution, and calls
inside quoted templates/local binding definitions are not resolved.

Reference resolution is **file-local and syntactic**. Prolog calls can point
to all matching local clauses. Lisp call candidates point to a unique local
function/macro definition, report ambiguity, or remain unresolved. The Lisp
reader cannot distinguish arbitrary macros from function calls. Imports are
not assumed to establish bindings. Prolog reference spans cover the containing
clause; Lisp references cover the candidate call form.

The API accepts at most 65,536 characters and applies an inference bound. It
does no I/O, stores no source, and creates no independent project KB. Existing
Tree-sitter/query/semantic normalization remains canonical for project-wide
observations and provenance. In particular these character spans cannot be
inserted as canonical byte spans. Hosts must still use the source/query/
semantic registry contracts for project freshness and coherent snapshots.

AgentProlog uses this adapter for immediate file inspection and bounded edit
proposals. Compiler and test execution remains a separate host-approved
process effect. A structural observation never certifies a Frozen Spec.
