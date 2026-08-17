:- begin_tests(rlm_authority_hardening).

:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_mcp_server').

:- multifile rlm_mcp_server:mcp_server/2.

rlm_mcp_server:mcp_server(
    authority_once_fixture,
    mcp_server_spec{
        transport:fixture(stdio,
                          plunit_rlm_authority_hardening:unused_fixture),
        install:process(true, [], []),
        version:test,
        capabilities:[],
        options:[]
    }).

unused_fixture(_, _, error(unused_fixture_transport)).

base_operation(Correlation,
               authority_operation{
                   name:hardening_write,
                   effect:write,
                   capability:tool(hardening_write),
                   args:_{value:1},
                   details:operation_details{target_path:"fixture://same"},
                   correlation:Correlation
               }).

test(fingerprint_ignores_incidental_correlation_metadata) :-
    Context = session(fingerprint_correlation),
    base_operation(correlation{trace_id:trace_a,
                               session_id:session_a,
                               run_id:run_a},
                   First),
    base_operation(correlation{trace_id:trace_b,
                               session_id:session_b,
                               run_id:run_b},
                   Second),
    rlm_operation_fingerprint(Context, First, FirstFingerprint),
    rlm_operation_fingerprint(Context, Second, SecondFingerprint),
    assertion(FirstFingerprint == SecondFingerprint).

test(fingerprint_changes_when_executable_payload_changes) :-
    Context = session(fingerprint_payload),
    base_operation(correlation{trace_id:trace_a}, First),
    put_dict(args, First, _{value:2}, Second),
    rlm_operation_fingerprint(Context, First, FirstFingerprint),
    rlm_operation_fingerprint(Context, Second, SecondFingerprint),
    assertion(FirstFingerprint \== SecondFingerprint).

test(mcp_allow_once_completes_and_replays_exact_operation,
     [ setup(rlm_authority_clear(session(mcp_allow_once_fixture))),
       cleanup(rlm_authority_clear(session(mcp_allow_once_fixture)))
     ]) :-
    Context = session(mcp_allow_once_fixture),
    rlm_set_authority(Context, allow_once, ok(_)),
    Options = [authority_context(Context)],
    rlm_install_mcp_server(authority_once_fixture, Options, First),
    First = ok(FirstResult),
    assertion(FirstResult.status == installed),
    rlm_authority(Context, approve_diff),
    rlm_install_mcp_server(authority_once_fixture, Options, Second),
    assertion(Second == First).

:- end_tests(rlm_authority_hardening).
