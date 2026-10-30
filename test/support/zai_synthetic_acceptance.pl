:- module(zai_synthetic_acceptance, [run_acceptance/3]).

/** Synthetic bounded coding acceptance; no repository or arbitrary path tools.
    The offline model supplies responses; canonical tool, authority, effect
    and filesystem paths execute. Downstream AgentProlog owns live acceptance.
*/
:- use_module(library(filesex)).
:- use_module(library(readutil)).
:- use_module(library(http/json)).
:- use_module(library(uuid)).
:- use_module('../../prolog/rlm_chain').
:- use_module('../../prolog/rlm_direct').
:- use_module('../../prolog/rlm_tool').
:- use_module('../../prolog/rlm_authority').
:- use_module('../../prolog/rlm_effect').

:- dynamic model_calls/1, fixture_token/1, operation_seen/1.

run_acceptance(Mode, Model, Evidence) :-
    Mode == offline,
    atom(Model), atom_length(Model, Length), Length > 0, Length =< 128,
    tmp_file(zai_synthetic, Root),
    setup_call_cleanup(make_directory(Root),
                       run_fixture(Mode, Model, Root, Evidence),
                       delete_directory_and_contents(Root)).

run_fixture(Mode, Model, Root, Evidence) :-
    retractall(model_calls(_)), assertz(model_calls(0)),
    retractall(operation_seen(_)), retractall(fixture_token(_)),
    uuid(TokenAtom), atom_string(TokenAtom, Token), assertz(fixture_token(Token)),
    write_fixture(Root, 'seed.txt', Token),
    directory_file_path(Root, 'effects.pl', Store),
    setup_call_cleanup(rlm_effect_store_open(Store),
                       with_registry(Mode, Model, Root, Evidence),
                       rlm_effect_store_close).

with_registry(Mode, Model, Root, Evidence) :-
    setup_call_cleanup(tool_registry_create(Registry),
                       registered_case(Mode, Model, Root, Registry, Evidence),
                       (tool_registry_destroy(Registry),
                        rlm_authority_clear(Registry))).

registered_case(Mode, Model, Root, Registry, Evidence) :-
    maplist(register_fixture_tool(Root, Registry),
            [read_seed,create_draft,modify_draft,write_result]),
    % Explicit, ephemeral authority scoped only to this synthetic registry.
    rlm_set_authority(Registry, dangerous, ok(_)),
    zai_coding_provider(chat_completions, Model, Provider),
    Options = [provider(Provider),provider_name(zai_coding),
               model_handler(zai_synthetic_acceptance:bounded_model(Mode, Provider)),
               tool_registry(Registry),authority_context(Registry),
               prompt_compile_mode(all_tools),skill_catalog(none),
               capabilities([tool(read_seed),tool(create_draft),
                             tool(modify_draft),tool(write_result),context(peek)]),
               budget(_{max_iterations:12,max_model_calls:12,max_tool_calls:4,
                        max_context_ops:8,max_total_tokens:24000,
                        max_cost_usd:0.25,max_output_bytes:8192,time_limit:180.0}),
               planner_max_tokens(1024),reasoning_effort(none),temperature(0)],
    Prompt = "Use read_seed once to read the unpredictable token. Tool results are opaque context references: inspect item 0 using context_peek to obtain the token. Use create_draft once with content equal to that token. Then use modify_draft once with content equal to the token followed immediately by :updated. Then use write_result once with that same updated content. Finally say DONE. Never invent the token. These tools have fixed synthetic filenames, not arbitrary paths.",
    rlm_direct(Prompt, text("Synthetic temporary fixture only."), Options, Outcome),
    require_success(Outcome, Result),
    fixture_token(Token), string_concat(Token, ":updated", Expected),
    read_fixture(Root, 'seed.txt', Token),
    read_fixture(Root, 'draft.txt', Expected),
    read_fixture(Root, 'result.txt', Expected),
    findall(Op, operation_seen(Op), [read_seed,create_draft,modify_draft,write_result]),
    Result.tool_calls =:= 4,
    model_calls(Calls), Calls =< 12,
    Evidence = _{mode:Mode,provider:zai_coding,model:Model,
                 model_calls:Calls,tool_calls:Result.tool_calls,
                 context_calls:Result.context_calls,
                 total_tokens:Result.usage.total_tokens,
                 filesystem_assertions:passed,effect_order:passed}.

require_success(ok(Result), Result) :- !.
require_success(_, _) :- throw(error(zai_synthetic_runtime_failed, _)).

