:- begin_tests(rlm_demo).

:- use_module('../prolog/rlm_demo').

pass_demo(Name) :-
    demo(Name, Result),
    assertion(Result.status == pass),
    assertion(Result.name == Name).

test(context_demo) :-
    pass_demo(context),
    demo(context, Result),
    assertion(Result.value.search_matches =:= 2),
    assertion(length(Result.trace, 2)).

test(tool_demo_reads_fixture_under_capability) :-
    pass_demo(tool),
    demo(tool, Result),
    assertion(sub_string(Result.value.content,
                         _, _, _,
                         "PROLOG_RLM_TOOL_OK")),
    Result.trace = [Trace],
    assertion(Trace.authorization == allowed),
    assertion(Trace.status == ok).

test(recursion_demo_executes_depth_one) :-
    pass_demo(recursion),
    demo(recursion, Result),
    assertion(Result.value.selected_policy == recursive_rlm),
    assertion(Result.value.depth =:= 1),
    assertion(Result.value.usage.model_calls =:= 2).

test(agent_demo_cascades_parent_cancellation) :-
    pass_demo(agent),
    demo(agent, Result),
    assertion(Result.value.logical_agents =:= 2),
    assertion(Result.value.worker_pool_size =:= 2),
    assertion(Result.value.parent_status == cancelled(demo_complete)),
    assertion(Result.value.child_status == cancelled(demo_complete)).

test(graph_demo_interrupts_checkpoints_and_resumes) :-
    pass_demo(graph),
    demo(graph, Result),
    assertion(Result.value.paused_status == paused(needs_approval)),
    assertion(Result.value.checkpoint_status == paused(needs_approval)),
    assertion(Result.value.completed_status == completed),
    assertion(Result.value.state.approved == true),
    assertion(Result.trace \== []).

test(mcp_demo_uses_version_neutral_facade) :-
    pass_demo(mcp),
    demo(mcp, Result),
    assertion(Result.value.facade == version_neutral),
    assertion(Result.value.supported_protocols ==
              ['2025-11-25','2026-07-28']),
    assertion(Result.value.list_tools.op == list_tools).

test(all_demo_runs_every_family) :-
    demo(all, Result),
    assertion(Result.status == pass),
    assertion(length(Result.cases, 6)),
    findall(Name,
            ( member(Case, Result.cases),
              Name = Case.name
            ),
            Names),
    assertion(Names == [context,tool,recursion,agent,graph,mcp]).

test(unknown_demo_is_structured_error) :-
    demo(nope, error(Error)),
    assertion(Error.kind == unknown_demo),
    assertion(memberchk(all, Error.available)).

:- end_tests(rlm_demo).
