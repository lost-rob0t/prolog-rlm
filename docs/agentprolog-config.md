# AgentProlog configuration

AgentProlog has one canonical configuration model and exactly two input formats:

- Prolog-native `config.prolog`;
- JSON.

Prolog is the primary format. JSON is normalized through the same resolver and does not own separate runtime semantics.

## User configuration

The default Prolog path is:

```text
$XDG_CONFIG_HOME/prolog-rlm/agentProlog/config.prolog
```

When `XDG_CONFIG_HOME` is unset, AgentProlog uses `$HOME/.config` in the usual way. If `config.prolog` does not exist, discovery falls back to `config.json` in the same directory. If both exist, `config.prolog` wins deterministically and the JSON path is reported as shadowed provenance.

The default runtime settings are lossless conversation history, no compaction, persistent sessions, and OpenRouter using `openrouter/free`. Direct DeepSeek routing is not required by AgentProlog configuration.

## Prolog format

`config.prolog` is deliberately read as closed data. It is **not** consulted as an arbitrary Prolog module.

A minimal file can use `setting/2`:

```prolog
setting(provider, openrouter).
setting(model, "openrouter/free").
setting(persist_sessions, true).
```

A larger configuration can use a dict:

```prolog
config(_{
    settings: _{
        provider: openrouter,
        model: "openrouter/free"
    },
    frontend: _{
        theme: "dark"
    },
    detectors: _{
        loop_guard: _{enabled: true}
    }
}).
```

Sections may also be overlaid individually:

```prolog
section(frontend, _{theme: "dark"}).
section(prompt, _{max_tokens: 300000}).
```

The canonical sections reserved by the first configuration schema are `settings`, `extensions`, `tools`, `detectors`, `prompt`, and `frontend`. Later AgentProlog extension registries can validate their own values inside those sections without creating another configuration parser.

### JSON from `config.prolog`

The stock Prolog format includes a JSON input handler. This keeps Prolog as the entry point while allowing shared JSON fragments:

```prolog
json("shared.json").
setting(model, "openrouter/auto").
```

`include_json/1` is an equivalent explicit spelling.

Included JSON must stay inside the directory tree containing the `config.prolog` file. It cannot use `../` or an absolute path to escape that tree.

Declarations are applied in file order, so later Prolog declarations can deliberately override values loaded from JSON.

## JSON format

JSON may use the canonical sections:

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

For ordinary settings, a shorthand object is also accepted:

```json
{
  "provider": "openrouter",
  "model": "openrouter/free",
  "persist_sessions": true
}
```

Both examples are normalized into the same canonical `agentprolog_config{...}` representation used by Prolog input.

## Project configuration

AgentProlog owns the downstream project convention:

```text
<project-root>/.agentprolog/config.prolog
<project-root>/.agentprolog/config.json
```

Project `config.prolog` wins when both files exist.

The filesystem root is discovery metadata, not project security identity. The resolver requires a separate explicit, ground project identity from the trusted host. The current API is shaped so #75's canonical ProjectIdentity can replace that supplied identity directly when the scoped-state substrate lands.

Ordinary project settings overlay user settings. Resolving project A never mutates or reuses project B's effective configuration.

## Security model

The Prolog format is parsed with `read_term/3` and accepts only supported ground declarations. AgentProlog does not call `consult/1` on discovered project configuration.

The following are not configuration declarations and are rejected rather than executed:

```prolog
:- initialization(...).
foo(X) :- dangerous(X).
```

Likewise, configuration loading does not grant capabilities, change an authority tier, authorize a tool effect, start an MCP server, or bypass path/process/network policy. Later tool/hook/detector configuration selects trusted registered implementations through their own closed schemas.

Credential-like settings such as `api_key`, `openrouter_api_key`, `deepseek_api_key`, access tokens, passwords, and credential fields are rejected. Provider secrets remain environment or trusted external configuration references.

## API

The first slice exposes:

```prolog
agentprolog_config_default_path(-Path).
agentprolog_config_json_path(-Path).
agentprolog_project_config_paths(+ProjectRoot, -PrologPath, -JsonPath).
agentprolog_config_defaults(-Config).
agentprolog_config_load_file(+Path, +Format, -Outcome).
agentprolog_config_normalize(+Config, -Outcome).
agentprolog_config_resolve(+Context, -Outcome).
agentprolog_config_save_file(+Path, +Format, +Config, -Outcome).
```

`Format` is `prolog`, `json`, or `auto` for load/save paths with a recognized extension.

A project-aware resolution context looks like:

```prolog
_{project:_{identity:project_identity(my_project, 1),
            root:"/absolute/project/root"}}
```

Frontends should consume the effective configuration and provenance returned by `agentprolog_config_resolve/2`. They should not reproduce precedence or format semantics themselves.

## Follow-up extension points

Issue #128 defines the typed hook/extension registry. #129 adds config-driven trusted tool selection. #130 adds error and non-progress/loop detectors. #131 migrates the DeepSeek Harness path from its private settings file to these canonical AgentProlog configuration APIs.
