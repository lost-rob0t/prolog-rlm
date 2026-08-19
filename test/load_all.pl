:- initialization(main, main).

:- use_module('../prolog/rlm').
:- use_module('../prolog/rlm_context_budget', []).
:- use_module('../prolog/rlm_conversation', []).
:- use_module('../prolog/rlm_conversation_warm', []).
:- use_module('../prolog/rlm_conversation_runtime', []).
:- use_module('../prolog/rlm_prompt_compiler', []).
:- use_module('../prolog/rlm_effect', []).
:- use_module('../prolog/rlm_effect_authority', []).
:- use_module('../prolog/rlm_effect_executor', []).
:- use_module('../prolog/rlm_effect_persist', []).
:- use_module('../prolog/rlm_effect_migration', []).
:- use_module('../prolog/rlm_effects', []).
:- use_module('../prolog/rlm_tool_loader', []).
:- use_module('../prolog/rlm_mcp_policy', []).
:- use_module('../prolog/rlm_mcp_server', []).
:- use_module('../prolog/rlm_mcp_tool', []).
:- use_module('../prolog/rlm_mcp_tool_pack', []).
:- use_module('../prolog/rlm_evidence', []).
:- use_module('../prolog/rlm_assertion', []).
:- use_module('../prolog/rlm_spec', []).
:- use_module('../prolog/rlm_spec_lang', []).
:- use_module('../prolog/rlm_verify', []).
:- use_module('../prolog/rlm_spec_workflow', []).
:- use_module('../agentProlog/prolog/prolog_agent_ui_v1', []).
:- use_module('../agentProlog/prolog/prolog_agent_ui_facade', []).
:- use_module('../agentProlog/prolog/prolog_agent_ui_fixture', []).

main(_) :-
    (   rlm:rlm_ready,
        rlm_context_budget:rlm_context_budget_ready,
        rlm_conversation:rlm_conversation_ready,
        rlm_conversation_warm:rlm_conversation_warm_ready,
        rlm_conversation_runtime:rlm_conversation_runtime_ready,
        rlm_prompt_compiler:rlm_prompt_compiler_ready,
        rlm_evidence:rlm_evidence_ready,
        rlm_assertion:rlm_assertion_ready,
        rlm_spec:rlm_spec_ready,
        rlm_spec_lang:rlm_spec_lang_ready,
        rlm_verify:rlm_verify_ready,
        rlm_spec_workflow:rlm_spec_workflow_ready,
        prolog_agent_ui_v1:ui_v1_ready,
        prolog_agent_ui_facade:ui_facade_ready,
        prolog_agent_ui_fixture:ui_fixture_ready
    ->  halt(0)
    ;   halt(1)
    ).
