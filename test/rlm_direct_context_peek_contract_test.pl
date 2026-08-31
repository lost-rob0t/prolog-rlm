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


% --- Issue #312: one authoritative context_peek selector contract ----------
%
% The projected tool schema (context_schema(peek, ...) below) and native
% argument validation (peek_selector/2) must derive from the same contract
% facts in prolog/rlm_direct.pl: only `type` is required, `index` and
% `count` are optional shared fields with advertised minima (index >= 0,
% count >= 1), unknown selector fields fail closed, and omitted values fall
% back to the bounded native defaults. The tests below pin the advertised
% contract and probe native validation from the projected schema itself, so
% schema/validator drift fails this gate instead of diverging at runtime.

% Selector boundary matrix: every selector type accepts its advertised
% boundaries and rejects advertised violations.

selector_accept(metadata, _{type:"metadata", index:0}).
selector_accept(metadata, _{type:"metadata", count:1}).
selector_accept(metadata, _{type:"metadata", index:0, count:1}).
selector_accept(head, _{type:"head", index:0, count:1}).
selector_accept(tail, _{type:"tail", index:0, count:1}).
selector_accept(item, _{type:"item", index:0, count:1}).
selector_accept(metadata, _{type:"metadata"}).
selector_accept(head, _{type:"head"}).
selector_accept(tail, _{type:"tail"}).
selector_accept(item, _{type:"item"}).

selector_reject(metadata, _{type:"metadata", index: -1},
                invalid_selector_field(index, 0)).
selector_reject(metadata, _{type:"metadata", count:0},
                invalid_selector_field(count, 1)).
selector_reject(head, _{type:"head", index: -1, count:1},
                invalid_selector_field(index, 0)).
selector_reject(head, _{type:"head", index:0, count:0},
                invalid_selector_field(count, 1)).
selector_reject(tail, _{type:"tail", index: -1, count:1},
                invalid_selector_field(index, 0)).
selector_reject(tail, _{type:"tail", index:0, count:0},
                invalid_selector_field(count, 1)).
selector_reject(item, _{type:"item", index: -1},
                invalid_selector_field(index, 0)).
selector_reject(item, _{type:"item", count:0},
                invalid_selector_field(count, 1)).

selector_outcome(Selector, ok) :-
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input", selector:Selector}, _Args),
            true
          ),
          direct_fault(_), fail).
selector_outcome(Selector, fault(Kind, Detail)) :-
    catch(( rlm_direct:context_arguments(context(peek),
                  _{context:"input", selector:Selector}, _Args),
            false
          ),
          direct_fault(Error),
          ( Kind = Error.kind, Detail = Error.detail )).

test(selector_accepts_advertised_boundary,
     [forall(selector_accept(Type, Selector))]) :-
    assertion(selector_outcome(Selector, ok)).

test(selector_rejects_advertised_violation,
     [forall(selector_reject(Type, Selector, Detail))]) :-
    assertion(selector_outcome(Selector, fault(malformed_arguments, Detail))).

% Fail-closed regressions for selector shapes outside the advertised
% contract, including wrong primitive types.

test(unknown_selector_type_fails_closed) :-
    assertion(selector_outcome(_{type:"slice"},
                               fault(malformed_arguments,
                                     unsupported_selector))).

test(selector_type_must_be_text) :-
    assertion(selector_outcome(_{type:5},
                               fault(malformed_arguments,
                                     unsupported_selector))).

test(unknown_selector_field_fails_closed) :-
    assertion(selector_outcome(_{type:"head", count:1, cursor:1},
                               fault(malformed_arguments,
                                     unexpected_fields([cursor])))).

test(missing_required_selector_type_fails_closed) :-
    assertion(selector_outcome(_{count:1},
                               fault(malformed_arguments,
                                     invalid_selector))).

test(non_dict_selector_fails_closed) :-
    assertion(selector_outcome("head",
                               fault(malformed_arguments,
                                     invalid_selector))).

test(selector_count_must_be_an_integer) :-
    assertion(selector_outcome(_{type:"head", count:"20"},
                               fault(malformed_arguments,
                                     invalid_selector_field(count, 1)))).

% Bounded native defaults for omitted optional fields.

test(head_count_defaults_to_bounded_whole_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"head"}}, Args),
    assertion(Args.selector == head(128)).

test(tail_count_defaults_to_bounded_whole_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"tail"}}, Args),
    assertion(Args.selector == tail(128)).

test(head_default_count_coexists_with_validated_index) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"head", index:0}}, Args),
    assertion(Args.selector == head(128)).

test(tail_default_count_coexists_with_validated_index) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"tail", index:0}}, Args),
    assertion(Args.selector == tail(128)).

