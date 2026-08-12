:- module(rlm_tool,
          [ tool_registry_create/1,
            tool_registry_destroy/1,
            tool_register/4,
            tool_discover/2,
            tool_lookup/3,
            tool_invoke/7,
            tool_registry_runtime_tools/3,
            capabilities_normalize/2,
            capability_allowed/2,
            capabilities_narrow/3,
            register_project_read_tool/4
          ]).

/** <module> Capability-gated tool registry

Trusted host code registers handlers and schemas. Model-selected plans may name
registered tools, but model data never becomes a callable. Invocation performs
capability authorization, schema validation, wall-time enforcement, normalized
result validation, and output-byte enforcement before returning a value.
*/

:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(readutil)).
:- use_module(library(time)).

:- dynamic tool_registry_alive/1.
:- dynamic tool_registry_entry/4.

/* -------------------------------------------------------------------------
 * Capability model
 * ---------------------------------------------------------------------- */

capabilities_normalize(Capabilities, Outcome) :-
    catch(( must_be_capability_list(Capabilities),
            maplist(must_be_capability, Capabilities),
            sort(Capabilities, Normalized),
            Outcome = ok(Normalized)
          ),
          Exception,
          capability_exception(Exception, Outcome)).

capability_allowed(Capabilities, Capability) :-
    capabilities_normalize(Capabilities, ok(Normalized)),
    must_be_capability(Capability),
    memberchk(Capability, Normalized).

capabilities_narrow(Parent, Requested, Outcome) :-
    capabilities_normalize(Parent, ParentOutcome),
    capabilities_narrow_parent(ParentOutcome, Requested, Outcome).

capabilities_narrow_parent(error(Error), _, error(Error)) :- !.
capabilities_narrow_parent(ok(Parent), Requested, Outcome) :-
    capabilities_normalize(Requested, RequestedOutcome),
    capabilities_narrow_requested(RequestedOutcome, Parent, Outcome).

capabilities_narrow_requested(error(Error), _, error(Error)) :- !.
capabilities_narrow_requested(ok(Requested), Parent, Outcome) :-
    findall(Cap,
            ( member(Cap, Requested),
              \+ memberchk(Cap, Parent)
            ),
            Widening),
    (   Widening == []
    ->  Outcome = ok(Requested)
    ;   Outcome = error(capability_error{kind:widening_denied,
                                         requested:Requested,
                                         parent:Parent,
                                         unauthorized:Widening,
                                         message:"child capabilities must be a subset of parent capabilities"})
    ).

must_be_capability_list(Value) :-
    is_list(Value),
    !.
must_be_capability_list(Value) :-
    throw(capability_fault(invalid_capability_list(Value))).

must_be_capability(Capability) :-
    capability_shape(Capability),
    !.
must_be_capability(Capability) :-
    throw(capability_fault(invalid_capability(Capability))).

capability_shape(rlm).
capability_shape(parallel).
capability_shape(retry).
capability_shape(checkpoint).
capability_shape(tool(Name)) :- capability_name(Name).
capability_shape(context(Name)) :- capability_name(Name).
capability_shape(model(Name)) :- capability_name(Name).
capability_shape(graph(Name)) :- capability_name(Name).
capability_shape(persistence(Name)) :- capability_name(Name).
capability_shape(network(Name)) :- capability_name(Name).
capability_shape(filesystem(Name)) :- capability_name(Name).
capability_shape(process(Name)) :- capability_name(Name).
capability_shape(mcp(Name)) :- capability_name(Name).

capability_name(Name) :-
    atom(Name),
    Name \== ''.

capability_exception(capability_fault(Fault), error(Error)) :-
    !,
    Error = capability_error{kind:invalid_capabilities,
                             detail:Fault,
                             message:"capability set is invalid"}.
