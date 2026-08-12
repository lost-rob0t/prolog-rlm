from pathlib import Path


def replace_once(path: str, old: str, new: str) -> None:
    file_path = Path(path)
    text = file_path.read_text()
    if text.count(old) != 1:
        raise SystemExit(f"expected exactly one match in {path}: {old[:80]!r}")
    file_path.write_text(text.replace(old, new, 1))


replace_once(
    "prolog/rlm_plan.pl",
    "normalize_step(tool(Name, Args, Bind), tool(Name, Args, Bind)) :- !.\n"
    "normalize_step(parallel(Plans0, Bind), parallel(Plans, Bind)) :-\n",
    "normalize_step(tool(Name, Args, Bind), tool(Name, Args, Bind)) :- !.\n"
    "normalize_step(spawn_agent(Spec, Capabilities, Bind),\n"
    "               tool(spawn_agent,\n"
    "                    literal(agent_spawn_request{spec:Spec,\n"
    "                                                capabilities:Capabilities}),\n"
    "                    Bind)) :- !.\n"
    "normalize_step(parallel(Plans0, Bind), parallel(Plans, Bind)) :-\n",
)

replace_once(
    "prolog/rlm_plan.pl",
    "normalize_dict_step(tool, Dict, tool(Name, Args, Bind)) :-\n"
    "    !,\n"
    "    require_text_atom(Dict, name, Name),\n"
    "    require_dict_key(Dict, args, Args0),\n"
    "    normalize_expr(Args0, Args),\n"
    "    require_text_atom(Dict, bind, Bind).\n"
    "normalize_dict_step(parallel, Dict, parallel(Plans, Bind)) :-\n",
    "normalize_dict_step(tool, Dict, tool(Name, Args, Bind)) :-\n"
    "    !,\n"
    "    require_text_atom(Dict, name, Name),\n"
    "    require_dict_key(Dict, args, Args0),\n"
    "    normalize_expr(Args0, Args),\n"
    "    require_text_atom(Dict, bind, Bind).\n"
    "normalize_dict_step(spawn_agent, Dict,\n"
    "                    tool(spawn_agent,\n"
    "                         literal(agent_spawn_request{spec:Spec,\n"
    "                                                     capabilities:Capabilities}),\n"
    "                         Bind)) :-\n"
    "    !,\n"
    "    require_dict_key(Dict, spec, Spec),\n"
    "    require_dict_key(Dict, capabilities, Capabilities),\n"
    "    must_list(Capabilities, child_capabilities),\n"
    "    require_text_atom(Dict, bind, Bind).\n"
    "normalize_dict_step(parallel, Dict, parallel(Plans, Bind)) :-\n",
)

replace_once(
    "prolog/rlm_agent.pl",
    "            agent_trace/2,\n"
    "            agent_plan_handler/5\n",
    "            agent_trace/2,\n"
    "            agent_plan_handler/5,\n"
    "            agent_tool_handler/4\n",
)

replace_once(
    "prolog/rlm_agent.pl",
    "    ->  signal_runtime_workers(Id, runtime_destroyed),\n"
    "        destroy_runtime_agents(Id),\n"
    "        catch(thread_pool_destroy(Pool), _, true),\n",
    "    ->  signal_runtime_workers(Id, runtime_destroyed),\n"
    "        catch(thread_pool_destroy(Pool), _, true),\n"
    "        destroy_runtime_agents(Id),\n",
)

replace_once(
    "prolog/rlm_agent.pl",
    "    ->  (   thread_send_message(Queue,\n"
    "                                result(CallId, Result),\n"
    "                                [timeout(SendTimeout)])\n",
    "    ->  (   catch(thread_send_message(Queue,\n"
    "                                      result(CallId, Result),\n"
    "                                      [timeout(SendTimeout)]),\n"
    "                  _,\n"
    "                  fail)\n",
)

replace_once(
    "prolog/rlm_agent.pl",
    "agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child) :-\n"
    "    agent_spawn(Runtime, Parent, Spec, Capabilities, Outcome),\n"
    "    (   Outcome = ok(Child)\n"
    "    ->  true\n"
    "    ;   Outcome = error(Error),\n"
    "        throw(error(agent_spawn_failed(Error),\n"
    "                    context(rlm_agent:agent_plan_handler/5,\n"
    "                            'typed plan could not spawn child agent')))\n"
    "    ).\n",
    "agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child) :-\n"
    "    agent_spawn(Runtime, Parent, Spec, Capabilities, Outcome),\n"
    "    (   Outcome = ok(Child)\n"
    "    ->  true\n"
    "    ;   Outcome = error(Error),\n"
    "        throw(error(agent_spawn_failed(Error),\n"
    "                    context(rlm_agent:agent_plan_handler/5,\n"
    "                            'typed plan could not spawn child agent')))\n"
    "    ).\n"
    "\n"
    "agent_tool_handler(Runtime, Parent, Request, Child) :-\n"
    "    normalize_agent_tool_request(Request, Spec, Capabilities),\n"
    "    agent_plan_handler(Runtime, Parent, Spec, Capabilities, Child).\n"
    "\n"
    "normalize_agent_tool_request(Request, Spec, Capabilities) :-\n"
    "    (   is_dict(Request),\n"
    "        get_dict(spec, Request, Spec),\n"
    "        get_dict(capabilities, Request, RawCapabilities),\n"
    "        is_list(RawCapabilities)\n"
    "    ->  maplist(normalize_agent_tool_capability,\n"
    "                RawCapabilities,\n"
    "                Capabilities)\n"
    "    ;   throw(agent_fault(invalid_agent_spawn_request(Request)))\n"
    "    ).\n"
    "\n"
    "normalize_agent_tool_capability(Value, Capability) :-\n"
    "    capabilities_normalize([Value], ok([Capability])),\n"
    "    !.\n"
    "normalize_agent_tool_capability(Value, Capability) :-\n"
    "    (atom(Value); string(Value)),\n"
    "    !,\n"
    "    require_name_atom(Value, Atom),\n"
    "    (   capabilities_normalize([Atom], ok([Capability]))\n"
    "    ->  true\n"
    "    ;   throw(agent_fault(invalid_child_capability(Value)))\n"
    "    ).\n"
    "normalize_agent_tool_capability(Value, Capability) :-\n"
    "    is_dict(Value),\n"
    "    !,\n"
    "    (   get_dict(type, Value, Type0),\n"
    "        get_dict(name, Value, Name0)\n"
    "    ->  require_name_atom(Type0, Type),\n"
    "        require_name_atom(Name0, Name),\n"
    "        Term =.. [Type, Name],\n"
    "        (   capabilities_normalize([Term], ok([Capability]))\n"
    "        ->  true\n"
    "        ;   throw(agent_fault(invalid_child_capability(Value)))\n"
    "        )\n"
    "    ;   throw(agent_fault(invalid_child_capability(Value)))\n"
    "    ).\n"
    "normalize_agent_tool_capability(Value, _) :-\n"
    "    throw(agent_fault(invalid_child_capability(Value))).\n",
)

print("issue11 source patch applied")
