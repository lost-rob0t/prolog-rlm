:- begin_tests(rlm_agent_zero_adapter).

:- use_module('../prolog/adaptors/rlm_agent_zero_adapter').
:- use_module('../prolog/rlm_tool').

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

host_tool(Name, Args, _{tool:Name, args:Args}).

:- end_tests(rlm_agent_zero_adapter).
