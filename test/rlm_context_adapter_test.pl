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

test(anonymous_adapter_data_is_canonicalized_before_storage_and_output) :-
    setup_call_cleanup(
        register_canonical_adapter,
        canonical_adapter_case,
        cleanup_canonical_adapter).

canonical_adapter_case :-
    context_adapter_info(canonical_external, ok(AdapterInfo)),
    assertion(ground(AdapterInfo.capabilities)),
    assertion(is_dict(AdapterInfo.capabilities, rlm_anonymous_dict)),
    context_register_adapter(canonical_external,
                             _{id:7},
                             [],
                             ok(Ref)),
    assertion(ground(Ref)),
    assertion(Ref.metadata.source.source ==
              rlm_anonymous_dict{id:7}),
    get_dict(handle, Ref, Handle),
    context_search(Handle, "needle", [], ok(Result)),
    assertion(Result.value ==
              [rlm_anonymous_dict{source:rlm_anonymous_dict{id:7}}]),
    context_delete(Handle, ok(_)).

test(variable_and_cyclic_adapter_capabilities_fail_closed) :-
    VariableCapabilities = _{operations:[search], value:_},
    context_adapter_register(variable_capabilities,
                             VariableCapabilities,
                             plunit_rlm_context_adapter:canonical_metadata,
                             plunit_rlm_context_adapter:canonical_operation,
                             error(VariableError)),
    assertion(VariableError.kind == invalid_adapter),
    CyclicCapabilities = _{operations:[search], self:CyclicCapabilities},
    context_adapter_register(cyclic_capabilities,
                             CyclicCapabilities,
                             plunit_rlm_context_adapter:canonical_metadata,
                             plunit_rlm_context_adapter:canonical_operation,
                             error(CyclicError)),
    assertion(CyclicError.kind == invalid_adapter).

test(variable_and_cyclic_adapter_source_refs_fail_closed) :-
    setup_call_cleanup(
        register_canonical_adapter,
        ( context_register_adapter(canonical_external,
                                   _{id:_},
                                   [],
                                   error(VariableError)),
          assertion(VariableError.kind == invalid_adapter_source),
          CyclicSource = _{self:CyclicSource},
          context_register_adapter(canonical_external,
                                   CyclicSource,
                                   [],
                                   error(CyclicError)),
          assertion(CyclicError.kind == invalid_adapter_source)
        ),
        cleanup_canonical_adapter).

test(variable_and_cyclic_adapter_metadata_fail_closed) :-
    setup_call_cleanup(
        register_invalid_metadata_adapter,
        ( context_register_adapter(invalid_metadata,
                                   variable,
                                   [],
                                   error(VariableError)),
          assertion(VariableError.kind == invalid_adapter_metadata),
          context_register_adapter(invalid_metadata,
                                   cyclic,
                                   [],
                                   error(CyclicError)),
          assertion(CyclicError.kind == invalid_adapter_metadata)
        ),
        cleanup_invalid_metadata_adapter).

test(variable_and_cyclic_adapter_work_values_fail_closed) :-
    setup_call_cleanup(
        register_invalid_work_adapter,
        invalid_work_case,
        cleanup_invalid_work_adapter).

invalid_work_case :-
    context_register_adapter(invalid_work, variable, [], ok(VariableRef)),
    context_search(VariableRef.handle, "needle", [], error(VariableError)),
    assertion(VariableError.kind == invalid_adapter_work),
    context_delete(VariableRef.handle, ok(_)),
    context_register_adapter(invalid_work, cyclic, [], ok(CyclicRef)),
    context_search(CyclicRef.handle, "needle", [], error(CyclicError)),
    assertion(CyclicError.kind == invalid_adapter_work),
    context_delete(CyclicRef.handle, ok(_)).

register_canonical_adapter :-
    Capabilities = _{source_kinds:[canonical_external],
                     operations:[search],
                     persistent:false,
                     filesystem:false,
                     network:false},
    context_adapter_register(
        canonical_external,
        Capabilities,
        plunit_rlm_context_adapter:canonical_metadata,
        plunit_rlm_context_adapter:canonical_operation,
        ok(_)).

cleanup_canonical_adapter :-
    catch(context_adapter_unregister(canonical_external, _), _, true).

canonical_metadata(Source,
                   _{kind:canonical_external,
                     bytes:unknown,
                     items:1,
                     source:Source}).

canonical_operation(search(_), Source, _Limits,
                    _{value:[_{source:Source}],
                      bytes_inspected:1,
                      items_inspected:1,
                      truncated:false}).

register_invalid_metadata_adapter :-
    context_adapter_register(
        invalid_metadata,
        capabilities{operations:[search]},
        plunit_rlm_context_adapter:invalid_metadata,
        plunit_rlm_context_adapter:canonical_operation,
        ok(_)).

cleanup_invalid_metadata_adapter :-
    catch(context_adapter_unregister(invalid_metadata, _), _, true).

invalid_metadata(variable, _{kind:invalid_metadata, value:_}).
invalid_metadata(cyclic, Metadata) :-
    Metadata = _{kind:invalid_metadata, self:Metadata}.

register_invalid_work_adapter :-
    context_adapter_register(
        invalid_work,
        capabilities{operations:[search]},
        plunit_rlm_context_adapter:canonical_metadata,
        plunit_rlm_context_adapter:invalid_work,
        ok(_)).

cleanup_invalid_work_adapter :-
    catch(context_adapter_unregister(invalid_work, _), _, true).

invalid_work(search(_), variable, _Limits,
             work{value:_{item:_},
                  bytes_inspected:1,
                  items_inspected:1,
                  truncated:false}).
invalid_work(search(_), cyclic, _Limits, Work) :-
    Value = _{self:Value},
    Work = work{value:Value,
                bytes_inspected:1,
                items_inspected:1,
                truncated:false}.

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
