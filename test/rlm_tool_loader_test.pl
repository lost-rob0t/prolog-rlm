:- begin_tests(rlm_tool_loader).

:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_tool_loader').

:- multifile rlm_tool_loader:tool_pack/2.

rlm_tool_loader:tool_pack(
    fixture_pack,
    plunit_rlm_tool_loader:load_fixture_pack).

load_fixture_pack(Registry, Outcome) :-
    fixture_schema(Schema),
    tool_register(Registry,
                  Schema,
                  plunit_rlm_tool_loader:fixture_handler,
                  RegisterOutcome),
    (   RegisterOutcome = ok(_)
    ->  Outcome = ok(tool_pack{pack:fixture_pack,
                               registered:[fixture_pack_echo]})
    ;   Outcome = RegisterOutcome
    ).

fixture_schema(
    tool_schema{
        name:fixture_pack_echo,
        description:"external tool-pack loading fixture",
        capability:tool(fixture_pack_echo),
        effect:read,
        arguments:_{type:object,
                    required:[value],
                    additional_properties:false,
                    properties:_{value:_{type:integer}}},
        result:_{type:integer},
        limits:_{time_limit:1.0, max_output_bytes:1024}
    }).

fixture_handler(Args, Value) :-
    Value = Args.value.

test(pack_discovery_is_immediate_and_declarative) :-
    rlm_tool_packs(Packs),
    assertion(memberchk(fixture_pack, Packs)).

test(unknown_pack_fails_closed) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( rlm_load_tools(Registry, definitely_missing_pack, error(Error)),
          assertion(Error.kind == unknown_tool_pack)
        ),
        tool_registry_destroy(Registry)).

test(loading_registers_tools_but_grants_no_capability) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( rlm_load_tools(Registry, fixture_pack, ok(_)),
          tool_lookup(Registry, fixture_pack_echo, ok(_)),
          tool_invoke(Registry,
                      [],
                      fixture_pack_echo,
                      _{value:7},
                      [],
                      error(Error),
                      Trace),
          assertion(Error.kind == capability_denied),
          assertion(Trace.authorization == denied)
        ),
        tool_registry_destroy(Registry)).

test(explicit_capability_allows_loaded_tool) :-
    setup_call_cleanup(
        tool_registry_create(Registry),
        ( rlm_load_tools(Registry, fixture_pack, ok(_)),
          tool_invoke(Registry,
                      [tool(fixture_pack_echo)],
                      fixture_pack_echo,
                      _{value:9},
                      [],
                      ok(Execution),
                      Trace),
          assertion(Execution.value =:= 9),
          assertion(Trace.authorization == allowed)
        ),
        tool_registry_destroy(Registry)).

:- end_tests(rlm_tool_loader).