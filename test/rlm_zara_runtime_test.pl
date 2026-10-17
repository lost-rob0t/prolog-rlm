:- begin_tests(rlm_zara_runtime).

:- use_module('../prolog/rlm_zara_runtime').
:- use_module(library(http/http_open)).
:- use_module(library(http/json)).
:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_json)).
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_effect').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_async').

:- dynamic effect_callback_count/1.

:- http_handler(root('zara-host-tool/v1/read'), host_read_fixture,
                [method(post)]).
:- http_handler(root('zara-host-tool/v1/effect'), host_effect_fixture,
                [method(post)]).

host_effect_fixture(Request) :-
    member(authorization('Bearer test-secret-123456'), Request),
    http_read_json_dict(Request, Body, [value_string_as(string)]),
    with_mutex(zara_effect_fixture,
               ( ( retract(effect_callback_count(N0)) -> true ; N0 = 0 ),
                 N is N0+1,
                 assertz(effect_callback_count(N)) )),
    reply_json_dict(_{protocol:"ZARA-HOST-EFFECT/1",
                      request_id:Body.request_id,
                      tool_call_id:Body.tool_call_id,
                      generation:Body.generation,
                      attempt_id:Body.attempt_id,
                      effect_fingerprint:Body.effect_fingerprint,
                      status:"observed", value:_{seen:Body.args.value}}).

test(effect_callback_requires_approval_and_dispatches_once) :-
    write_host_wire_schema(Wire),
    tmp_file(zara_effect_store, Ledger),
    setup_call_cleanup(
        ( retractall(effect_callback_count(_)),
          assertz(effect_callback_count(0)),
          rlm_effect_store_open(Ledger),
          zara_runtime_server_start(Port),
          zara_runtime_set_bootstrap_token("test-secret-123456"),
          format(string(ReadURL),
                 'http://127.0.0.1:~d/zara-host-tool/v1/read', [Port]),
          format(string(EffectURL),
                 'http://127.0.0.1:~d/zara-host-tool/v1/effect', [Port]),
          format(string(ConfigURL),
                 'http://127.0.0.1:~d/zara-runtime/v1/host-config', [Port]),
          Config = _{protocol:"ZARA-RUNTIME/1",endpoint:ReadURL,
                     effect_endpoint:EffectURL,generation:7,tools:[Wire]},
          host_post(ConfigURL, Config, true, ConfigReply),
          assertion(ConfigReply.status == "configured") ),
        ( rlm_zara_runtime:request_host_tools("effect-request",
                    _{host_tools:["host_write"]}, Registry, Caps),
          Context = session(zara_host("effect-request", 7)),
          tool_invoke(Registry, Caps, host_write, json{value:42},
                      [authority_context(Context)],
                      approval_required(Pending), _),
          effect_callback_count(Before), assertion(Before =:= 0),
          rlm_zara_runtime:project_outcome("effect-request", rlm,
                                          error(pending_tool), Projected),
          assertion(Projected.status == "approval_required"),
          rlm_zara_runtime:request_host_tools("different-request",
                    _{host_tools:["host_write"]}, OtherRegistry, OtherCaps),
          OtherContext = session(zara_host("different-request", 7)),
          tool_invoke(OtherRegistry, OtherCaps, host_write,
                      json{value:42},
                      [authority_context(OtherContext)],
                      approval_required(OtherPending), _),
          assertion(Pending.operation.effect_identity.fingerprint \==
                    OtherPending.operation.effect_identity.fingerprint),
          rlm_deny(OtherPending.id, test_cleanup, ok(_)),
          rlm_authority_clear(OtherContext),
          tool_registry_destroy(OtherRegistry),
          rlm_zara_runtime:release_host_registry("effect-request", Registry),
          host_post(ConfigURL, Config, true, Busy),
          assertion(Busy.status == "failed"),
          format(string(PendingURL),
                 'http://127.0.0.1:~d/zara-runtime/v1/host-pending', [Port]),
          PendingBody = _{protocol:"ZARA-RUNTIME/1",
                          request_id:"effect-request",generation:7},
          host_post(PendingURL, PendingBody, false, Unauthorized),
          assertion(Unauthorized.error.kind == "unauthorized"),
          host_post(PendingURL, PendingBody, true, PendingHTTP),
          assertion(PendingHTTP.status == "approval_required"),
          zara_runtime_pending("effect-request", 8, Missing),
          assertion(Missing.status == "not_found"),
          zara_runtime_pending("effect-request", 7, PendingReply),
          assertion(PendingReply.status == "approval_required"),
          PendingReply.approvals = [Approval],
          assertion(Approval.id == Pending.id),
          assertion(Approval.attempt_id ==
                    Pending.operation.effect_identity.attempt_id),
          assertion(Approval.effect_fingerprint ==
                    Pending.operation.effect_identity.fingerprint),
          rlm_pending_resolution_async(Pending.id, Future),
          format(string(ApprovalURL),
                 'http://127.0.0.1:~d/zara-runtime/v1/host-approval', [Port]),
          ApprovalBody = PendingBody.put(_{approval_id:Pending.id,
                                           decision:"approve"}),
          host_post(ApprovalURL, ApprovalBody, true, ApprovalReply),
          assertion(ApprovalReply.status == "accepted"),
          rlm_future_await(Future, 2.0, Resolution),
          assertion(Resolution.outcome = ok(_)),
          format(string(StatusURL),
                 'http://127.0.0.1:~d/zara-runtime/v1/host-approval-status',
                 [Port]),
          StatusBody = PendingBody.put(approval_id, Pending.id),
          host_post(StatusURL, StatusBody, true, StatusReply),
          assertion(StatusReply.status == "completed"),
          host_post(ConfigURL, Config, true, Reconfigured),
          assertion(Reconfigured.status == "configured"),
          effect_callback_count(After), assertion(After =:= 1),
          rlm_future_destroy(Future),
          rlm_authority_clear(Context),
          tool_registry_destroy(Registry) ),
        ( zara_runtime_set_host_tools("", []),
          zara_runtime_set_bootstrap_token(""),
          zara_runtime_server_stop,
          rlm_effect_store_close,
          catch(delete_file(Ledger), _, true),
          retractall(effect_callback_count(_)) )).