test(item_index_defaults_to_zero_when_omitted) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"item"}}, Args),
    assertion(Args.selector == item(0)).

test(item_default_index_coexists_with_validated_count) :-
    rlm_direct:context_arguments(context(peek),
        _{context:"input", selector:_{type:"item", count:1}}, Args),
    assertion(Args.selector == item(0)).

test(peek_default_count_is_the_bounded_whole) :-
    rlm_direct:peek_default_count(128).

% Schema/validator conformance: the projected selector schema must be
% exactly the authoritative contract, and native validation must enforce
% every advertised field, minimum, and enum value.

peek_schema(SelectorSchema) :-
    rlm_direct:context_schema(peek, Schema),
    get_dict(selector, Schema.parameters.properties, SelectorSchema).

pair_key(Key-_, Key).

test(projected_selector_schema_advertises_the_authoritative_contract) :-
    rlm_direct:context_schema(peek, Schema),
    Parameters = Schema.parameters,
    assertion(Parameters.required == ["selector"]),
    assertion(Parameters.additionalProperties == false),
    peek_schema(SelectorSchema),
    assertion(SelectorSchema.type == "object"),
    assertion(SelectorSchema.required == ["type"]),
    assertion(SelectorSchema.additionalProperties == false),
    rlm_direct:peek_selector_types(Types),
    maplist(atom_string, Types, EnumStrings),
    get_dict(type, SelectorSchema.properties, TypeSchema),
    assertion(TypeSchema.type == "string"),
    assertion(TypeSchema.enum == EnumStrings),
    forall(rlm_direct:peek_selector_minimum(Field, Minimum),
           ( get_dict(Field, SelectorSchema.properties, FieldSchema),
             assertion(FieldSchema.type == "integer"),
             assertion(FieldSchema.minimum == Minimum) )).

test(advertised_selector_types_are_the_documented_set) :-
    peek_schema(SelectorSchema),
    get_dict(type, SelectorSchema.properties, TypeSchema),
    assertion(TypeSchema.enum == ["metadata", "head", "tail", "item"]).

test(advertised_field_minima_are_the_documented_bounds) :-
    peek_schema(SelectorSchema),
    get_dict(index, SelectorSchema.properties, IndexSchema),
    get_dict(count, SelectorSchema.properties, CountSchema),
    assertion(IndexSchema.minimum == 0),
    assertion(CountSchema.minimum == 1).

test(validator_selector_fields_equal_projected_schema_fields) :-
    peek_schema(SelectorSchema),
    dict_pairs(SelectorSchema.properties, json, Pairs),
    maplist(pair_key, Pairs, SchemaKeys),
    sort(SchemaKeys, SortedSchemaKeys),
    rlm_direct:peek_selector_fields(Fields),
    sort(Fields, SortedFields),
    assertion(SortedSchemaKeys == SortedFields).

test(every_advertised_selector_type_is_natively_accepted) :-
    peek_schema(SelectorSchema),
    get_dict(type, SelectorSchema.properties, TypeSchema),
    forall(member(Type, TypeSchema.enum),
           ( put_dict(type, _{}, Type, Selector),
             assertion(selector_outcome(Selector, ok)) )).

test(every_advertised_field_bound_is_natively_enforced) :-
    peek_schema(SelectorSchema),
    dict_pairs(SelectorSchema.properties, json, FieldPairs),
    get_dict(type, SelectorSchema.properties, TypeSchema),
    forall( ( member(Field-FieldSchema, FieldPairs),
              dif(Field, type),
              member(Type, TypeSchema.enum) ),
            ( get_dict(minimum, FieldSchema, Minimum),
              Boundary is Minimum - 1,
              put_dict(Field, _{type:Type}, Minimum, MinSelector),
              put_dict(Field, _{type:Type}, Boundary, BadSelector),
              assertion(selector_outcome(MinSelector, ok)),
              assertion(\+ selector_outcome(BadSelector, ok)) )).

test(boundary_faults_carry_the_advertised_minimum) :-
    peek_schema(SelectorSchema),
    dict_pairs(SelectorSchema.properties, json, FieldPairs),
    get_dict(type, SelectorSchema.properties, TypeSchema),
    forall( ( member(Field-FieldSchema, FieldPairs),
              dif(Field, type),
              member(Type, TypeSchema.enum) ),
            ( get_dict(minimum, FieldSchema, Minimum),
              Boundary is Minimum - 1,
              put_dict(Field, _{type:Type}, Boundary, BadSelector),
              assertion(selector_outcome(BadSelector,
                                         fault(malformed_arguments,
                                               invalid_selector_field(Field,
                                                                      Minimum)))) )).

:- end_tests(rlm_direct_context_peek_contract).
