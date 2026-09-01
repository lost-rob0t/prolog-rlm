:- begin_tests(rlm_agent_zero_adapter).

:- use_module('../prolog/adaptors/rlm_agent_zero_adapter').
:- use_module('../prolog/rlm_tool').
:- use_module(library(filesex)).

compile_request(Message, Request) :-
    Request = _{
        message:Message,
        max_context_tokens:4096,
        units:[
            _{format:dox,
              kind:dox,
              name:core,
              description:"Repository DOX",
              content:"Follow the repository instructions.",
              permanent:true},
            _{format:agent_zero_tool,
              kind:tool,
              name:response,
              description:"Return the final answer",
              content:"### response",
              schema:_{type:"object", properties:_{text:_{type:"string"}}},
              effect:read,
              permanent:true},
            _{format:agent_zero_tool,
              kind:tool,
              name:text_editor,
              description:"Read and edit project text files",
              content:"### text_editor",
              schema:_{type:"object", properties:_{path:_{type:"string"}}},
              effect:write,
              permanent:true},
            _{format:agent_zero_tool,
              kind:tool,
              name:browser,
              description:"Browse websites and web pages",
              content:"### browser",
              schema:_{type:"object", properties:_{}},
              effect:network,
              permanent:false},
            _{format:agent_zero_skill,
              kind:skill,
              name:pdf,
              description:"Read and create PDF files",
              content:"Available skill pdf",
              permanent:false}
        ]}.

test(public_adapter_uses_compiler_and_keeps_permanent_core_tools) :-
    compile_request("unrelated question", Request),
    agent_zero_context_compile(Request, ok(Result)),
    assertion(Result.active_tools == [response, text_editor]),
    assertion(sub_string(Result.text, _, _, _, "Return the final answer")),
    assertion(sub_string(Result.text, _, _, _, "Read and edit project text files")),
    assertion(\+ sub_string(Result.text, _, _, _, "### browser")),
    assertion(Result.fingerprint \== ""),
    assertion(is_dict(Result.token_ledger)).

test(relevant_nonpermanent_tool_is_selected_by_prolog) :-
    compile_request("browse this website", Request),
    agent_zero_context_compile(Request, ok(Result)),
    assertion(Result.active_tools == [browser, response, text_editor]).

test(agent_zero_skill_format_is_adapted_without_python_policy) :-
    compile_request("create a pdf", Request),
    agent_zero_context_compile(Request, ok(Result)),
    assertion(memberchk(skill(pdf), Result.active_units)),
    assertion(sub_string(Result.text, _, _, _, "Available skill pdf")).

test(skill_packages_use_canonical_skill_metadata_and_graph,
     [ setup(agent_zero_skill_fixture(Root, ReviewDir, HelperDir, HiddenDir)),
       cleanup(delete_directory_and_contents(Root)) ]) :-
    compile_request("review pull request", Request0),
    Request = Request0.put(_{
        include_core_skills:false,
        skill_packages:[
            _{name:"review-pr", path:ReviewDir},
            _{name:"helper", path:HelperDir}
        ],
        selected_skills:[]
    }),
    agent_zero_context_compile(Request, ok(Result)),
    assertion(memberchk(skill('review-pr'), Result.active_units)),
    assertion(memberchk('review-pr', Result.active_skills)),
    assertion(sub_string(Result.text, _, _, _, "REVIEW_PR_BODY_MARKER")),
    Graph = Result.skill_graph,
    assertion(member(Node, Graph.nodes)),
    assertion(Node.unit == skill('review-pr')),
    assertion(Node.category == review),
    assertion(member(Edge, Graph.edges)),
    assertion(Edge.kind == suggests),
    assertion(Edge.from == skill('review-pr')),
    assertion(Edge.to == skill(helper)),
    assertion(\+ (member(HiddenNode, Graph.nodes),
                  HiddenNode.unit == skill('hidden-skill'))),
    assertion(\+ sub_string(Result.text, _, _, _, "HIDDEN_SKILL_BODY_MARKER")),
    assertion(exists_directory(HiddenDir)).

test(selected_current_chat_skill_is_pinned_on_unrelated_query,
     [ setup(agent_zero_skill_fixture(Root, _ReviewDir, HelperDir, _HiddenDir)),
       cleanup(delete_directory_and_contents(Root)) ]) :-
    compile_request("unrelated question", Request0),
    Request = Request0.put(_{
        include_core_skills:false,
        skill_packages:[_{name:"helper", path:HelperDir}],
        selected_skills:["helper"]
    }),
    agent_zero_context_compile(Request, ok(Result)),
    assertion(memberchk(skill(helper), Result.active_units)),
    assertion(memberchk(helper, Result.active_skills)),
    assertion(sub_string(Result.text, _, _, _, "HELPER_BODY_MARKER")).

test(default_prolog_rlm_core_skills_join_same_graph) :-
    compile_request("unrelated question", Request0),
    Request = Request0.put(_{
        include_core_skills:true,
        skill_packages:[],
        selected_skills:[]
    }),
    agent_zero_context_compile(Request, ok(Result)),
    Graph = Result.skill_graph,
    assertion(member(CoreNode, Graph.nodes)),
    assertion(CoreNode.unit == skill('rlm-operate')),
    assertion(CoreNode.source == prolog_rlm_core),
    assertion(memberchk('rlm-operate', Result.active_skills)).

