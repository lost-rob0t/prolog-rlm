:- begin_tests(rlm_symbolic_tool).

:- use_module('../prolog/rlm_symbolic_tool').
:- use_module('../prolog/rlm_tool').

symbolic_schema(
    tool_schema{name:education_discount,
                description:"pure symbolic education discount",
                capability:tool(education_discount),
                effect:read,
                arguments:_{type:object,
                            required:[segment],
                            additional_properties:false,
                            properties:_{segment:_{type:string}}},
                result:_{type:object,
                         required:[discount],
                         additional_properties:false,
                         properties:_{discount:_{type:number}}},
                limits:_{time_limit:1.0,
                         max_output_bytes:1024}}).

education_program(
    symbolic_program(
        [rule(eq(field(segment), const("edu")),
              json{discount:0.30})],
        json{discount:0.0})).

test(program_validates_as_closed_data) :-
    education_program(Program),
    symbolic_program_validate(Program, ok(Program)).

test(symbolic_tool_registers_and_invokes_through_canonical_tool_runtime) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( symbolic_schema(Schema),
          education_program(Program),
          symbolic_tool_register(Registry, Schema, Program, [], ok(_)),
          tool_invoke(Registry,
                      [tool(education_discount)],
                      education_discount,
                      json{segment:"edu"},
                      [],
                      ok(Execution),
                      Trace),
          assertion(Execution.value.discount =:= 0.30),
          assertion(Trace.authorization == allowed),
          assertion(Trace.status == ok)
        ),
        tool_registry_destroy(Registry)).

test(default_branch_is_used_when_no_rule_matches) :-
    education_program(Program),
    symbolic_eval(Program,
                  json{segment:"commercial"},
                  ok(Result)),
    assertion(Result.discount =:= 0.0).

test(template_expressions_can_reuse_argument_values) :-
    Program = symbolic_program(
                  [],
                  json{charge:expr(mul(field(units), field(rate)))}),
    symbolic_eval(Program,
                  json{units:25, rate:0.4},
                  ok(Result)),
    assertion(Result.charge =:= 10.0).

test(effectful_schema_is_rejected_before_registry_registration) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( symbolic_schema(ReadSchema),
          put_dict(effect, ReadSchema, write, WriteSchema),
          education_program(Program),
          symbolic_tool_register(Registry,
                                 WriteSchema,
                                 Program,
                                 [],
                                 error(Error)),
          assertion(Error.kind == invalid_symbolic_program)
        ),
        tool_registry_destroy(Registry)).

test(arbitrary_callable_condition_is_rejected) :-
    symbolic_program_validate(
        symbolic_program([rule(call(shell), json{ok:true})],
                         json{ok:false}),
        error(Error)),
    assertion(Error.kind == invalid_symbolic_program).

:- end_tests(rlm_symbolic_tool).
