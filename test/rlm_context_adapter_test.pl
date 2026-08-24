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
    get_dict(handle, Ref, Handle),
    context_search(Handle,
                   "needle",
                   [max_results(1), max_bytes(4096)],
                   ok(Result)),
    get_dict(truncated, Result, true),
    get_dict(value, Result, Value),
    assertion(Value == [json{id:1, text:"needle one"}]),
    context_delete(Handle, ok(_)).

test(oversized_adapter_metadata_is_rejected_before_handle_exposure) :-
    setup_call_cleanup(
        register_fake_adapter,
        oversized_adapter_metadata_case,
        cleanup_fake_adapter).

oversized_adapter_metadata_case :-
    context_register_adapter(fake_external,
                             fake_source,
                             [max_bytes(512)],
                             ok(SafeRef)),
    get_dict(handle, SafeRef, SafeHandle),
    context_delete(SafeHandle, ok(_)),
    context_register_adapter(fake_external,
                             oversized_source,
                             [max_bytes(512)],
                             error(Error)),
    get_dict(kind, Error, ErrorKind),
    assertion(ErrorKind == adapter_metadata_too_large),
    get_dict(bytes, Error, Bytes),
    get_dict(max_bytes, Error, MaxBytes),
    assertion(MaxBytes == 512),
    assertion(Bytes > MaxBytes),
    context_adapter_unregister(fake_external,
                               ok(unregistered(fake_external))),
    register_fake_adapter.

test(live_handle_prevents_adapter_unregistration) :-
    setup_call_cleanup(
        register_fake_adapter,
        adapter_in_use_case,
        cleanup_fake_adapter).

adapter_in_use_case :-
    context_register_adapter(fake_external, fake_source, [], ok(Ref)),
    context_adapter_unregister(fake_external, error(Error)),
    get_dict(kind, Error, ErrorKind),
    assertion(ErrorKind == adapter_in_use),
    get_dict(handle, Ref, Handle),
    context_delete(Handle, ok(_)),
    context_adapter_unregister(fake_external, ok(unregistered(fake_external))),
    register_fake_adapter.

test(adapter_capability_declaration_blocks_undeclared_operation) :-
    setup_call_cleanup(
        register_fake_adapter,
        adapter_capability_case,
        cleanup_fake_adapter).

adapter_capability_case :-
    context_register_adapter(fake_external, fake_source, [], ok(Ref)),
    get_dict(handle, Ref, Handle),
    context_slice(Handle, 0, 1, [], error(Error)),
    get_dict(kind, Error, ErrorKind),
    assertion(ErrorKind == capability_denied),
    context_delete(Handle, ok(_)).

test(ordinary_context_registration_cannot_install_adapter_callbacks) :-
    context_register(adapter(fake_external, fake_source),
                     [],
                     error(Error)),
    get_dict(kind, Error, ErrorKind),
    assertion(ErrorKind == unsupported_source).

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
              json{kind:fake_external,
                bytes:unknown,
                items:3,
                source_id:test}).
fake_metadata(oversized_source, Metadata) :-
    length(Chars, 4096),
    maplist(=('x'), Chars),
    string_chars(Payload, Chars),
    Metadata = json{kind:fake_external,
                 bytes:unknown,
                 items:1,
                 source_payload:Payload}.

fake_operation(search(_),
               fake_source,
               _Limits,
               work{value:[json{id:1, text:"needle one"},
                           json{id:2, text:"needle two"},
                           json{id:3, text:"needle three"}],
                    bytes_inspected:36,
                    items_inspected:3,
                    truncated:false}).
fake_operation(peek(head(_)),
               fake_source,
               _Limits,
               work{value:[json{id:1, text:"one"}],
                    bytes_inspected:3,
                    items_inspected:1,
                    truncated:false}).

:- end_tests(rlm_context_adapter).