test(invalid_required_skill_relation_fails_closed,
     [ setup(invalid_skill_graph_fixture(Root, SkillDir)),
       cleanup(delete_directory_and_contents(Root)) ]) :-
    compile_request("broken graph", Request0),
    Request = Request0.put(_{
        include_core_skills:false,
        skill_packages:[_{name:"broken", path:SkillDir}],
        selected_skills:[]
    }),
    agent_zero_context_compile(Request, error(Error)),
    assertion(Error.kind == invalid_agent_zero_context).

test(non_text_callable_content_is_rejected_closed) :-
    compile_request("browse", Request0),
    Request0.units = [First|Rest],
    Bad = First.put(content, call(shell('unsafe'))),
    Request = Request0.put(units, [Bad|Rest]),
    agent_zero_context_compile(Request, error(Error)),
    assertion(Error.kind == invalid_agent_zero_context).

test(tool_declarations_import_as_registered_bindings_not_authority) :-
    compile_request("edit", Request),
    get_dict(units, Request, Units),
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( agent_zero_tool_registry_import(
              Registry,
              Units,
              plunit_rlm_agent_zero_adapter:host_tool,
              ok(Imported)),
          assertion(Imported.count =:= 3),
          tool_discover(Registry, Schemas),
          findall(Name,
                  (member(Schema, Schemas), Name = Schema.name),
                  Names),
          assertion(Names == [browser, response, text_editor])
        ),
        tool_registry_destroy(Registry)).

test(tool_pack_manifest_is_sanitized_and_contains_no_host_handler) :-
    compile_request("edit", Request),
    get_dict(units, Request, Units),
    agent_zero_tool_pack_manifest(Units, agent_zero, ok(Manifest)),
    assertion(Manifest.library == agent_zero),
    assertion(Manifest.category == agent_zero),
    findall(Name, (member(Export, Manifest.tools), Name = Export.name), Names),
    assertion(Names == [browser, response, text_editor]),
    assertion(\+ (sub_term(Sub, Manifest), nonvar(Sub), Sub = _:_)).

agent_zero_skill_fixture(Root, ReviewDir, HelperDir, HiddenDir) :-
    tmp_file(agent_zero_skill_graph, Root),
    make_directory(Root),
    skill_directory(Root, 'review-pr', ReviewDir),
    skill_directory(Root, helper, HelperDir),
    skill_directory(Root, 'hidden-skill', HiddenDir),
    directory_file_path(ReviewDir, 'SKILL.md', ReviewFile),
    write_text_file(
        ReviewFile,
        "---\nname: review-pr\ndescription: Review pull requests.\nmetadata:\n  prolog-rlm: |-\n    {\"schema\":1,\"category\":\"review\",\"aliases\":[\"pr review\"],\"triggers\":[{\"kind\":\"phrase\",\"value\":\"review pull request\",\"weight\":80}],\"requires\":[],\"suggests\":[{\"kind\":\"skill\",\"name\":\"helper\"}],\"conflicts\":[],\"supersedes\":[],\"requires_capability\":null,\"priority\":200,\"activation\":{\"automatic\":true}}\n---\nREVIEW_PR_BODY_MARKER\n"),
    directory_file_path(HelperDir, 'SKILL.md', HelperFile),
    write_text_file(
        HelperFile,
        "---\nname: helper\ndescription: Helper review workflow.\n---\nHELPER_BODY_MARKER\n"),
    directory_file_path(HiddenDir, 'SKILL.md', HiddenFile),
    write_text_file(
        HiddenFile,
        "---\nname: hidden-skill\ndescription: Hidden workflow.\n---\nHIDDEN_SKILL_BODY_MARKER\n").

invalid_skill_graph_fixture(Root, SkillDir) :-
    tmp_file(agent_zero_invalid_skill_graph, Root),
    make_directory(Root),
    skill_directory(Root, broken, SkillDir),
    directory_file_path(SkillDir, 'SKILL.md', SkillFile),
    write_text_file(
        SkillFile,
        "---\nname: broken\ndescription: Broken dependency fixture.\nmetadata:\n  prolog-rlm: |-\n    {\"schema\":1,\"category\":\"test\",\"aliases\":[],\"triggers\":[],\"requires\":[{\"kind\":\"skill\",\"name\":\"missing-skill\"}],\"suggests\":[],\"conflicts\":[],\"supersedes\":[],\"requires_capability\":null,\"priority\":100,\"activation\":{\"automatic\":true}}\n---\nBROKEN_BODY\n").

skill_directory(Root, Name, Directory) :-
    directory_file_path(Root, Name, Directory),
    make_directory(Directory).

write_text_file(Path, Text) :-
    setup_call_cleanup(
        open(Path, write, Stream, [encoding(utf8)]),
        format(Stream, '~s', [Text]),
        close(Stream)).

host_tool(Name, Args, _{tool:Name, args:Args}).

:- end_tests(rlm_agent_zero_adapter).
