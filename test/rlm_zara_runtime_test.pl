:- begin_tests(rlm_zara_runtime).

:- use_module('../prolog/rlm_zara_runtime').

test(descriptor_is_backend_neutral_machine_contract) :-
    zara_runtime_descriptor(Descriptor),
    assertion(Descriptor.id == "prolog-rlm"),
    assertion(Descriptor.protocol == "ZARA-RUNTIME/1"),
    assertion(Descriptor.locality == "local_sidecar"),
    assertion(Descriptor.transport == "loopback_http"),
    assertion(Descriptor.provider_control == "runtime"),
    assertion(Descriptor.model_control == "runtime"),
    assertion(Descriptor.supports_cancel == true),
    assertion(Descriptor.supports_streaming == false).

test(health_does_not_claim_provider_credential_readiness) :-
    zara_runtime_health(Health),
    assertion(Health.runtime_id == "prolog-rlm"),
    assertion(Health.available == true),
    assertion(Health.health == "ready").

test(valid_request_id_survives_machine_boundary) :-
    rlm_zara_runtime:normalize_identifier(request_id, "not-active", RequestId),
    assertion(RequestId == "not-active").

test(control_character_request_id_fails_closed,
     [throws(zara_runtime_fault(invalid_identifier(request_id)))]) :-
    rlm_zara_runtime:normalize_identifier(request_id, "bad\nrequest", _).

test(wrapped_runtime_fault_projects_to_typed_invalid_request) :-
    rlm_zara_runtime:error_kind(
        error(zara_runtime_fault(invalid_budget(max_tokens)), context(test, bridge)),
        Kind,
        Message
    ),
    assertion(Kind == "invalid_request"),
    assertion(Message == "runtime request is invalid").

test(optional_product_profiles_are_advertised_without_changing_runtime_identity) :-
    setup_call_cleanup(
        zara_runtime_set_profiles(["agentprolog"]),
        ( zara_runtime_descriptor(Descriptor),
          assertion(Descriptor.id == "prolog-rlm"),
          assertion(Descriptor.profiles == ["agentprolog"])
        ),
        zara_runtime_set_profiles([])
    ).

test(invalid_product_profile_fails_closed,
     [throws(zara_runtime_fault(invalid_profile("Agent Prolog")))]) :-
    zara_runtime_set_profiles(["Agent Prolog"]).

test(duplicate_product_profile_fails_closed,
     [throws(zara_runtime_fault(duplicate_profile))]) :-
    zara_runtime_set_profiles(["agentprolog", "agentprolog"]).

test(incompatible_protocol_fails_closed_without_execution) :-
    Request = _{
        protocol:"ZARA-RUNTIME/99",
        request_id:"bad-protocol",
        mode:"direct",
        prompt:"must not execute"
    },
    zara_runtime_execute(Request, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "incompatible_protocol").

test(unsupported_mode_fails_before_provider_execution) :-
    Request = _{
        protocol:"ZARA-RUNTIME/1",
        request_id:"bad-mode",
        mode:"ambient_python",
        prompt:"must not execute"
    },
    zara_runtime_execute(Request, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "invalid_request").

test(literal_provider_secret_is_rejected_and_redacted) :-
    Secret = "TOP-SECRET-MUST-NOT-LEAK",
    Request = _{
        protocol:"ZARA-RUNTIME/1",
        request_id:"literal-secret",
        mode:"direct",
        prompt:"must not execute",
        provider:_{
            kind:"openai-compatible",
            endpoint:"http://localhost:1/v1/chat/completions",
            model:"fixture",
            api_key:Secret
        }
    },
    zara_runtime_execute(Request, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "invalid_request"),
    term_string(Reply, Rendered),
    assertion(\+ sub_string(Rendered, _, _, _, Secret)).

test(unbounded_budget_is_rejected_before_execution) :-
    Request = _{
        protocol:"ZARA-RUNTIME/1",
        request_id:"huge-budget",
        mode:"direct",
        prompt:"must not execute",
        budgets:_{max_tokens:999999999}
    },
    zara_runtime_execute(Request, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "invalid_request").

test(messages_are_accepted_as_normalized_host_context_until_provider_stage) :-
    Request = _{
        protocol:"ZARA-RUNTIME/1",
        request_id:"messages-invalid-provider",
        mode:"direct",
        messages:[
            _{role:"system", content:"bounded system"},
            _{role:"user", content:"bounded question"}
        ],
        provider:_{kind:"unsupported"}
    },
    zara_runtime_execute(Request, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "invalid_request").

test(cancel_unknown_request_is_idempotent_not_found) :-
    zara_runtime_cancel("not-active", Reply),
    assertion(Reply.protocol == "ZARA-RUNTIME/1"),
    assertion(Reply.status == "not_found"),
    assertion(Reply.found == false).

test(cancel_identifier_rejects_control_characters) :-
    zara_runtime_cancel("bad\nrequest", Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "invalid_request").

:- end_tests(rlm_zara_runtime).
