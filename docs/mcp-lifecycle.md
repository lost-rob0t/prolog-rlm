# Declarative MCP servers and lifecycle

MCP server facts are trusted host configuration. Declaring, consulting, or
loader-discovering a server is inert: it does not install software, launch a
process, connect a client, import remote tools, grant capabilities, or change
host authority.

The boundaries are deliberately separate:

```text
server facts          = declarative host configuration
loader/category       = availability only
capabilities          = invocation permission
authority             = human mediation
installer/run policy  = hard execution confinement
```

None of these boundaries substitutes for another.

## Canonical server fact shape

External host configuration may contribute definitions with `multifile`
clauses. Process-backed declarations select a trusted execution profile instead
of carrying an executable or arbitrary argv directly:

```prolog
:- multifile rlm_mcp_server:mcp_server/2.

rlm_mcp_server:mcp_server(
    filesystem,
    mcp_server_spec{
        transport:stdio(
            package(npx_mcp,
                    '@modelcontextprotocol/server-filesystem',
                    '1.2.3')),
        install:package(npm_mcp,
                        '@modelcontextprotocol/server-filesystem',
                        '1.2.3'),
        environment:[env('GITHUB_TOKEN', env_ref('GITHUB_TOKEN')),
                     env('OPENROUTER_API_KEY',
                         config_ref(openrouter_api_key))],
        working_directory:directory('/srv/mcp'),
        version:external,
        capabilities:[tools],
        options:[timeout(30.0)]
    }).
```

A remote Streamable HTTP declaration remains non-process-backed and may omit all
process configuration:

```prolog
rlm_mcp_server:mcp_server(
    remote_search,
    mcp_server_spec{
        transport:streamable_http('https://mcp.example.invalid'),
        install:none,
        version:external,
        capabilities:[tools, resources]
    }).
```

`mcp_server_definition/2` normalizes one declaration and
`mcp_server_definitions/1` lists valid normalized declarations without running
them.

## First-class configuration references

Raw secret values are not part of the server declaration schema. Environment
bindings contain references:

```prolog
env('GITHUB_TOKEN', env_ref('GITHUB_TOKEN'))
env('OPENROUTER_API_KEY', config_ref(openrouter_api_key))
```

`env_ref(Name)` reads the named host environment variable. `config_ref(Key)`
resolves through trusted host configuration contributed to
`rlm_mcp_policy:mcp_config_value/2`.

Reference names are validated while the declaration is normalized. At the
explicit lifecycle boundary, required references are checked before authority
mediation and before process/network startup where practical. The resolved
secret value itself is fetched only inside the exact authority-permitted trusted
continuation immediately before process creation.

This ordering matters: approval records, normalized authority operations,
model-facing loader discovery, runtime handles, and ordinary lifecycle errors
carry reference metadata rather than resolved secret values. Public lifecycle
options do not accept an arbitrary environment mapping and do not reinterpret
model data as host configuration.

## Trusted execution profiles

Installer and stdio recipes select host-defined profiles. Profiles are trusted
multifile facts, not model-facing declarations:

```prolog
:- multifile rlm_mcp_policy:mcp_installer_profile/2.
:- multifile rlm_mcp_policy:mcp_stdio_profile/2.

rlm_mcp_policy:mcp_installer_profile(
    npm_mcp,
    mcp_process_profile{
        executable:path(npm),
        argv_prefix:[install, '--global'],
        argv_suffix:[],
        package_format:npm,
        cwd_roots:['/srv/mcp'],
        timeout:60.0,
        max_output_bytes:65536
    }).

rlm_mcp_policy:mcp_stdio_profile(
    npx_mcp,
    mcp_process_profile{
        executable:path(npx),
        argv_prefix:['-y'],
        argv_suffix:[],
        package_format:npm,
        cwd_roots:['/srv/mcp'],
        timeout:60.0,
        max_output_bytes:65536
    }).
```

The declaration chooses a profile and package/version. It does not choose an
executable, shell, installer command, or arbitrary argv. Package and version
syntax are structurally validated and the final package argument is constructed
by trusted core code according to the profile's closed package format.

Common shell executables are rejected as process profiles. There is no
`shell=true` escape hatch. Unsupported or undeclared profile names fail before
process creation, including under `dangerous` authority.

## Working-directory policy

`working_directory` is either `inherit` or `directory(AbsolutePath)`. A concrete
working directory is accepted only when the selected trusted process profile
has configured non-root `cwd_roots`, the directory resolves canonically, exists,
and is contained by an allowed root. Loader-facing discovery reports only
whether a working directory is configured, not its concrete path.

