:- module(rlm,
          [ rlm_version/1,
            rlm_ready/0,
            rlm_completion/4,
            llm_query/3,
            rlm_query/4,
            rlm_cancellation_token/1,
            rlm_cancel/1,
            default_completion_budget/1
          ]).

/** <module> prolog-rlm entrypoint

Load this module to initialize the public runtime namespaces.
*/

:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_plan).
:- use_module(rlm_tool).
:- use_module(rlm_completion,
              [ rlm_completion/4,
                llm_query/3,
                rlm_query/4,
                rlm_cancellation_token/1,
                rlm_cancel/1,
                default_completion_budget/1
              ]).
:- use_module(rlm_agent).
:- use_module(rlm_graph).
:- use_module(rlm_mcp).

rlm_version('0.1.0-dev').

rlm_ready :-
    rlm_chain:rlm_chain_ready,
    rlm_context:context_backend(memory, _),
    rlm_plan:default_plan_budget(_),
    rlm_tool:capabilities_normalize([], ok([])),
    rlm_completion:default_completion_budget(_),
    rlm_agent:rlm_agent_ready,
    rlm_graph:rlm_graph_ready,
    rlm_mcp:rlm_mcp_ready.