capability_exception(Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = capability_error{kind:capability_error,
                             exception:Safe,
                             message:"capability processing failed"}.

/* -------------------------------------------------------------------------
 * Registry
 * ---------------------------------------------------------------------- */

tool_registry_create(tool_registry(Id)) :-
    with_mutex(rlm_tool_registry,
               ( gensym(registry_, Id),
                 assertz(tool_registry_alive(Id))
               )).

tool_registry_destroy(tool_registry(Id)) :-
    with_mutex(rlm_tool_registry,
               ( retractall(tool_registry_entry(Id, _, _, _)),
                 retractall(tool_registry_alive(Id))
               )).

tool_register(Registry, Schema0, Handler, Outcome) :-
    catch(tool_register_(Registry, Schema0, Handler, Outcome),
          Exception,
          tool_api_exception(register, Exception, Outcome)).

tool_register_(Registry, Schema0, Handler, Outcome) :-
    registry_id(Registry, Id),
    normalize_tool_schema(Schema0, Schema),
    callable(Handler),
    !,
    Name = Schema.name,
    with_mutex(rlm_tool_registry,
               register_unique(Id, Name, Schema, Handler, Outcome)).
tool_register_(_, _, Handler,
               error(tool_error{phase:register,
                                kind:invalid_handler,
                                handler_shape:Shape,
                                message:"tool handler must be a trusted callable"})) :-
    value_shape(Handler, Shape).

register_unique(Id, Name, _, _,
                error(tool_error{phase:register,
                                 kind:duplicate_tool,
                                 tool:Name,
                                 message:"tool name is already registered"})) :-
    tool_registry_entry(Id, Name, _, _),
    !.
register_unique(Id, Name, Schema, Handler, ok(Schema)) :-
    assertz(tool_registry_entry(Id, Name, Schema, Handler)).

tool_discover(Registry, Schemas) :-
    registry_id(Registry, Id),
    findall(Schema,
            tool_registry_entry(Id, _, Schema, _),
            Schemas0),
    sort(2, @=<, Schemas0, Schemas).

tool_lookup(Registry, Name, Outcome) :-
    catch(tool_lookup_(Registry, Name, Outcome),
          Exception,
          tool_api_exception(lookup, Exception, Outcome)).

tool_lookup_(Registry, Name, Outcome) :-
    registry_id(Registry, Id),
    (   tool_registry_entry(Id, Name, Schema, _)
    ->  Outcome = ok(Schema)
    ;   Outcome = error(tool_error{phase:lookup,
                                   kind:unknown_tool,
                                   tool:Name,
                                   message:"tool is not registered"})
    ).

/* -------------------------------------------------------------------------
 * Invocation
 * ---------------------------------------------------------------------- */

tool_invoke(Registry, Capabilities, Name, Args, Options, Outcome, Trace) :-
    get_time(Start),
    catch(tool_invoke_(Registry, Capabilities, Name, Args, Options,
                       CoreOutcome, Auth, Status, Bytes),
          Exception,
          invoke_exception(Exception, CoreOutcome, Auth, Status, Bytes)),
    get_time(End),
    ElapsedMs is round((End-Start)*1000),
    Trace = tool_trace{tool:Name,
                       authorization:Auth,
                       status:Status,
                       output_bytes:Bytes,
                       elapsed_ms:ElapsedMs},
    attach_trace(CoreOutcome, Trace, Outcome).

tool_invoke_(Registry, Capabilities, Name, Args, Options,
             Outcome, Authorization, Status, Bytes) :-
    registry_entry(Registry, Name, Schema, Handler, LookupOutcome),
    invoke_after_lookup(LookupOutcome, Schema, Handler, Capabilities, Args,
                        Options, Outcome, Authorization, Status, Bytes).

registry_entry(Registry, Name, Schema, Handler, Outcome) :-
    registry_id(Registry, Id),
    (   tool_registry_entry(Id, Name, Schema0, Handler0)
    ->  Schema = Schema0,
        Handler = Handler0,
        Outcome = ok
    ;   Outcome = error(tool_error{phase:lookup,
                                   kind:unknown_tool,
                                   tool:Name,
                                   message:"tool is not registered"})
    ).

invoke_after_lookup(error(Error), _, _, _, _, _, error(Error),
                    denied, unknown_tool, 0) :- !.
invoke_after_lookup(ok, Schema, Handler, Capabilities, Args, Options,
                    Outcome, Authorization, Status, Bytes) :-
    Capability = Schema.capability,
    (   capability_allowed(Capabilities, Capability)
    ->  Authorization = allowed,
        invoke_authorized(Schema, Handler, Args, Options,
                          Outcome, Status, Bytes)
    ;   Authorization = denied,
        Status = capability_denied,
        Bytes = 0,
        Outcome = error(tool_error{phase:authorize,
                                   kind:capability_denied,
                                   tool:Schema.name,
                                   capability:Capability,
                                   message:"tool capability was not granted"})
    ).

invoke_authorized(Schema, Handler, Args, Options, Outcome, Status, Bytes) :-
    validate_schema(Schema.arguments, Args, args, ArgsOutcome),
    invoke_after_args(ArgsOutcome, Schema, Handler, Args, Options,
                      Outcome, Status, Bytes).

invoke_after_args(error(Error), _, _, _, _, error(Error), malformed_args, 0) :- !.
invoke_after_args(ok, Schema, Handler, Args, Options, Outcome, Status, Bytes) :-
    effective_limits(Schema.limits, Options, Limits),
    call_tool_with_limit(Handler, Args, Limits.time_limit, CallOutcome),
    invoke_after_call(CallOutcome, Schema, Limits, Outcome, Status, Bytes).

call_tool_with_limit(Handler, Args, TimeLimit, Outcome) :-
    catch(call_with_time_limit(TimeLimit,
                               ( call(Handler, Args, Value)
                               -> Outcome = ok(Value)
                               ;  Outcome = error(tool_error{phase:invoke,
                                                             kind:handler_failed,
                                                             message:"tool handler failed without returning a value"})
                               )),
          Exception,
          timed_tool_exception(Exception, Outcome)).

timed_tool_exception(time_limit_exceeded,
                     error(tool_error{phase:invoke,
                                      kind:timeout,
                                      message:"tool invocation exceeded its wall-time limit"})) :- !.
timed_tool_exception(time_limit_exceeded(_),
                     error(tool_error{phase:invoke,
                                      kind:timeout,
                                      message:"tool invocation exceeded its wall-time limit"})) :- !.
timed_tool_exception(Exception,
                     error(tool_error{phase:invoke,
                                      kind:handler_exception,
                                      exception:Safe,
                                      message:"tool handler raised an exception"})) :-
    safe_exception(Exception, Safe).

invoke_after_call(error(Error), _, _, error(Error), Status, 0) :-
    !,
    error_status(Error, Status).
invoke_after_call(ok(Value), Schema, Limits, Outcome, Status, Bytes) :-
    validate_schema(Schema.result, Value, result, ResultOutcome),
    invoke_after_result(ResultOutcome, Value, Schema, Limits,
                        Outcome, Status, Bytes).

invoke_after_result(error(Error), _, _, _, error(Error), invalid_result, 0) :- !.
invoke_after_result(ok, Value, Schema, Limits, Outcome, Status, Bytes) :-
    value_bytes(Value, Bytes0),
    (   Bytes0 =< Limits.max_output_bytes
    ->  Bytes = Bytes0,
        Status = ok,
        Outcome = ok(Value)
    ;   Bytes = Bytes0,
        Status = oversized_output,
        Outcome = error(tool_error{phase:normalize,
                                   kind:oversized_output,
                                   tool:Schema.name,
                                   output_bytes:Bytes0,
                                   limit:Limits.max_output_bytes,
                                   message:"tool output exceeds its byte limit"})
    ).

error_status(Error, Status) :-
    (   is_dict(Error), get_dict(kind, Error, Kind)
    ->  Status = Kind
    ;   Status = error
    ).

attach_trace(ok(Value), Trace,
             ok(tool_execution{value:Value, trace:Trace})) :- !.
attach_trace(error(Error0), Trace, error(Error)) :-
    (   is_dict(Error0)
    ->  put_dict(trace, Error0, Trace, Error)
    ;   Error = tool_error{phase:invoke,
                           kind:tool_error,
                           cause:Error0,
                           trace:Trace,
                           message:"tool invocation failed"}
    ).

/* -------------------------------------------------------------------------
 * Plan-runtime adapter
 * ---------------------------------------------------------------------- */

tool_registry_runtime_tools(Registry, Capabilities, Tools) :-
    registry_id(Registry, Id),
    findall(tool(Name,
                 rlm_tool:registry_plan_handler(Registry,
                                                Capabilities,
                                                Name)),
            tool_registry_entry(Id, Name, _, _),
            Tools).

registry_plan_handler(Registry, Capabilities, Name, Args, Envelope) :-
    tool_invoke(Registry, Capabilities, Name, Args, [], Outcome, Trace),
    (   Outcome = ok(Execution)
    ->  Envelope = tool_result{value:Execution.value,
                               authorization:Trace.authorization,
                               status:Trace.status,
                               output_bytes:Trace.output_bytes,
                               elapsed_ms:Trace.elapsed_ms}
    ;   Outcome = error(Error),
        throw(error(rlm_tool(Error), _))
    ).

/* -------------------------------------------------------------------------
 * Built-in read-only project tool
 * ---------------------------------------------------------------------- */

register_project_read_tool(Registry, Root0, Options, Outcome) :-
    catch(register_project_read_tool_(Registry, Root0, Options, Outcome),
          Exception,
          tool_api_exception(register_project_read, Exception, Outcome)).

register_project_read_tool_(Registry, Root0, Options, Outcome) :-
    normalize_root(Root0, Root),
    option_value(max_file_bytes, Options, 8192, MaxFileBytes),
    option_value(time_limit, Options, 1.0, TimeLimit),
    require_positive_integer(MaxFileBytes, max_file_bytes),
    require_positive_number(TimeLimit, time_limit),
    project_read_schema(MaxFileBytes, TimeLimit, Schema),
    Handler = rlm_tool:project_read_handler(Root, MaxFileBytes),
    tool_register(Registry, Schema, Handler, Outcome).

project_read_schema(MaxBytes, TimeLimit,
                    tool_schema{name:project_read,
                                description:"Read one UTF-8 regular file beneath an explicitly registered project root",
                                capability:tool(project_read),
                                arguments:_{type:object,
                                            required:[path],
                                            additional_properties:false,
                                            properties:_{path:_{type:string}}},
                                result:_{type:object,
                                         required:[path,content,bytes,truncated],
                                         additional_properties:false,
                                         properties:_{path:_{type:string},
                                                      content:_{type:string},
                                                      bytes:_{type:integer},
                                                      truncated:_{type:boolean}}},
                                limits:tool_limits{time_limit:TimeLimit,
                                                   max_output_bytes:MaxBytes}}).

project_read_handler(Root, MaxFileBytes, Args, Result) :-
    get_dict(path, Args, Path0),
    text_string(Path0, Relative),
    safe_relative_path(Relative, Segments),
    reject_symlink_components(Root, Segments),
    absolute_file_name(Relative,
                       Absolute,
                       [ relative_to(Root),
                         access(read),
                         file_type(regular),
                         file_errors(fail),
                         solutions(first)
                       ]),
    path_within_root(Root, Absolute),
    size_file(Absolute, Size),
    Size =< MaxFileBytes,
    setup_call_cleanup(open(Absolute, read, Stream, [encoding(utf8)]),
                       read_string(Stream, _, Content),
                       close(Stream)),
    Result = json{path:Relative,
                  content:Content,
                  bytes:Size,
                  truncated:false}.

normalize_root(Root0, Root) :-
    absolute_file_name(Root0,
                       Root0Abs,
                       [ file_type(directory),
                         access(read),
                         file_errors(fail),
                         solutions(first)
                       ]),
    strip_trailing_slash(Root0Abs, Root).

safe_relative_path(Path, Segments) :-
    string(Path),
    Path \== "",
    \+ sub_string(Path, 0, 1, _, "/"),
    \+ sub_string(Path, _, _, _, "\\"),
    \+ sub_string(Path, _, _, _, "\u0000"),
    split_string(Path, "/", "", Segments),
    Segments \== [],
    maplist(safe_path_segment, Segments).

safe_path_segment(Segment) :-
    Segment \== "",
    Segment \== ".",
    Segment \== "..".

reject_symlink_components(Root, Segments) :-
    reject_symlink_components_(Segments, Root).

reject_symlink_components_([], _).
reject_symlink_components_([Segment|Segments], Parent) :-
    atom_string(SegmentAtom, Segment),
    directory_file_path(Parent, SegmentAtom, Candidate),
    \+ read_link(Candidate, _, _),
    reject_symlink_components_(Segments, Candidate).

path_within_root(Root, Absolute) :-
    atom_concat(Root, '/', Prefix),
    sub_atom(Absolute, 0, _, _, Prefix).

strip_trailing_slash('/', '/') :- !.
strip_trailing_slash(Path0, Path) :-
    (   atom_concat(Path, '/', Path0), Path \== ''
    ->  true
    ;   Path = Path0
    ).

/* -------------------------------------------------------------------------
 * Schema validation
 * ---------------------------------------------------------------------- */

normalize_tool_schema(Schema0, Schema) :-
    is_dict(Schema0),
    require_schema_key(Schema0, name, Name),
    atom(Name),
    require_schema_key(Schema0, capability, Capability),
    must_be_capability(Capability),
    Capability == tool(Name),
    require_schema_key(Schema0, arguments, Arguments),
    require_schema_key(Schema0, result, Result),
    validate_schema_definition(Arguments),
    validate_schema_definition(Result),
    schema_description(Schema0, Description),
    schema_limits(Schema0, Limits),
    Schema = tool_schema{name:Name,
                         description:Description,
                         capability:Capability,
                         arguments:Arguments,
                         result:Result,
                         limits:Limits}.

schema_description(Schema, Description) :-
    (   get_dict(description, Schema, Value), text_string(Value, Text)
    ->  Description = Text
    ;   Description = ""
    ).

schema_limits(Schema, Limits) :-
    (   get_dict(limits, Schema, Limits0)
    ->  true
    ;   Limits0 = _{}
    ),
    limit_value(time_limit, Limits0, 1.0, TimeLimit),
    limit_value(max_output_bytes, Limits0, 4096, MaxBytes),
    require_positive_number(TimeLimit, time_limit),
    require_positive_integer(MaxBytes, max_output_bytes),
    Limits = tool_limits{time_limit:TimeLimit,
                         max_output_bytes:MaxBytes}.

validate_schema_definition(Schema) :-
    is_dict(Schema),
    get_dict(type, Schema, Type),
    memberchk(Type, [any,string,integer,number,boolean,list,object]),
    !,
    validate_schema_definition_type(Type, Schema).
validate_schema_definition(Schema) :-
    throw(tool_fault(invalid_schema(Schema))).

validate_schema_definition_type(object, Schema) :-
    !,
    (   get_dict(properties, Schema, Properties)
    ->  is_dict(Properties),
        dict_pairs(Properties, _, Pairs),
        maplist(validate_property_schema, Pairs)
    ;   true
    ),
    (   get_dict(required, Schema, Required)
    ->  is_list(Required), maplist(atom, Required)
    ;   true
    ).
validate_schema_definition_type(list, Schema) :-
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_schema_definition(ItemSchema)
    ;   true
    ).
