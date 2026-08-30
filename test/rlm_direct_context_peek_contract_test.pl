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

:- end_tests(rlm_direct_context_peek_contract).
