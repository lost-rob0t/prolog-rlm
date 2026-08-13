:- initialization(main, main).

:- use_module(library(plunit)).
:- consult(bootstrap_test).
:- consult(rlm_chain_test).
:- consult(rlm_chain_runtime_test).
:- consult(rlm_chain_message_metadata_test).
:- consult(rlm_chain_control_test).
:- consult(rlm_stream_canonical_test).
:- consult(rlm_mcp_model_test).
:- consult(rlm_mcp_2025_test).
:- consult(rlm_mcp_2026_test).
:- consult(rlm_mcp_runtime_test).
:- consult(rlm_mcp_dual_test).
:- consult(rlm_mcp_boundary_test).
:- consult(rlm_context_test).
:- consult(rlm_plan_test).
:- consult(rlm_tool_test).
:- consult(rlm_completion_test).
:- consult(rlm_completion_hardening_test).
:- consult(rlm_outcome_test).
:- consult(rlm_agent_test).
:- consult(rlm_graph_test).

main(_) :-
    (   run_tests
    ->  halt(0)
    ;   halt(1)
    ).
