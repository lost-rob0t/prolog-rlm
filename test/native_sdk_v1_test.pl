:- begin_tests(native_sdk_v1).

:- use_module(library(http/json)).
:- use_module(library(lists), [sort/2]).

fixture(Path) :-
    prolog_load_context(directory, Here),
    directory_file_path(Here, 'fixtures/native_sdk_v1.json', Path).

load_manifest(Manifest) :-
    fixture(Path),
    setup_call_cleanup(
        open(Path, read, Stream, [encoding(utf8)]),
        json_read_dict(Stream, Manifest),
        close(Stream)).

test(protocols_reuse_existing_runtime_contracts) :-
    load_manifest(M),
    M.protocol == "prolog_rlm_native_sdk_v1",
    M.ui_protocol == "prolog_agent_ui_v1",
    M.async_contract == "canonical_async_sync_bridge".

test(exact_eight_language_lanes) :-
    load_manifest(M),
    sort(M.languages, Actual),
    sort(["common_lisp",
          "python",
          "typescript",
          "nim",
          "emacs_lisp",
          "kotlin_jvm_android",
          "rust",
          "go"], Expected),
    Actual == Expected.

test(duplex_backend_kinds_are_closed) :-
    load_manifest(M),
    sort(M.backend_kinds, Actual),
    sort(["model", "tool", "verifier"], Expected),
    Actual == Expected.

test(required_conformance_cases_present) :-
    load_manifest(M),
    forall(member(Case,
                  ["capability_negotiation",
                   "prompt_stream_success",
                   "authority_pending_resolve",
                   "cancellation",
                   "timeout",
                   "reconnect_snapshot_replay",
                   "stale_event_rejection",
                   "usage_trace_correlation",
                   "indeterminate_external_effect",
                   "unknown_required_extension_rejected"]),
           memberchk(Case, M.required_cases)).

test(local_transport_is_mandatory_a2a_is_optional) :-
    load_manifest(M),
    M.transports = ["local_ndjson", "a2a_optional"].

:- end_tests(native_sdk_v1).
