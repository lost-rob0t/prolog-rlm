:- module(rlm_mcp_tool,
          [ mcp_import_tools/5,
            mcp_import_state_destroy/1
          ]).

/** <module> MCP tool import adapter

Import is explicit and requires an already connected MCP client. It never starts
or installs a server and never grants capabilities. Each remote tool is
registered in rlm_tool under a deterministic namespaced local atom and therefore
passes through the ordinary capability gate, schema validation, time/output
limits and canonical async invocation path exactly once.

The imported handler calls rlm_mcp's canonical command execute ABI directly.
That is deliberate: tool handlers already run inside an rlm_async worker, so
submitting a second Future and waiting on it would recreate the nested-wait bug
fixed by the canonical async architecture.
*/

:- use_module(library(gensym)).
:- use_module(rlm_mcp, []).
:- use_module(rlm_tool, []).

:- dynamic imported_client_state/3.

mcp_import_tools(Registry, Server, Client0, Options, Outcome) :-
    catch(mcp_import_tools_(Registry, Server, Client0, Options, Outcome),
          Exception,
          import_exception(Exception, Outcome)).

mcp_import_tools_(Registry, Server, Client0, Options, Outcome) :-
    require_server_name(Server),
    rlm_mcp:mcp_client_command(Client0,
                               list_tools,
                               Client,
                               ListOutcome),
    import_after_list(ListOutcome,
                      Registry,
                      Server,
                      Client,
                      Options,
                      Outcome).

import_after_list(error(Error), _, _, _, _, error(Error)) :- !.
import_after_list(ok(Page), Registry, Server, Client, Options, Outcome) :-
    get_dict(tools, Page, Tools),
    gensym(mcp_import_, StateId),
    assertz(imported_client_state(StateId, Server, Client)),
    catch(register_imported_tools(Tools,
                                  Registry,
                                  Server,
                                  StateId,
                                  Options,
                                  Imported,
                                  RegisterOutcome),
          Exception,
          ( retractall(imported_client_state(StateId, _, _)),
            throw(Exception)
          )),
    finish_import(RegisterOutcome, StateId, Server, Imported, Outcome).

finish_import(ok, StateId, Server, Imported,
              ok(mcp_tool_import{
                     server:Server,
                     state:mcp_import_state(StateId),
                     tools:Imported
                 })) :- !.
finish_import(error(Error), StateId, _, _, error(Error)) :-
    retractall(imported_client_state(StateId, _, _)).

register_imported_tools([], _, _, _, _, [], ok).
register_imported_tools([Tool|Tools], Registry, Server, StateId, Options,
                        [Imported|ImportedTools], Outcome) :-
    imported_schema(Server, Tool, Options, Schema, LocalName, RemoteName),
    Handler = rlm_mcp_tool:imported_tool_handler(StateId, RemoteName),
    rlm_tool:tool_register(Registry, Schema, Handler, RegisterOutcome),
    register_after_one(RegisterOutcome,
                       Tools,
                       Registry,
                       Server,
                       StateId,
                       Options,
                       LocalName,
                       RemoteName,
                       Imported,
                       ImportedTools,
                       Outcome).

register_after_one(error(Error), _, _, _, _, _, _, _, _, [], error(Error)) :- !.
register_after_one(ok(_), Tools, Registry, Server, StateId, Options,
                   LocalName, RemoteName,
                   mcp_imported_tool{local_name:LocalName,
                                     remote_name:RemoteName,
                                     capability:tool(LocalName)},
                   ImportedTools,
                   Outcome) :-
    register_imported_tools(Tools,
                            Registry,
                            Server,
                            StateId,
                            Options,
                            ImportedTools,
                            Outcome).

imported_schema(Server, Tool, Options, Schema, LocalName, RemoteName) :-
    Remote0 = Tool.name,
    text_atom(Remote0, RemoteName),
    namespaced_tool_name(Server, RemoteName, LocalName),
    mcp_input_schema(Tool, ArgumentSchema),
    option_number(time_limit, Options, 30.0, TimeLimit),
    option_integer(max_output_bytes, Options, 65536, MaxOutputBytes),
    tool_description(Tool, Description),
    Schema = tool_schema{
                 name:LocalName,
                 description:Description,
                 capability:tool(LocalName),
                 arguments:ArgumentSchema,
                 result:_{type:any},
                 limits:_{time_limit:TimeLimit,
                          max_output_bytes:MaxOutputBytes}
             }.

namespaced_tool_name(Server, RemoteName, LocalName) :-
    format(atom(LocalName), 'mcp.~w.~w', [Server, RemoteName]).

tool_description(Tool, Description) :-
    (   get_dict(description, Tool, Value), Value \== null
    ->  text_string(Value, Description)
    ;   Description = "Imported MCP tool"
    ).

mcp_input_schema(Tool, Schema) :-
    (   get_dict(input_schema, Tool, Raw), is_dict(Raw)
    ->  mcp_schema(Raw, Schema)
    ;   Schema = _{type:object}
    ).

