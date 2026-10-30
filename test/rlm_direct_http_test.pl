:- begin_tests(rlm_direct_http).

:- use_module(library(http/json)).
:- use_module('../prolog/rlm_direct').
:- use_module('../prolog/rlm_tool').
:- use_module('../prolog/rlm_authority').
:- use_module('../prolog/rlm_effect').
:- use_module('support/tool_effect_test_support').
:- use_module('support/scripted_http_support').

response(Text, Calls, Response) :-
    ( Calls == [] -> Finish = stop; Finish = tool_calls ),
    Response = _{id:"fixture-response", model:"fixture/model",
                 choices:[_{message:_{role:assistant,content:Text,
                                      tool_calls:Calls},finish_reason:Finish}],
                 usage:_{prompt_tokens:2,completion_tokens:1,total_tokens:3}}.

native_call(Id, Name, Args, Call) :-
    atom_json_dict(Atom, Args, [width(0)]),
    atom_string(Atom, Arguments),
    Call = _{id:Id,type:"function",
             function:_{name:Name,arguments:Arguments}}.

first_request(Body) :-
    Body.model == "fixture/model",
    last(Body.messages, User),
    User.role == "user",
    sub_string(User.content, _, _, _, "HTTP_FIXTURE_TASK").

declares_write(Body) :-
    first_request(Body),
    member(Tool, Body.tools), Tool.function.name == "counting_write",
    Tool.function.parameters.type == "object",
    Tool.function.parameters.required == ["value"],
    Tool.function.parameters.properties.value.type == "integer".

tool_observation(Id, Name, Body, Observation) :-
    append(_, [Assistant, Tool], Body.messages),
    Assistant.role == "assistant",
    Assistant.tool_calls = [Call], Call.id == Id,
    Call.function.name == Name,
    string(Call.function.arguments),
    Tool.role == "tool", Tool.tool_call_id == Id,
    atom_json_dict(Tool.content, Observation, []),
    Observation.call_id == Id, Observation.name == Name.

write_observation(Body) :-
    tool_observation("write_1", "counting_write", Body, Observation),
    Observation.value.id == "result_write_1",
    append(_, [Assistant, _], Body.messages),
    Assistant.tool_calls = [Call],
    atom_json_dict(Call.function.arguments, Args, []),
    Args.value =:= 37.

peek_observation(Body) :-
    tool_observation("peek_1", "context_peek", Body, Observation),
    Value = Observation.value,
    Value.seen =:= 37, Value.count =:= 1,
    findall(Id, (member(M,Body.messages), M.role == "tool", Id=M.tool_call_id),
            ["write_1","peek_1"]).

any_request(_).

reject_request(_) :- fail.

rejected_observation(Name, Kind, Body) :-
    tool_observation("bad_1", Name, Body, Observation),
    Observation.value.error == Kind.

hidden_write(Body) :-
    first_request(Body),
    \+ (member(Tool, Body.tools), Tool.function.name == "counting_write").

run_direct(Registry, Context, Extra, Expected, Provider) :-
    append(Extra,
           [provider(Provider),provider_name(openai_compatible),
            capabilities([tool(counting_write),context(peek)]),
            tool_registry(Registry),authority_context(Context),
            prompt_compile_mode(all_tools)], Options),
    rlm_direct("HTTP_FIXTURE_TASK", text("synthetic input"), Options, Outcome),
    ( Outcome = Expected -> true; throw(unexpected_direct_outcome(Outcome)) ).

setup_write(Registry, Context, File) :-
    tmp_file(http_fixture_effect, File),
    rlm_effect_store_open(File),
    reset_tool_mutations,
    tool_registry_create(Registry),
    write_schema(Schema),
    tool_register(Registry, Schema,
                  tool_effect_test_support:counting_write_tool, ok(_)),
    Context = session(http_fixture),
    rlm_set_authority(Context, allow_session, ok(_)).

cleanup_write(Registry, Context, File) :-
    tool_registry_destroy(Registry),
    rlm_authority_clear(Context),
    rlm_effect_store_close,
    delete_file(File),
    atom_concat(File, '.lock', Lock),
    ( exists_file(Lock) -> delete_file(Lock); true ),
    reset_tool_mutations.

test(text_only_uses_production_http) :-
    response("TEXT_DONE", [], Final),
    with_scripted_http([reply(plunit_rlm_direct_http:first_request,Final)],
        run_direct(none, session(http_text), [], ok(Result)), Requests),
    assertion(Result.value == "TEXT_DONE"),
    assertion(Result.turns =:= 1),
    assertion(Result.usage.total_tokens =:= 3),
    assertion(Requests = [request{index:1,path:'/v1/chat/completions',body:_}]).

test(approved_write_and_peek_round_trip_without_mocked_execution) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("write_1", "counting_write", _{value:37}, Write),
          native_call("peek_1", "context_peek",
                      _{context:"result_write_1",selector:_{type:"item",index:0}},
                      Peek),
          response("", [Write], First), response("", [Peek], Second),
          response("WRITE_DONE", [], Final),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:declares_write,First),
               reply(plunit_rlm_direct_http:write_observation,Second),
               reply(plunit_rlm_direct_http:peek_observation,Final)],
              run_direct(R,C,[],ok(Result)), Requests),
          assertion(Result.value == "WRITE_DONE"),
          assertion(Result.turns =:= 3),
          assertion(Result.tool_calls =:= 1),
          assertion(Result.context_calls =:= 1),
          assertion(Result.usage.total_tokens =:= 9),
          assertion(length(Requests,3)),
          tool_mutation_count(1), tool_last_value(37),
          member(Event, Result.trajectory), Event.type == native_tool,
          assertion(Event.trace.authorization == allowed), !
        ), cleanup_write(R,C,F)).