host_post(URL, Body, Authorized, Reply) :-
    atom_json_dict(BodyAtom, Body, []),
    ( Authorized == true
    -> Headers = [request_header('Authorization'='Bearer test-secret-123456')]
    ;  Headers = []
    ),
    append([method(post),post(atom(BodyAtom)),
            request_header('Content-Type'='application/json')],
           Headers, Options),
    setup_call_cleanup(
        http_open(URL, Stream, Options),
        json_read_dict(Stream, Reply),
        close(Stream)).

write_host_wire_schema(_{name:"host_write", effect:"write",
                         description:"Bounded write fixture",
                         arguments:_{type:"object",
                                     properties:_{value:_{type:"integer"}},
                                     required:["value"]},
                         result:_{type:"object",
                                  properties:_{seen:_{type:"integer"}},
                                  required:["seen"]}}).

test(authenticated_host_config_requires_effect_store_for_write) :-
    write_host_wire_schema(Wire),
    setup_call_cleanup(
        ( zara_runtime_set_bootstrap_token("test-secret-123456"),
          zara_runtime_server_start(Port) ),
        ( format(string(URL),
                 'http://127.0.0.1:~d/zara-runtime/v1/host-config', [Port]),
          format(string(ReadURL),
                 'http://127.0.0.1:~d/zara-host-tool/v1/read', [Port]),
          format(string(EffectURL),
                 'http://127.0.0.1:~d/zara-host-tool/v1/effect', [Port]),
          Body = _{protocol:"ZARA-RUNTIME/1",endpoint:ReadURL,
                   effect_endpoint:EffectURL,generation:7,tools:[Wire]},
          atom_json_dict(BodyAtom, Body, []),
          setup_call_cleanup(
              http_open(URL, Stream,
                        [method(post),post(atom(BodyAtom)),
                         request_header('Content-Type'='application/json'),
                         request_header('Authorization'='Bearer test-secret-123456')]),
              json_read_dict(Stream, Reply),
              close(Stream)),
          assertion(Reply.status == "failed"),
          assertion(Reply.error.kind == "effect_store_required") ),
        ( zara_runtime_set_host_tools("", []),
          zara_runtime_set_bootstrap_token(""),
          zara_runtime_server_stop )).

