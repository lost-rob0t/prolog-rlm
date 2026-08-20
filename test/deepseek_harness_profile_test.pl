:- begin_tests(deepseek_harness_profile).

:- use_module(library(readutil)).

test(headless_profile_uses_base_and_headless_bundles) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/package.json', Package, []),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-base"')),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-headless"')),
    assertion(\+ sub_string(Package, _, _, _, '"@deepseek-ai/dsh-web-app"')).

test(web_profile_uses_base_and_web_bundle) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile-web/package.json', Package, []),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-base"')),
    assertion(sub_string(Package, _, _, _, '"@deepseek-ai/dsh-web-app"')),
    assertion(\+ sub_string(Package, _, _, _, '"@deepseek-ai/dsh-headless"')).

test(base_bundle_keeps_only_agent_and_session_services_in_headless) :-
    read_file_to_string('../agentProlog/deepseek-harness/upstream/packages/bundle/base/cordis.patch.yml', Base, []),
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml', Profile, []),
    patch_ids(Base, Ids),
    forall(( member(Id, Ids), \+ memberchk(Id, ["agent", "session"]) ),
           assertion(disabled_in_profile(Profile, Id))).

test(headless_bundle_keeps_only_argv_startup) :-
    read_file_to_string('../agentProlog/deepseek-harness/upstream/packages/bundle/headless/cordis.patch.yml', Headless, []),
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml', Profile, []),
    patch_ids(Headless, Ids),
    forall(( member(Id, Ids), Id \== "headless-startup" ),
           assertion(disabled_in_profile(Profile, Id))).

test(headless_profile_preserves_required_dsh_spine) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile/cordis.patch.yml', Patch, []),
    forall(member(Id, ["session", "agent", "headless-startup"]),
           assertion(\+ disabled_in_profile(Patch, Id))),
    assertion(sub_string(Patch, _, _, _, "- id: prolog-agent-factory\n      name: '@prolog-rlm/dsh-agent-factory'")),
    assertion(sub_string(Patch, _, _, _, "- id: prolog-headless-runner\n      name: '@prolog-rlm/dsh-agent-factory/headless'")),
    assertion(sub_string(Patch, _, _, _, "inject: [headlessStartup, agents]" )).

test(web_profile_fences_stock_executors_and_history_rewriters) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile-web/cordis.patch.yml', Patch, []),
    forall(member(Id,
                  ["llm-pi-ai", "llm-deepseek", "agent-loop", "tool-bash",
                   "tool-fs", "tool-web", "agent-presets", "compaction-basic",
                   "command-compact", "tool-result-pruner",
                   "subagent-spawn-in-process", "subagent-fork-in-process",
                   "workflow-worker-thread", "tool-workflow"]),
           assertion(disabled_in_profile(Patch, Id))),
    assertion(sub_string(Patch, _, _, _, "- id: prolog-agent-factory\n      name: '@prolog-rlm/dsh-agent-factory'" )).

test(web_profile_preserves_api_gateway_required_service_spine) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile-web/cordis.patch.yml', Patch, []),
    forall(member(Id,
                  ["agent", "session", "agent-default-model", "llm", "tools",
                   "subagent", "user-questions", "attachment-local",
                   "session-query-sqlite", "session-projection", "workspace",
                   "directory-picker"]),
           assertion(\+ disabled_in_profile(Patch, Id))),
    assertion(sub_string(Patch, _, _, _, 'provider: prolog-rlm')),
    assertion(sub_string(Patch, _, _, _, 'model: managed')).

test(web_profile_preserves_gui_transport_and_conversation_spine) :-
    read_file_to_string('../agentProlog/deepseek-harness/profile-web/cordis.patch.yml', Patch, []),
    forall(member(Id,
                  ["web-startup", "webserver", "web-runtime", "api-gateway",
                   "modules", "connection", "api-remotes", "client-runtime",
                   "cordis-client-runner", "ui-layout", "ui-renderer",
                   "ui-sidebar", "ui-conversation", "ui-workspace"]),
           assertion(\+ disabled_in_profile(Patch, Id))).

test(root_pnpm_interface_is_the_public_entrypoint) :-
    read_file_to_string('../package.json', Package, []),
    forall(member(Needle,
                  ['"packageManager": "pnpm@11.7.0"',
                   '"build": "./bin/build-agentProlog"',
                   '"dev": "./bin/dev-agentProlog"',
                   '"start": "./bin/agentProlog"',
                   '"headless": "./bin/agentProlog-headless"']),
           assertion(sub_string(Package, _, _, _, Needle))).

test(runtime_launchers_never_install_or_build) :-
    forall(member(Path, ['../bin/agentProlog', '../bin/agentProlog-headless']),
           ( read_file_to_string(Path, Launcher, []),
             assertion(\+ sub_string(Launcher, _, _, _, 'pnpm install')),
             assertion(\+ sub_string(Launcher, _, _, _, 'submodule update')),
             assertion(\+ sub_string(Launcher, _, _, _, 'build:official')),
             assertion(sub_string(Launcher, _, _, _, 'run pnpm run build'))
           )).

test(dev_uses_upstream_web_watcher_without_building) :-
    read_file_to_string('../bin/dev-agentProlog', Dev, []),
    assertion(sub_string(Dev, _, _, _, 'run dev:web')),
    assertion(sub_string(Dev, _, _, _, 'run pnpm run build')),
    assertion(\+ sub_string(Dev, _, _, _, 'build:official')),
    assertion(\+ sub_string(Dev, _, _, _, 'submodule update')).

test(builder_uses_standalone_upstream_official_build) :-
    read_file_to_string('../bin/build-agentProlog', Builder, []),
    assertion(sub_string(Builder, _, _, _, 'git clone --local --no-hardlinks')),
    assertion(sub_string(Builder, _, _, _, 'install --frozen-lockfile')),
    assertion(sub_string(Builder, _, _, _, 'run build:official')),
    assertion(\+ sub_string(Builder, _, _, _, 'CI=true')),
    assertion(sub_string(Builder, _, _, _, 'profile-web')),
    assertion(sub_string(Builder, _, _, _, 'agentProlog-headless')).

patch_ids(Text, Ids) :-
    split_string(Text, "\n", "\r", Lines),
    findall(Id,
            ( member(Line, Lines),
              normalize_space(string(Trimmed), Line),
              string_concat("- id: ", Id, Trimmed)
            ),
            Ids0),
    sort(Ids0, Ids).

disabled_in_profile(Profile, Id) :-
    format(string(Needle), '- id: ~s\n  disabled: true', [Id]),
    sub_string(Profile, _, _, _, Needle).

:- end_tests(deepseek_harness_profile).
