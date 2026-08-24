# Agent Zero adapter

`rlm_agent_zero_adapter` is the public Prolog-owned adaptation boundary for
Agent Zero. The host sends bounded inert declarations; Prolog-RLM owns their
normalization, activation evidence, permanent visibility, context packing,
native-schema projection, rejection reasons, token ledger and fingerprint.

Supported declaration formats are:

- `dox` for repository and project instructions;
- `agent_zero_skill` for Agent Zero skills;
- `agent_zero_tool` for local and MCP tool metadata;
- `agent_zero_context` for other bounded context units.

`permanent:true` explicitly selects an essential unit on every compile. It is
still subject to the provider context budget. A permanent tool that cannot fit
causes a structural budget failure; it is never silently unloaded. Selection
does not grant capability or authority.

Executable tools use a separate path:

```prolog
agent_zero_tool_pack_manifest(Declarations, Category, Outcome),
agent_zero_tool_registry_import(Registry,
                                Declarations,
                                TrustedHostHandler,
                                Outcome).
```

The handler is trusted host code and never appears in model-facing metadata.
Agent Zero's external plugin pack combines these APIs with
`rlm_load_tool_pack_instance/5`, so the production tool implementations remain
Agent Zero-owned while Prolog-RLM enforces schemas, capabilities, authority,
effects, scheduling and traces.

Arbitrary callable values, free values, cycles, unknown formats, invalid
schemas and malformed permanence markers fail closed.