mcp_schema(Raw, Schema) :-
    schema_type(Raw, Type),
    mcp_schema_type(Type, Raw, Schema).

schema_type(Raw, Type) :-
    (   get_dict(type, Raw, RawType)
    ->  normalize_schema_type(RawType, Type)
    ;   Type = any
    ).

normalize_schema_type(Value, Type) :-
    text_atom(Value, Atom),
    schema_type_atom(Atom, Type),
    !.
normalize_schema_type(_, any).

schema_type_atom(object, object).
schema_type_atom(array, list).
schema_type_atom(string, string).
schema_type_atom(integer, integer).
schema_type_atom(number, number).
schema_type_atom(boolean, boolean).
schema_type_atom(any, any).

mcp_schema_type(object, Raw, Schema) :-
    !,
    object_properties(Raw, Properties),
    object_required(Raw, Required),
    object_additional(Raw, Additional),
    Schema = _{type:object,
               properties:Properties,
               required:Required,
               additional_properties:Additional}.
mcp_schema_type(list, Raw, Schema) :-
    !,
    (   get_dict(items, Raw, Items), is_dict(Items)
    ->  mcp_schema(Items, ItemSchema),
        Schema = _{type:list, items:ItemSchema}
    ;   Schema = _{type:list}
    ).
mcp_schema_type(Type, _, _{type:Type}).

object_properties(Raw, Properties) :-
    (   get_dict(properties, Raw, RawProperties), is_dict(RawProperties)
    ->  dict_pairs(RawProperties, _, Pairs0),
        maplist(convert_property, Pairs0, Pairs),
        dict_pairs(Properties, tool_properties, Pairs)
    ;   Properties = tool_properties{}
    ).

convert_property(Key-Raw, Key-Schema) :-
    (   is_dict(Raw)
    ->  mcp_schema(Raw, Schema)
    ;   Schema = _{type:any}
    ).

object_required(Raw, Required) :-
    (   get_dict(required, Raw, Values), is_list(Values)
    ->  maplist(text_atom, Values, Required)
    ;   Required = []
    ).

object_additional(Raw, false) :-
    ( get_dict(additionalProperties, Raw, false)
    ; get_dict(additional_properties, Raw, false)
    ),
    !.
object_additional(_, true).

imported_tool_handler(StateId, RemoteName, Args, Value) :-
    with_mutex(StateId,
               imported_tool_command(StateId, RemoteName, Args, Value)).

imported_tool_command(StateId, RemoteName, Args, Value) :-
    imported_client_state(StateId, Server, Client0),
    rlm_mcp:mcp_client_command_execute(Client0,
                                        call_tool(RemoteName, Args),
                                        Result),
    update_imported_client(StateId, Server, Client0, Result),
    imported_command_value(Result, Value).

update_imported_client(StateId, Server, _, Result) :-
    is_dict(Result, mcp_command_async_result),
    !,
    retractall(imported_client_state(StateId, _, _)),
    assertz(imported_client_state(StateId, Server, Result.client)).
update_imported_client(_, _, _, _).

imported_command_value(Result, Value) :-
    is_dict(Result, mcp_command_async_result),
    Result.outcome = ok(Value),
    !.
imported_command_value(Result, _) :-
    (   is_dict(Result, mcp_command_async_result)
    ->  Error = Result.outcome
    ;   Error = Result
    ),
    throw(error(rlm_mcp_imported_tool(Error), _)).

mcp_import_state_destroy(mcp_import_state(StateId)) :-
    retractall(imported_client_state(StateId, _, _)).

require_server_name(Server) :-
    atom(Server),
    Server \== '',
    !.
require_server_name(Server) :-
    throw(error(type_error(mcp_server_name, Server), _)).

option_number(Name, Options, Default, Value) :-
    option_value(Name, Options, Default, Found),
    number(Found),
    Found > 0,
    !,
    Value = Found.
option_number(Name, _, _, _) :-
    throw(error(domain_error(positive_number_option, Name), _)).

option_integer(Name, Options, Default, Value) :-
    option_value(Name, Options, Default, Found),
    integer(Found),
    Found > 0,
    !,
    Value = Found.
option_integer(Name, _, _, _) :-
    throw(error(domain_error(positive_integer_option, Name), _)).

option_value(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

text_atom(Value, Value) :- atom(Value), !.
text_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
text_atom(Value, _) :- throw(error(type_error(text, Value), _)).

text_string(Value, Value) :- string(Value), !.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).
text_string(Value, _) :- throw(error(type_error(text, Value), _)).

import_exception(Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
import_exception(Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_tool_import_error{
                kind:import_exception,
                exception:Safe,
                message:"MCP tool import failed"
            }.

control_exception(rlm_async_cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).
control_exception(cancelled(_)).
control_exception('$aborted').
control_exception(abort).