host_read_fixture(Request) :-
    member(authorization('Bearer test-secret-123456'), Request),
    http_read_json_dict(Request, Body, [value_string_as(string)]),
    ( Body.args.value =:= 99
    -> ResponseGeneration is Body.generation+1,
       Status = "ok"
    ; Body.args.value =:= 98
    -> ResponseGeneration = Body.generation,
       Status = "denied"
    ;  ResponseGeneration = Body.generation,
       Status = "ok"
    ),
    reply_json_dict(_{protocol:"ZARA-HOST-TOOL/1",
                      request_id:Body.request_id,
                      tool_call_id:Body.tool_call_id,
                      generation:ResponseGeneration,
                      status:Status, value:_{seen:Body.args.value}}).

host_echo(Args, json{seen:Args.value}).

host_planner(_, ok(planner_output{
    plan:plan([tool(host_echo, literal(json{value:7}), observed),
               final(literal("tool-ran"))]),
    usage:_{prompt_tokens:1, completion_tokens:1,
            total_tokens:2, cost:0.0}})).

host_schema(tool_schema{name:host_echo,
                        description:"Bounded test echo",
                        capability:tool(host_echo),
                        effect:read,
                        arguments:json{type:object,
                                       properties:json{value:json{type:integer}},
                                       required:[value]},
                        result:json{type:object,
                                    properties:json{seen:json{type:integer}},
                                    required:[seen]}}).

host_wire_schema(_{name:"host_echo", description:"Bounded test echo",
                   arguments:_{type:"object",
                               properties:_{value:_{type:"integer"}},
                               required:["value"]},
                   result:_{type:"object",
                            properties:_{seen:_{type:"integer"}},
                            required:["seen"]}}).

test(bootstrap_configures_read_callback_from_authenticated_wire) :-
    host_wire_schema(WireSchema),
    setup_call_cleanup(
        zara_runtime_set_bootstrap_token("test-secret-123456"),
        setup_call_cleanup(
            zara_runtime_server_start(Port),
            ( format(string(ConfigURL),
                     'http://127.0.0.1:~d/zara-runtime/v1/host-config', [Port]),
              format(string(CallbackURL),
                     'http://127.0.0.1:~d/zara-host-tool/v1/read', [Port]),
              Body = _{protocol:"ZARA-RUNTIME/1", endpoint:CallbackURL,
                       generation:7, tools:[WireSchema]},
              atom_json_dict(BodyAtom, Body, []),
              setup_call_cleanup(
                  http_open(ConfigURL, DeniedStream,
                            [method(post), post(atom(BodyAtom)),
                             request_header('Content-Type'='application/json')]),
                  json_read_dict(DeniedStream, Denied),
                  close(DeniedStream)),
              assertion(Denied.error.kind == "unauthorized"),
              setup_call_cleanup(
                  http_open(ConfigURL, AllowedStream,
                            [method(post), post(atom(BodyAtom)),
                             request_header('Content-Type'='application/json'),
                             request_header('Authorization'='Bearer test-secret-123456')]),
                  json_read_dict(AllowedStream, Allowed),
                  close(AllowedStream)),
              assertion(Allowed.status == "configured"),
              zara_runtime_descriptor(Descriptor),
              assertion(Descriptor.supports_host_tools == true)
            ),
            zara_runtime_server_stop),
        ( zara_runtime_set_host_tools("", []),
          zara_runtime_set_bootstrap_token("") )
    ).

