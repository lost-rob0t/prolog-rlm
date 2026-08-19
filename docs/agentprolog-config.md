# AgentProlog configuration

AgentProlog has one configuration runtime and two front doors:

- executable Prolog in `config.prolog`;
- JSON consumed by the Prolog configuration runtime.

Prolog is primary. The intended experience is closer to an Emacs init file than a static preferences document: trusted configuration can define predicates, helper code, rules, imports, and later hook/tool/detector registrations.

## User configuration

The default path is:

```text
$XDG_CONFIG_HOME/prolog-rlm/agentProlog/config.prolog
```

When `XDG_CONFIG_HOME` is unset, AgentProlog falls back to `$HOME/.config`. If `config.prolog` is absent, discovery may load `config.json` from the same directory. If both exist, Prolog wins and the JSON path is retained as shadowed provenance.

The XDG `config.prolog` is **trusted executable operator code**. AgentProlog loads it as Prolog. It therefore has the privileges of the AgentProlog process, exactly as an Emacs init file has the privileges of Emacs. Do not put code in it that you do not trust.

The default ordinary runtime settings are lossless conversation history, no compaction, persistent sessions, and OpenRouter using `openrouter/free`. Direct DeepSeek routing is not required by AgentProlog configuration.

## Programmable Prolog configuration

A simple config can expose ordinary settings as facts:

```prolog
setting(provider, openrouter).
setting(model, "openrouter/free").
setting(persist_sessions, true).
```

They may also be ordinary rules:

```prolog
preferred_model("openrouter/free").

setting(model, Model) :-
    preferred_model(Model).
```

Normal Prolog features are available because this is executable configuration:

```prolog
:- use_module(library(lists)).
:- initialization(format(user_error, 'AgentProlog config loaded~n', [])).

my_prompt_budget(300000).

section(prompt, _{max_tokens: Tokens}) :-
    my_prompt_budget(Tokens).
```

A larger ordinary-settings projection can be supplied with `config/1`:

```prolog
config(_{
    settings: _{
        provider: openrouter,
        model: "openrouter/free"
    },
    frontend: _{
        theme: "dark"
    }
}).
```

The canonical projected sections used by the first schema are `settings`, `extensions`, `tools`, `detectors`, `prompt`, and `frontend`. The executable module can contain additional predicates freely. Later hook/tool/detector registries use those predicates directly rather than forcing executable customization back into JSON-shaped data.

### Loading JSON from Prolog

The runtime recognizes `json/1` and `include_json/1` from `config.prolog`:

```prolog
json("shared.json").

preferred_model("openrouter/auto").
setting(model, Model) :- preferred_model(Model).
```

JSON is applied before `config/1`, `section/2`, and `setting/2`, so explicit Prolog configuration can override imported data.

Because executable `config.prolog` is trusted host code, JSON includes are not treated as a sandbox boundary. A config may refer to files the AgentProlog process can read. The trust boundary is whether the executable config itself was trusted, not an artificial path prison around trusted code.

## JSON-only configuration

A user who does not want executable Prolog can use `config.json`:

```json
{
  "schema_version": 1,
  "settings": {
    "provider": "openrouter",
    "model": "openrouter/free"
  },
  "frontend": {
    "theme": "dark"
  }
}
```

An ordinary-settings shorthand is also accepted:

```json
{
  "provider": "openrouter",
  "model": "openrouter/free",
  "persist_sessions": true
}
```

JSON has no independent precedence or runtime. It is normalized into the same effective AgentProlog configuration projection.

## Project configuration and trust

AgentProlog owns this downstream project convention:

```text
<project-root>/.agentprolog/config.prolog
<project-root>/.agentprolog/config.json
```

Project `config.prolog` wins when both exist.

A repository-local executable config is **not executed merely because the repository was opened**. The host supplies a structured project identity and an explicit trust decision:

```prolog
_{project:_{identity:project_identity(my_project, 1),
            root:"/absolute/project/root",
            trusted:true}}
```

