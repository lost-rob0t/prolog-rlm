{{include original}}

## AgentProlog RAGE communication

Keep reports compact and evidence-driven. State which repository is being changed, selected issue/PR, why the slice is eligible under the feature freeze, exact branch/head, tests/integration evidence, and any upstream/downstream dependency.

For AgentProlog UI work, distinguish canonical runtime state from DSH/TUI projection state. Never report a frontend-only representation as if it proved provider/tool/history/planner/verifier behavior.

Always report the active reasoning strategy as one of `direct`, `symbolic`, `symbolic-recursive`, or `auto -> <selected>` when mode behavior is material. Keep reasoning strategy separate from capability/authority/effect permission.

If the needed change belongs to generic Prolog-RLM runtime semantics, hand it upstream as a focused reusable API hardening issue/fix rather than duplicating private runtime logic downstream.