test(host_tools_are_absent_until_trusted_registration) :-
    zara_runtime_descriptor(Descriptor),
    assertion(Descriptor.supports_host_tools == false).

test(authenticated_read_callback_reaches_registered_rlm_tool) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_server_start(Port),
        ( format(string(URL), 'http://127.0.0.1:~d/zara-host-tool/v1/read', [Port]),
          setup_call_cleanup(
              zara_runtime_set_host_callback("test-secret-123456", URL,
                                             7, [Schema]),
              ( zara_runtime_descriptor(Descriptor),
                assertion(Descriptor.supports_host_tools == true),
                rlm_zara_runtime:request_host_tools("request-7",
                    _{host_tools:["host_echo"]}, Registry, Capabilities),
                setup_call_cleanup(
                    true,
                    ( tool_invoke(Registry, Capabilities, host_echo,
                                  json{value:11}, [], ok(Execution), _),
                      assertion(Execution.value.seen =:= 11)
                    ),
                    rlm_zara_runtime:release_host_registry(Registry))
              ),
              zara_runtime_set_host_tools("", []))
        ),
        zara_runtime_server_stop
    ).

test(callback_rejects_mismatched_generation_and_host_denial) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_server_start(Port),
        ( format(string(URL), 'http://127.0.0.1:~d/zara-host-tool/v1/read', [Port]),
          setup_call_cleanup(
              zara_runtime_set_host_callback("test-secret-123456", URL,
                                             7, [Schema]),
              ( rlm_zara_runtime:request_host_tools("request-7",
                    _{host_tools:["host_echo"]}, Registry, Capabilities),
                setup_call_cleanup(
                    true,
                    ( tool_invoke(Registry, Capabilities, host_echo,
                                  json{value:99}, [], error(_), MismatchTrace),
                      assertion(MismatchTrace.status == handler_exception),
                      tool_invoke(Registry, Capabilities, host_echo,
                                  json{value:98}, [], error(_), DenialTrace),
                      assertion(DenialTrace.status == handler_exception)
                    ),
                    rlm_zara_runtime:release_host_registry(Registry))
              ),
              zara_runtime_set_host_tools("", []))
        ),
        zara_runtime_server_stop
    ).

test(callback_endpoint_rejects_nonliteral_loopback) :-
    host_schema(Schema),
    catch(zara_runtime_set_host_callback("test-secret-123456",
                                         "http://localhost:1234/zara-host-tool/v1/read",
                                         7, [Schema]),
          Error, true),
    assertion(Error == zara_runtime_fault(invalid_host_callback_endpoint)).