validate_schema_definition_type(_, _).

validate_property_schema(_-Schema) :-
    validate_schema_definition(Schema).

validate_schema(Schema, Value, Path, Outcome) :-
    catch(( validate_schema_value(Schema, Value, Path), Outcome = ok ),
          tool_fault(Fault),
          schema_fault(Path, Fault, Outcome)).

validate_schema_value(Schema, Value, Path) :-
    get_dict(type, Schema, Type),
    validate_type(Type, Schema, Value, Path).

validate_type(any, _, _, _) :- !.
validate_type(string, _, Value, _) :- text_string(Value, _), !.
validate_type(integer, _, Value, _) :- integer(Value), !.
validate_type(number, _, Value, _) :- number(Value), !.
validate_type(boolean, _, Value, _) :- memberchk(Value, [true,false]), !.
validate_type(list, Schema, Value, Path) :-
    is_list(Value),
    !,
    (   get_dict(items, Schema, ItemSchema)
    ->  validate_list_items(Value, ItemSchema, Path, 0)
    ;   true
    ).
validate_type(object, Schema, Value, Path) :-
    is_dict(Value),
    !,
    validate_object(Schema, Value, Path).
validate_type(Type, _, Value, Path) :-
    throw(tool_fault(schema_type_mismatch(Path, Type, Value))).

