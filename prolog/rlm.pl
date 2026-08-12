:- module(rlm,
          [ rlm_version/1,
            rlm_ready/0
          ]).

/** <module> prolog-rlm entrypoint

Load this module to initialize the public runtime namespaces.
*/

:- use_module(rlm_chain).
:- use_module(rlm_context).
:- use_module(rlm_agent).
:- use_module(rlm_graph).
:- use_module(rlm_mcp).

rlm_version('0.1.0-dev').

rlm_ready :-
    rlm_chain:rlm_chain_ready,
    rlm_context:context_backend(memory, _),
    rlm_agent:rlm_agent_ready,
    rlm_graph:rlm_graph_ready,
    rlm_mcp:rlm_mcp_ready.