With `trusted:false` or with trust omitted, AgentProlog may report the discovered config as `blocked_untrusted`, but does not load or apply it. This prevents a cloned repository from acquiring host-code execution merely by containing `.agentprolog/config.prolog`.

Project trust is deliberately strong: once trusted, project config is real Prolog host extension code. It is **not** an authority tier and does not mean “allow all tools.” Registered AgentProlog tools still use their declared schemas, capabilities, authority and effect boundaries when they are invoked, but the config module itself is trusted process code.

The project root is discovery metadata, not the durable security identity. #75 supplies the long-term canonical ProjectIdentity/scoped-state substrate.

## Editing configuration

Changing executable configuration is a privileged mutation. A model suggestion is not permission to rewrite the file that will run on the next reload.

Frontends must request config edits through the AgentProlog authority-mediated file-mutation path. `agentprolog_config_save_file/4` is a trusted whole-file writer for the final host-side write; it is not intended to be exposed as an unrestricted model tool. General editing of hand-written executable Prolog should use an authority-mediated text/diff mutation so helper code is not accidentally replaced by a generated `config/1` fact.

AgentProlog-created or AgentProlog-rewritten config files are forced to POSIX mode `0600`. Writes use a temporary file and replacement so an invalid canonical configuration value is rejected before the existing file is touched.

Generated Prolog files contain a `config/1` fact and remain ordinary executable Prolog files. Users can edit them and add helper predicates, hooks, tools, or detectors.

## Load and reload lifecycle

Reading effective configuration does not repeatedly execute `config.prolog`.

The first load of a path creates an isolated generated config module and records an active generation. Later `agentprolog_config_resolve/2` calls reuse that active generation without re-running directives or `initialization/1` hooks.

An explicit `agentprolog_config_reload_file/3` loads the current file into a **fresh generated module**. The new module and projected settings become active only after the candidate load and projection succeed. A failed reload therefore leaves the previous active projection selected. Trusted candidate code may still have performed its own side effects before failing; executable configuration is host code, not a transaction sandbox.

Old generated modules are inactive after a successful reload. Generation identity is exposed in source provenance so #128-#130 can remove stale hook/tool/detector registrations owned by the previous generation instead of accumulating duplicate active extensions.

A successful trusted whole-file write invalidates the cached generation. The next resolve or explicit reload loads the newly written file as a new generation.

## Secrets

Credential-like keys such as `api_key`, `openrouter_api_key`, `deepseek_api_key`, tokens, passwords, and credential fields are rejected from the canonical ordinary-settings projection. Provider credentials should normally remain environment or external secret references.

This is not a claim that trusted executable Prolog is sandboxed. Trusted config can call ordinary Prolog APIs and access what the process can access. The restriction exists to keep frontends and persisted configuration projections from casually becoming plaintext secret stores.

## API

The first slice exposes:

```prolog
agentprolog_config_default_path(-Path).
agentprolog_config_json_path(-Path).
agentprolog_project_config_paths(+ProjectRoot, -PrologPath, -JsonPath).
agentprolog_config_defaults(-Config).
agentprolog_config_load_file(+Path, +Format, -Outcome).
agentprolog_config_reload_file(+Path, +Format, -Outcome).
agentprolog_config_normalize(+Config, -Outcome).
agentprolog_config_resolve(+Context, -Outcome).
agentprolog_config_save_file(+Path, +Format, +Config, -Outcome).
```

`Format` is `prolog`, `json`, or `auto` for a recognized extension.

Frontends consume `agentprolog_config_resolve/2` and its source provenance. They should not reproduce discovery, project trust, precedence, reload, or file-format semantics themselves.

## Follow-up extension points

Issue #128 adds executable Prolog hooks and typed extension points. #129 lets trusted config register tools through the canonical tool runtime. #130 adds programmable error and loop/non-progress detectors. #131 replaces the DeepSeek Harness private settings authority with these AgentProlog APIs.