validate_list_items([], _, _, _).
validate_list_items([Value|Values], Schema, Path, Index) :-
    validate_schema_value(Schema, Value, Path-Index),
    Next is Index+1,
    validate_list_items(Values, Schema, Path, Next).

validate_object(Schema, Value, Path) :-
    (   get_dict(required, Schema, Required)
    ->  maplist(require_object_key(Value, Path), Required)
    ;   true
    ),
    (   get_dict(properties, Schema, Properties)
    ->  validate_object_properties(Properties, Value, Path),
        validate_additional_properties(Schema, Properties, Value, Path)
    ;   true
    ).

require_object_key(Value, Path, Key) :-
    (   get_dict(Key, Value, _)
    ->  true
    ;   throw(tool_fault(missing_required_field(Path, Key)))
    ).

validate_object_properties(Properties, Value, Path) :-
    dict_pairs(Properties, _, Pairs),
    maplist(validate_present_property(Value, Path), Pairs).

validate_present_property(Value, Path, Key-Schema) :-
    (   get_dict(Key, Value, FieldValue)
    ->  validate_schema_value(Schema, FieldValue, Path-Key)
    ;   true
    ).

validate_additional_properties(Schema, Properties, Value, Path) :-
    (   get_dict(additional_properties, Schema, false)
    ->  dict_keys(Properties, Allowed),
        dict_keys(Value, Actual),
        subtract(Actual, Allowed, Extra),
        (   Extra == []
        ->  true
        ;   throw(tool_fault(unexpected_fields(Path, Extra)))
        )
    ;   true
    ).