test(host_token_rejects_whitespace) :-
    host_schema(Schema),
    catch(zara_runtime_set_host_tools("invalid secret 123456",
                                      [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
          Error, true),
    assertion(Error == zara_runtime_fault(invalid_host_token)).

test(effectful_host_tool_registration_is_denied_until_resume_contract_exists) :-
    host_schema(ReadSchema),
    put_dict(effect, ReadSchema, write, WriteSchema),
    catch(zara_runtime_set_host_tools("test-secret-123456",
                                      [host_tool(WriteSchema, plunit_rlm_zara_runtime:host_echo)]),
          Error, true),
    assertion(Error == zara_runtime_fault(effectful_host_tool_unsupported)),
    zara_runtime_descriptor(Descriptor),
    assertion(Descriptor.supports_host_tools == false).

test(trusted_host_tool_is_granted_only_when_requested) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        ( zara_runtime_descriptor(Descriptor),
          assertion(Descriptor.supports_host_tools == true),
          rlm_zara_runtime:request_host_tools(_{host_tools:["host_echo"]},
                                             Registry, Capabilities),
          assertion(memberchk(tool(host_echo), Capabilities)),
          rlm_zara_runtime:runtime_options("host-test", fixture, fixture,
                                           _{}, 128, Registry, Capabilities,
                                           token, Options),
          assertion(memberchk(tool_registry(Registry), Options)),
          assertion(memberchk(capabilities(AllCapabilities), Options)),
          assertion(memberchk(tool(host_echo), AllCapabilities)),
          tool_invoke(Registry, Capabilities, host_echo,
                      json{value:7}, [], ok(Execution), _),
          assertion(Execution.value.seen =:= 7),
          rlm_zara_runtime:request_host_tools(_{}, Registry, NoGrants),
          tool_invoke(Registry, NoGrants, host_echo,
                      json{value:7}, [], error(Denial), _),
          assertion(Denial.kind == capability_denied)
        ),
        zara_runtime_set_host_tools("", [])
    ).

test(rlm_completion_invokes_granted_registered_host_read_tool) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        ( rlm_zara_runtime:request_host_tools(_{host_tools:["host_echo"]},
                                               Registry, Capabilities),
          rlm_zara_runtime:runtime_options("host-plan", fixture, fixture,
                                           _{}, 128, Registry, Capabilities,
                                           token, BaseOptions),
          rlm:rlm_completion("invoke registered read tool", text("context"),
                             [planner_handler(plunit_rlm_zara_runtime:host_planner)|BaseOptions],
                             Outcome),
          Outcome = ok(Result),
          assertion(Result.value == "tool-ran"),
          assertion(Result.vars.observed.value.seen =:= 7)
        ),
        zara_runtime_set_host_tools("", [])
    ).

test(host_registration_cannot_replace_registry_during_active_request) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        setup_call_cleanup(
            rlm_zara_runtime:register_request("in-flight", token),
            ( catch(zara_runtime_set_host_tools("", []), Error, true),
              assertion(Error == zara_runtime_fault(host_tools_busy)),
              zara_runtime_descriptor(Descriptor),
              assertion(Descriptor.supports_host_tools == true)
            ),
            rlm_zara_runtime:unregister_request("in-flight", token)),
        zara_runtime_set_host_tools("", [])
    ).

test(client_cannot_submit_tool_schema_or_handler_as_grant) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        ( Request = _{protocol:"ZARA-RUNTIME/1", request_id:"wire-schema",
                      mode:"rlm", prompt:"no provider call",
                      host_tools:[_{name:"host_echo", handler:"shell"}]},
          zara_runtime_execute(Request, Reply),
          assertion(Reply.status == "failed"),
          assertion(Reply.error.kind == "invalid_request")
        ),
        zara_runtime_set_host_tools("", [])
    ).

test(unknown_host_tool_fails_before_provider_execution) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        ( Request = _{protocol:"ZARA-RUNTIME/1",
                      request_id:"unknown-host-tool",
                      mode:"rlm", prompt:"no provider call",
                      host_tools:["not_registered"]},
          zara_runtime_execute(Request, Reply),
          assertion(Reply.status == "failed"),
          assertion(Reply.error.kind == "invalid_request")
        ),
        zara_runtime_set_host_tools("", [])
    ).

test(loopback_generate_requires_host_token_when_tools_are_registered) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        setup_call_cleanup(
            zara_runtime_server_start(Port),
            ( format(string(URL), 'http://127.0.0.1:~d/zara-runtime/v1/generate', [Port]),
              Request = _{protocol:"ZARA-RUNTIME/1", request_id:"auth-check",
                          mode:"rlm", prompt:"no provider call",
                          host_tools:["host_echo"], provider:_{kind:"unsupported"}},
              atom_json_dict(Body, Request, []),
              setup_call_cleanup(
                  http_open(URL, Stream,
                            [method(post), post(atom(Body)),
                             request_header('Content-Type'='application/json')]),
                  json_read_dict(Stream, Denied),
                  close(Stream)),
              assertion(Denied.error.kind == "unauthorized"),
              setup_call_cleanup(
                  http_open(URL, AuthorizedStream,
                            [method(post), post(atom(Body)),
                             request_header('Content-Type'='application/json'),
                             request_header('Authorization'='Bearer test-secret-123456')]),
                  json_read_dict(AuthorizedStream, Allowed),
                  close(AuthorizedStream)),
              assertion(Allowed.error.kind == "invalid_request")
            ),
            zara_runtime_server_stop),
        zara_runtime_set_host_tools("", [])
    ).