## Installation policy

`install` is either:

```prolog
install:none
```

or a closed package declaration:

```prolog
install:package(Profile, Package, Version)
```

Before authority is consulted, the lifecycle validates the profile, package,
version, configuration references, and working-directory confinement. After
authority permits the exact normalized `install` effect, the trusted
continuation resolves configuration references and spawns only the executable
and argument shape defined by the host profile.

Installer stdout/stderr are not returned as unconstrained data. The profile
sets bounded timeout/output policy and installer failure is returned as a
structured lifecycle outcome. A timeout terminates and reaps the owned process.

## Stdio run policy

A declared stdio transport has one of these closed forms:

```prolog
transport:stdio(profile(Profile))
transport:stdio(package(Profile, Package, Version))
```

Legacy `stdio(Executable, Args)` declaration data is not accepted by the server
lifecycle. The same trusted-profile, configuration-reference, package/version,
and working-directory policy used for installation is applied before a stdio
server can start.

Low-level transport code still receives an executable/argv pair internally, but
that pair is constructed only after the declaration has crossed the hard policy
boundary. It is not reconstructed from model-supplied callable or predicate
names.

## Loader/category behavior

The external `mcp` category exposes only sanitized discovery and inspection
tools. Loading the category:

- registers availability metadata only;
- does not install, start, connect, restart, stop, or import an MCP server;
- does not grant `tool(Name)` or `mcp(Name)` capabilities;
- does not change authority;
- does not expose trusted profile executables, profile argv, resolved config
  values, concrete working-directory paths, or raw HTTP endpoint text.

Safe inspection may expose server name, transport kind, trusted profile name,
package/version metadata, configuration-reference kind/name, declared MCP
capabilities, and whether a working directory is configured.

## Explicit lifecycle

Installation and runtime lifecycle remain separate explicit operations:

```prolog
rlm_install_mcp_server(filesystem, InstallOutcome).
rlm_run_mcp_server(filesystem, RunOutcome).
```

A successful run returns an owned `mcp_runtime_handle{}`. Connection is explicit
and borrows the owned transport:

```prolog
RunOutcome = ok(Handle),
rlm_connect_mcp_server(Handle,
                       ClientInfo,
                       ClientCapabilities,
                       [],
                       ConnectOutcome).
```

Closing the resulting MCP client closes the protocol connection view but does
not take ownership of the declared server process. Stop and restart remain
explicit lifecycle operations:

```prolog
rlm_stop_mcp_server(Handle, Outcome).
rlm_restart_mcp_server(Handle, Outcome).
```

Owned stdio handles stop their owned process. Borrowed `existing(Transport)`
views never kill their owner.

## Capability and authority separation

Server declarations may describe remote MCP capabilities, but lifecycle and
tool permission remain host-controlled. Loading or importing a tool never grants
the resulting capability.

The authority modes remain exactly:

```text
approve_diff
allow_once
allow_session
dangerous
```

Unset authority defaults to `approve_diff`. `dangerous` skips interactive
approval only. It never bypasses execution-profile allow-lists, package/version
validation, configuration-reference validation, working-directory confinement,
capability checks, schemas, budgets, network restrictions, or tracing.

## Canonical async direction

Every latency-bearing lifecycle operation uses the shared bounded `rlm_async`
scheduler:

```text
canonical execute predicate
          |
          +--> async API -> Future
          |
          `--> sync API  -> same async API -> await Future
```

The implemented pairs cover install, run, stop, restart, connect, client
command, client close, and canonical server request handling. Trusted code
already executing inside canonical async work uses execute ABIs directly rather
than submitting a nested Future and waiting on it.

## Tool import

Remote tool import is a separate explicit step and requires an already connected
MCP client:

```prolog
mcp_import_tools(Registry,
                 filesystem,
                 Client,
                 [],
                 Outcome).
```

Imported remote tools are ordinary namespaced `rlm_tool` entries and execute
through the same canonical tool contract. Import does not grant their
`tool(Name)` capability.

## Malformed or untrusted declarations

Malformed profiles, config references, package names, versions, working
directories, raw environment values, legacy direct installer processes, and
legacy direct stdio executable/argv declarations fail structurally. They are
not made valid by authority and they are not spawned first and rejected later.

The concrete production standard tool pack is intentionally separate work. This
module defines the host execution boundary that such a pack must obey.
