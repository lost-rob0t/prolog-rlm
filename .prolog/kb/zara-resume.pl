/* Resume contract for the Zara sidecar; see docs/zara-runtime.md. */
zara_resume_endpoint('/zara-runtime/v1/resume',
                     [request_id, generation, approval_id]).
zara_resume_result_source(rlm_authority, pending_resolution).
zara_resume_cursor_scope(request_generation, single_use_in_process).
zara_resume_restart_behavior(cursor_discarded, effect_journal_retained).