test(loopback_cancel_requires_host_token_when_tools_are_registered) :-
    host_schema(Schema),
    setup_call_cleanup(
        zara_runtime_set_host_tools("test-secret-123456", [host_tool(Schema, plunit_rlm_zara_runtime:host_echo)]),
        setup_call_cleanup(
            zara_runtime_server_start(Port),
            ( format(string(URL), 'http://127.0.0.1:~d/zara-runtime/v1/cancel', [Port]),
              setup_call_cleanup(
                  http_open(URL, Stream,
                            [method(post), post(atom('{"request_id":"missing"}')),
                             request_header('Content-Type'='application/json')]),
                  json_read_dict(Stream, Denied),
                  close(Stream)),
              assertion(Denied.error.kind == "unauthorized")
            ),
            zara_runtime_server_stop),
        zara_runtime_set_host_tools("", [])
    ).

test(server_binds_ipv4_loopback_and_serves_discovery) :-
    setup_call_cleanup(
        zara_runtime_server_start(Port),
        ( integer(Port),
          Port > 0,
          format(string(URL), 'http://127.0.0.1:~d/zara-runtime/v1/discover', [Port]),
          setup_call_cleanup(
              http_open(URL, Stream, []),
              json_read_dict(Stream, Discovery),
              close(Stream)
          ),
          Discovery.runtimes = [Descriptor],
          assertion(Descriptor.id == "prolog-rlm")
        ),
        zara_runtime_server_stop
    ).

test(descriptor_is_backend_neutral_machine_contract) :-
    zara_runtime_descriptor(Descriptor),
    assertion(Descriptor.id == "prolog-rlm"),
    assertion(Descriptor.protocol == "ZARA-RUNTIME/1"),
    assertion(Descriptor.provenance == "prolog-rlm:local"),
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

test(completed_outcome_does_not_project_raw_runtime_result) :-
    Secret = "RAW-PROVIDER-SECRET-MUST-NOT-CROSS",
    Outcome = ok(_{
        response:_{
            text:"safe answer",
            provider_payload:_{authorization:Secret}
        }
    }),
    rlm_zara_runtime:project_outcome("redacted-complete", direct, Outcome, Reply),
    assertion(Reply.status == "completed"),
    assertion(Reply.text == "safe answer"),
    assertion(\+ get_dict(result, Reply, _)),
    term_string(Reply, Rendered),
    assertion(\+ sub_string(Rendered, _, _, _, Secret)).

test(failed_outcome_does_not_project_raw_runtime_error) :-
    Secret = "RAW-ERROR-SECRET-MUST-NOT-CROSS",
    Outcome = error(_{kind:provider_error, authorization:Secret}),
    rlm_zara_runtime:project_outcome("redacted-failure", direct, Outcome, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "runtime_error"),
    assertion(\+ get_dict(detail, Reply.error, _)),
    term_string(Reply, Rendered),
    assertion(\+ sub_string(Rendered, _, _, _, Secret)).

test(invalid_outcome_does_not_project_raw_runtime_payload) :-
    Secret = "RAW-INVALID-OUTCOME-SECRET-MUST-NOT-CROSS",
    Outcome = _{unexpected:_{provider_payload:_{authorization:Secret}}},
    rlm_zara_runtime:project_outcome("redacted-invalid", direct, Outcome, Reply),
    assertion(Reply.status == "failed"),
    assertion(Reply.error.kind == "runtime_error"),
    assertion(\+ get_dict(detail, Reply.error, _)),
    term_string(Reply, Rendered),
    assertion(\+ sub_string(Rendered, _, _, _, Secret)).

:- end_tests(rlm_zara_runtime).