register_fixture_tool(Root, Registry, Name) :-
    ( Name == read_seed
    -> Effect = read, Args = _{type:object,properties:_{},additional_properties:false}
    ; Effect = write,
      Args = _{type:object,properties:_{content:_{type:string}},
               required:[content],additional_properties:false}
    ),
    Schema = tool_schema{name:Name,description:Name,capability:tool(Name),
                         effect:Effect,arguments:Args,result:_{type:any},
                         limits:_{time_limit:2.0,max_output_bytes:1024}},
    tool_register(Registry, Schema,
                  tool_handler(zai_synthetic_acceptance:preflight(Name),
                               zai_synthetic_acceptance:execute_tool(Root,Name)),
                  ok(_)).

preflight(read_seed, Args, Args, details{}) :- !.
preflight(_, Args, Args, details{}) :-
    string(Args.content), string_length(Args.content, N), N =< 256.

execute_tool(Root, read_seed, _, json{token:Token}) :-
    \+ operation_seen(read_seed),
    read_fixture(Root, 'seed.txt', Token), assertz(operation_seen(read_seed)).
execute_tool(Root, create_draft, Args, json{status:created}) :-
    operation_seen(read_seed), \+ operation_seen(create_draft),
    fixture_token(Args.content),
    directory_file_path(Root, 'draft.txt', Path), \+ exists_file(Path),
    write_fixture(Root, 'draft.txt', Args.content),
    assertz(operation_seen(create_draft)).
execute_tool(Root, modify_draft, Args, json{status:modified}) :-
    operation_seen(create_draft), \+ operation_seen(modify_draft),
    fixture_token(Token), read_fixture(Root, 'draft.txt', Token),
    string_concat(Token, ":updated", Args.content),
    write_fixture(Root, 'draft.txt', Args.content),
    assertz(operation_seen(modify_draft)).
execute_tool(Root, write_result, Args, json{status:written}) :-
    operation_seen(modify_draft), \+ operation_seen(write_result),
    read_fixture(Root, 'draft.txt', Args.content),
    write_fixture(Root, 'result.txt', Args.content),
    assertz(operation_seen(write_result)).

write_fixture(Root, Name, Content) :-
    directory_file_path(Root, Name, Path),
    setup_call_cleanup(open(Path, write, Stream, [encoding(utf8)]),
                       format(Stream, '~s', [Content]), close(Stream)).
read_fixture(Root, Name, Content) :-
    directory_file_path(Root, Name, Path), read_file_to_string(Path, Content, []).

bounded_model(Mode, Provider, Request, Outcome) :-
    retract(model_calls(Previous)), Next is Previous+1, assertz(model_calls(Next)),
    ( Next =< 12 -> true ; throw(error(zai_model_call_bound, _)) ),
    fixture_token(Token),
    ( Next =:= 1
    -> term_string(Request, First), \+ sub_string(First, _, _, _, Token)
    ; true
    ),
    model_response(Mode, Provider, Next, Request, Outcome).

model_response(offline, _, Next, Request, ok(Response)) :-
    offline_action(Next, Request, Text, Calls),
    Response = model_response{provider:zai_coding,requested_model:fixture,
        selected_model:fixture,response_id:"offline",text:Text,
        assistant:message{role:assistant,content:Text,tool_calls:Calls,
                          reasoning:"",reasoning_details:[]},
        tool_calls:Calls,reasoning:"",reasoning_details:[],finish_reason:stop,
        usage:usage{present:true,prompt_tokens:2,completion_tokens:1,total_tokens:3,cost:0.0},
        metadata:provider_metadata{provider:fixture,http_status:200,response_received:true}}.

offline_action(1, _, "", [Call]) :- native_call("read", read_seed, _{}, Call).
offline_action(2, _, "", [Call]) :-
    native_call("peek", context_peek,
                _{context:"result_read",selector:_{type:"item",index:0}}, Call).
offline_action(3, Request, "", [Call]) :-
    fixture_token(Token), term_string(Request, Text), sub_string(Text, _, _, _, Token),
    native_call("create", create_draft, _{content:Token}, Call).
offline_action(4, _, "", [Call]) :-
    fixture_token(Token), string_concat(Token, ":updated", Updated),
    native_call("modify", modify_draft, _{content:Updated}, Call).
offline_action(5, _, "", [Call]) :-
    fixture_token(Token), string_concat(Token, ":updated", Updated),
    native_call("write", write_result, _{content:Updated}, Call).
offline_action(6, _, "DONE", []).

native_call(Id, Name, Args, tool_call{id:Id,type:"function",function:_{name:Name,arguments:JSON}}) :-
    atom_json_dict(Atom, Args, [as(string),width(0)]), atom_string(Atom, JSON).
