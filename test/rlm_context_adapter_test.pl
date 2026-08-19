:- begin_tests(rlm_context_adapter).

:- use_module('../prolog/rlm_context').

test(adapter_output_is_rebounded_by_core_limits) :-
    setup_call_cleanup(
        register_fake_adapter,
        adapter_rebound_case,
        cleanup_fake_adapter).

adapter_rebound_case :-
    context_register_adapter(fake_external,
                             fake_source,
                             [],
                             ok(Ref)),
    context_search(Ref.handle,
                   "needle",
                   [max_results(1), max_bytes(4096)],
                   ok(Result)),
    assertion(Result.truncated == true),
    assertion(Result.value == [_{id:1, text:"needle one"}]),
    context_delete(Ref.handle, ok(_)).

test(live_handle_prevents_adapter_unregistration) :-
    setup_call_cleanup(
        register_fake_adapter,
        adapter_in_use_case,
        cleanup_fake_adapter).

adapter_in_use_case :-
    context_register_adapter(fake_external, fake_source, [], ok(Ref)),
    context_adapter_unregister(fake_external, error(Error)),
    assertion(Error.kind == adapter_in_use),
    context_delete(Ref.handle, ok(_)),
    context_adapter_unregister(fake_external, ok(unregistered(fake_external))),
    register_fake_adapter.

test(adapter_capability_declaration_blocks_undeclared_operation) :-
    setup_call_cleanup(
        register_fake_adapter,
        adapter_capability_case,
        cleanup_fake_adapter).

adapter_capability_case :-
    context_register_adapter(fake_external, fake_source, [], ok(Ref)),
    context_slice(Ref.handle, 0, 1, [], error(Error)),
    assertion(Error.kind == capability_denied),
    context_delete(Ref.handle, ok(_)).

test(ordinary_context_registration_cannot_install_adapter_callbacks) :-
    context_register(adapter(fake_external, fake_source),
                     [],
                     error(Error)),
    assertion(Error.kind == unsupported_source).

register_fake_adapter :-
    Capabilities = capabilities{source_kinds:[fake_external],
                                operations:[peek,search],
                                persistent:false,
                                filesystem:false,
                                network:false},
    context_adapter_register(
        fake_external,
        Capabilities,
        plunit_rlm_context_adapter:fake_metadata,
        plunit_rlm_context_adapter:fake_operation,
        Outcome),
    assertion(Outcome = ok(_)).

cleanup_fake_adapter :-
    catch(context_adapter_unregister(fake_external, _), _, true).

fake_metadata(fake_source,
              _{kind:fake_external,
                bytes:unknown,
                items:3,
                source_id:test}).

fake_operation(search(_),
               fake_source,
               _Limits,
               work{value:[_{id:1, text:"needle one"},
                           _{id:2, text:"needle two"},
                           _{id:3, text:"needle three"}],
                    bytes_inspected:36,
                    items_inspected:3,
                    truncated:false}).
fake_operation(peek(head(_)),
               fake_source,
               _Limits,
               work{value:[_{id:1, text:"one"}],
                    bytes_inspected:3,
                    items_inspected:1,
                    truncated:false}).

:- end_tests(rlm_context_adapter).