test(repeated_effect_cannot_mutate_twice) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("write_1", "counting_write", _{value:37}, A),
          native_call("write_2", "counting_write", _{value:37}, B),
          response("",[A],First), response("",[B],Second),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:declares_write,First),
               reply(plunit_rlm_direct_http:write_observation,Second)],
              run_direct(R,C,[],error(Error)), _),
          assertion(Error.kind == effectful_replay_denied),
          tool_mutation_count(1)
        ), cleanup_write(R,C,F)).

test(unapproved_write_stops_before_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( rlm_authority_clear(C),
          native_call("write_1", "counting_write", _{value:37}, Call),
          response("",[Call],First),
          with_scripted_http([reply(plunit_rlm_direct_http:declares_write,First)],
              run_direct(R,C,[],error(Error)), _),
          assertion(Error.kind == approval_required), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(zero_tool_budget_prevents_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("write_1", "counting_write", _{value:37}, Call),
          response("",[Call],First),
          with_scripted_http([reply(plunit_rlm_direct_http:declares_write,First)],
              run_direct(R,C,[budget(_{max_tool_calls:0})],error(Error)), _),
          assertion(Error.kind == tool_call_budget_exhausted), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(unknown_tool_returns_correlated_fault_without_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("bad_1", "not_registered", _{}, Call),
          response("",[Call],First), response("REJECTED",[],Final),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:first_request,First),
               reply(plunit_rlm_direct_http:rejected_observation(
                         "not_registered","unavailable_tool_schema"),Final)],
              run_direct(R,C,[],ok(Result)), _),
          assertion(Result.tool_calls =:= 0), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(capability_filters_schema_and_rejects_forged_call) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("bad_1", "counting_write", _{value:37}, Call),
          response("",[Call],First), response("REJECTED",[],Final),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:hidden_write,First),
               reply(plunit_rlm_direct_http:rejected_observation(
                         "counting_write","unavailable_tool_schema"),Final)],
              run_direct(R,C,[capabilities([context(peek)])],ok(Result)), _),
          assertion(Result.tool_calls =:= 0), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(malformed_arguments_are_returned_as_correlated_fault) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( Call = _{id:"bad_1",type:"function",
                   function:_{name:"counting_write",arguments:"{broken"}},
          response("",[Call],First), response("REJECTED",[],Final),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:declares_write,First),
               reply(plunit_rlm_direct_http:rejected_observation(
                         "counting_write","malformed_arguments"),Final)],
              run_direct(R,C,[],ok(Result)), _),
          assertion(Result.tool_calls =:= 0), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(invalid_call_id_rejects_text_and_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("bad id", "counting_write", _{value:37}, Call),
          response("MUST_NOT_SUCCEED",[Call],First),
          with_scripted_http([reply(plunit_rlm_direct_http:declares_write,First)],
              run_direct(R,C,[],error(Error)), _),
          assertion(Error.kind == malformed_call_id), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(schema_invalid_value_is_rejected_before_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("bad_1", "counting_write", _{value:"not an integer"}, Call),
          response("",[Call],First), response("REJECTED",[],Final),
          with_scripted_http(
              [reply(plunit_rlm_direct_http:declares_write,First),
               reply(plunit_rlm_direct_http:rejected_observation(
                         "counting_write","malformed_arguments"),Final)],
              run_direct(R,C,[],ok(Result)), _),
          assertion(Result.tool_calls =:= 0), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(duplicate_call_ids_reject_batch_before_effect) :-
    setup_call_cleanup(setup_write(R,C,F),
        ( native_call("dup_1", "counting_write", _{value:37}, Call),
          response("",[Call,Call],First),
          with_scripted_http([reply(plunit_rlm_direct_http:declares_write,First)],
              run_direct(R,C,[],error(Error)), _),
          assertion(Error.kind == duplicate_call_id), tool_mutation_count(Count), assertion(Count =:= 0)
        ), cleanup_write(R,C,F)).

test(http_errors_are_bounded_without_implicit_retry,
     [forall(member(Status,[429,503]))]) :-
    with_scripted_http([http_error(Status)],
        run_direct(none,session(http_error),[],error(Error)), Requests),
    assertion(Error.kind == provider_failed),
    assertion(Error.cause.http_status =:= Status),
    assertion(length(Requests,1)).

test(server_expectation_failure_reaches_test_thread,
     [throws(request_mismatch(1,_))]) :-
    response("unused",[],Final),
    with_scripted_http([reply(plunit_rlm_direct_http:reject_request,Final)],
        run_direct(none,session(http_fault),[],error(_)), _).

test(counter_fixture_cannot_report_zero_after_mutation,
     [setup(reset_tool_mutations),cleanup(reset_tool_mutations)]) :-
    counting_write_tool(_{value:37}, _),
    tool_mutation_count(Count),
    assertion(Count =:= 1),
    assertion(\+ tool_mutation_count(0)).

:- end_tests(rlm_direct_http).
