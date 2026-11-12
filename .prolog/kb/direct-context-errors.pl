% Verified by issue #423 direct-loop and Auto-Dig selector consumer tests.
direct_context_repairable_fault(unknown_context_alias).
direct_context_repairable_fault(unsupported_selector).
direct_context_repairable_fault(out_of_range).

direct_context_error_boundary(rlm_direct, read_only,
                              correlated_native_context_observation,
                              charged_context_call).