schema_fault(Path, Fault,
             error(tool_error{phase:schema,
                              kind:schema_validation_failed,
                              path:Path,
                              detail:Fault,
                              message:"tool value does not match its declared schema"})).

/* -------------------------------------------------------------------------
 * Helpers
 * ---------------------------------------------------------------------- */

registry_id(tool_registry(Id), Id) :-
    tool_registry_alive(Id),
    !.
registry_id(Registry, _) :-
    throw(tool_fault(invalid_or_stale_registry(Registry))).

require_schema_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(tool_fault(missing_schema_field(Key)))
    ).

effective_limits(Spec, Options,
                 tool_limits{time_limit:TimeLimit,
                             max_output_bytes:MaxBytes}) :-
    option_value(time_limit, Options, Spec.time_limit, RequestedTime),
    option_value(max_output_bytes, Options, Spec.max_output_bytes,
                 RequestedBytes),
    require_positive_number(RequestedTime, time_limit),
    require_positive_integer(RequestedBytes, max_output_bytes),
    TimeLimit is min(Spec.time_limit, RequestedTime),
    MaxBytes is min(Spec.max_output_bytes, RequestedBytes).

limit_value(Key, Dict, Default, Value) :-
    (   is_dict(Dict), get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

option_value(Name, Options, Default, Value) :-
    (   is_list(Options),
        member(Option, Options),
        Option =.. [Name, Found]
    ->  Value = Found
    ;   Value = Default
    ).

require_positive_integer(Value, _) :-
    integer(Value), Value > 0,
    !.
require_positive_integer(Value, Field) :-
    throw(tool_fault(invalid_positive_integer(Field, Value))).

require_positive_number(Value, _) :-
    number(Value), Value > 0,
    !.
require_positive_number(Value, Field) :-
    throw(tool_fault(invalid_positive_number(Field, Value))).

text_string(Value, String) :-
    string(Value),
    !,
    String = Value.
text_string(Value, String) :-
    atom(Value),
    !,
    atom_string(Value, String).

value_bytes(Value, Bytes) :-
    term_string(Value, Text, [quoted(true), numbervars(true)]),
    string_bytes(Text, Octets, utf8),
    length(Octets, Bytes).

value_shape(Value, Shape) :-
    (   var(Value) -> Shape = variable
    ;   is_dict(Value) -> Shape = dict
    ;   is_list(Value) -> Shape = list
    ;   compound(Value) -> functor(Value, Name, Arity), Shape = Name/Arity
    ;   atom(Value) -> Shape = atom
    ;   string(Value) -> Shape = string
    ;   number(Value) -> Shape = number
    ;   Shape = other
    ).

tool_api_exception(Phase, tool_fault(Fault), error(Error)) :-
    !,
    Error = tool_error{phase:Phase,
                       kind:invalid_tool_operation,
                       detail:Fault,
                       message:"tool operation is invalid"}.
tool_api_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = tool_error{phase:Phase,
                       kind:tool_runtime_error,
                       exception:Safe,
                       message:"tool operation failed"}.

invoke_exception(tool_fault(Fault), error(Error), denied, invalid_tool, 0) :-
    !,
    Error = tool_error{phase:invoke,
                       kind:invalid_tool_operation,
                       detail:Fault,
                       message:"tool invocation is invalid"}.
invoke_exception(capability_fault(Fault), error(Error), denied,
                 invalid_capabilities, 0) :-
    !,
    Error = tool_error{phase:authorize,
                       kind:invalid_capabilities,
                       detail:Fault,
                       message:"tool capability set is invalid"}.
invoke_exception(Exception, error(Error), denied, runtime_error, 0) :-
    safe_exception(Exception, Safe),
    Error = tool_error{phase:invoke,
                       kind:tool_runtime_error,
                       exception:Safe,
                       message:"tool invocation failed"}.

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
