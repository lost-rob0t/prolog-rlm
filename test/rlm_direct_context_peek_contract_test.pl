:- begin_tests(rlm_direct_context_peek_contract).

:- use_module('../prolog/rlm_direct').

test(head_accepts_shared_schema_index_field) :-
    rlm_direct:context_arguments(
        context(peek),
        _{context:"input",
          selector:_{type:"head", count:20, index:0}},
        Args),
    assertion(Args.context == "input"),
    assertion(Args.selector == head(20)).

test(tail_accepts_shared_schema_index_field) :-
    rlm_direct:context_arguments(
        context(peek),
        _{context:"input",
          selector:_{type:"tail", count:20, index:0}},
        Args),
    assertion(Args.selector == tail(20)).

test(metadata_accepts_shared_schema_count_and_index_fields) :-
    rlm_direct:context_arguments(
        context(peek),
        _{context:"input",
          selector:_{type:"metadata", count:1, index:0}},
        Args),
    assertion(Args.selector == metadata).

test(item_accepts_shared_schema_count_field) :-
    rlm_direct:context_arguments(
        context(peek),
        _{context:"input",
          selector:_{type:"item", count:1, index:0}},
        Args),
    assertion(Args.selector == item(0)).


% --- Issue #312: projected schema and native validation share one contract ---

test(peek_schema_advertises_flat_permissive_selector_contract) :-
    rlm_direct:context_schema(peek, Schema),
    Parameters = Schema.parameters,
    get_dict(selector, Parameters.properties, SelectorSchema),
    assertion(SelectorSchema.type == "object"),
    assertion(get_dict(type, SelectorSchema.properties, _)),
    assertion(get_dict(index, SelectorSchema.properties, _)),
    assertion(get_dict(count, SelectorSchema.properties, _)),
    assertion(SelectorSchema.required == ["type"]),
    assertion(SelectorSchema.additionalProperties == false),
    assertion(Parameters.required == ["selector"]),
    assertion(Parameters.additionalProperties == false).

field_probe_value(index, 0).
field_probe_value(count, 1).

test(advertised_selector_fields_are_accepted_for_every_type) :-
    forall(( member(Type, ["metadata", "head", "tail", "item"]),
             member(Field, [index, count]) ),
           ( field_probe_value(Field, Value),
             put_dict(Field, _{type:Type}, Value, Selector),
             rlm_direct:context_arguments(context(peek),
                                          _{context:"input",
                                            selector:Selector},
                                          _Args)
           )).

test(unknown_selector_field_is_rejected_by_validator_and_schema) :-
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input",
                    selector:_{type:"head", count:20, cursor:1}},
                  _),
            fail
          ),
          direct_fault(Error),
          ( assertion(Error.kind == malformed_arguments),
            assertion(Error.detail == unexpected_fields([cursor])) )).

test(head_count_defaults_to_bounded_whole_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"head"}}, Args),
    rlm_direct:peek_default_count(Default),
    assertion(Args.selector == head(Default)).

test(tail_count_defaults_to_bounded_whole_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"tail"}}, Args),
    rlm_direct:peek_default_count(Default),
    assertion(Args.selector == tail(Default)).

test(item_index_defaults_to_zero_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"item"}}, Args),
    assertion(Args.selector == item(0)).

test(metadata_count_must_satisfy_advertised_minimum) :-
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input",
                    selector:_{type:"metadata", count:0}},
                  _),
            fail
          ),
          direct_fault(Error),
          ( assertion(Error.kind == malformed_arguments),
            assertion(Error.detail == invalid_positive_integer(count)) )).

test(item_count_must_satisfy_advertised_minimum) :-
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input",
                    selector:_{type:"item", count:0, index:0}},
                  _),
            fail
          ),
          direct_fault(Error),
          ( assertion(Error.kind == malformed_arguments),
            assertion(Error.detail == invalid_positive_integer(count)) )).

test(head_index_must_satisfy_advertised_minimum) :-
    NegIndex is -1,
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input",
                    selector:_{type:"head", count:1, index:NegIndex}},
                  _),
            fail
          ),
          direct_fault(Error),
          ( assertion(Error.kind == malformed_arguments),
            assertion(Error.detail == invalid_nonnegative_integer(index)) )).

:- end_tests(rlm_direct_context_peek_contract).
