:- begin_tests(zai_synthetic_acceptance).
:- use_module('support/zai_synthetic_acceptance').

test(offline_model_drives_read_create_modify_write_with_real_files) :-
    run_acceptance(offline, 'offline-fixture', Evidence),
    assertion(Evidence.model_calls =:= 6),
    assertion(Evidence.tool_calls =:= 4),
    assertion(Evidence.context_calls =:= 1),
    assertion(Evidence.filesystem_assertions == passed).

:- end_tests(zai_synthetic_acceptance).
