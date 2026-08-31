:- module(rlm_native_tool,
          [ native_tool_call_normalize/2,
            native_tool_calls_normalize/2,
            native_tool_calls_classify/2,
            native_tool_schema_normalize/2,
            native_tool_schema_wire/3,
            native_tool_result_message/3
          ]).

/** <module> Provider-neutral native tool protocol data

This module normalizes provider tool calls and renders inert provider schemas.
It owns no registry handlers, capabilities, authority, effects, or scheduling.
*/

:- use_module(library(http/json)).
:- use_module(library(lists)).
:- use_module(rlm_trace, [trace_encode/2]).

native_tool_call_normalize(Input, Outcome) :-
    catch(( normalize_native_call(Input, Call),
            Result = ok(Call)
          ),
          native_tool_fault(Error),
          Result = error(Error)),
    Outcome = Result.

native_tool_calls_normalize(Inputs, Outcome) :-
    catch(( require_call_list(Inputs),
            maplist(normalize_native_call, Inputs, Calls),
            require_unique_call_ids(Calls),
            Result = ok(Calls)
          ),
          native_tool_fault(Error),
          Result = error(Error)),
    Outcome = Result.

% Normalize one provider batch while retaining attributable argument-parse
% faults in wire text as inert ordered entries. Envelope, identity, type,
% name, and duplicate-ID failures remain batch-fatal. The strict
% normalization APIs above keep their existing all-or-nothing contract.
native_tool_calls_classify(Inputs, Outcome) :-
    catch(( require_call_list(Inputs),
            maplist(classify_native_call, Inputs, Entries),
            maplist(native_call_entry_call, Entries, Calls),
            require_unique_call_ids(Calls),
            Result = ok(Entries)
          ),
          native_tool_fault(Error),
          Result = error(Error)),
    Outcome = Result.

normalize_native_call(Input, Call) :-
    normalize_native_call_parts(Input, Id, Name, Arguments0),
    normalize_arguments(Arguments0, Arguments),
    Call = native_tool_call{id:Id,
                            name:Name,
                            arguments:Arguments,
                            type:function}.

normalize_native_call_parts(Input, Id, Name, Arguments0) :-
    require_ground_acyclic(Input, call),
    require_dict(Input, call),
    require_allowed_keys(Input, [id,type,function,index], call),
    require_key(Input, id, Id0, call),
    normalize_protocol_token(Id0, call_id, Id),
    require_key(Input, type, Type0, call),
    normalize_atom(Type0, Type, call_type),
    (   Type == function
    ->  true
    ;   native_error(normalize, unsupported_call_type,
                     _{call_id:Id,type:Type},
                     "provider native call type is unsupported")
    ),
    require_key(Input, function, Function, call),
    require_dict(Function, function),
    require_allowed_keys(Function, [name,arguments], function),
    require_key(Function, name, Name0, function),
    normalize_tool_name(Name0, Name),
    require_key(Function, arguments, Arguments0, function).

classify_native_call(Input, Entry) :-
    normalize_native_call_parts(Input, Id, Name, Arguments0),
    Identity = native_tool_call{id:Id,name:Name,type:function},
    catch(normalize_arguments(Arguments0, Arguments),
          native_tool_fault(Cause),
          true),
    classified_native_call(Cause, Identity, Arguments0, Arguments, Entry).

classified_native_call(Cause, Identity, Arguments0, _, Entry) :-
    nonvar(Cause),
    !,
    (   Cause.phase == normalize,
        Cause.kind == malformed_arguments,
        text_value(Arguments0, _)
    ->  Entry = native_call_entry{call:Identity,
                                  status:fault(Cause),
                                  arguments:Arguments0}
    ;   throw(native_tool_fault(Cause))
    ).
classified_native_call(_, Identity, _, Arguments,
                       native_call_entry{call:Call,status:normalized}) :-
    put_dict(arguments, Identity, Arguments, Call).

native_call_entry_call(Entry, Entry.call).

require_call_list(Inputs) :-
    (   is_list(Inputs)
    ->  true
    ;   native_error(normalize, malformed_tool_calls,
                     _{detail:expected_list},
                     "provider tool_calls must be a list")
    ).

require_unique_call_ids(Calls) :-
    require_unique_call_ids(Calls, []).

require_unique_call_ids([], _).
require_unique_call_ids([Call|Calls], Seen) :-
    (   memberchk(Call.id, Seen)
    ->  native_error(normalize, duplicate_call_id,
                     _{call_id:Call.id},
                     "provider reused a native call ID")
    ;   require_unique_call_ids(Calls, [Call.id|Seen])
    ).

normalize_arguments(Arguments0, Arguments) :-
    (   is_dict(Arguments0)
    ->  canonical_json(Arguments0, Arguments)
    ;   text_value(Arguments0, Text)
    ->  catch(parse_json_object(Text, Arguments), _, fail)
    ;   fail
    ),
    is_dict(Arguments),
    ground(Arguments),
    acyclic_term(Arguments),
    !.
normalize_arguments(_, _) :-
    native_error(normalize, malformed_arguments, _{},
                 "native tool arguments must be one ground JSON object").

parse_json_object(Text, Arguments) :-
    atom_string(Atom, Text),
    atom_json_dict(Atom, Parsed, []),
    is_dict(Parsed),
    canonical_json(Parsed, Arguments).

native_tool_schema_normalize(Input, Outcome) :-
    catch(( normalize_native_schema(Input, Schema),
            Result = ok(Schema)
          ),
          native_tool_fault(Error),
          Result = error(Error)),
    Outcome = Result.

normalize_native_schema(Input, Schema) :-
    require_ground_acyclic(Input, schema),
    require_dict(Input, schema),
    require_key(Input, name, Name0, schema),
    normalize_tool_name(Name0, Name),
    require_key(Input, description, Description0, schema),
    require_text(Description0, Description, description),
    require_key(Input, capability, Capability, schema),
    (   Capability == tool(Name)
    ->  true
    ;   native_error(schema, invalid_capability,
                     _{name:Name,capability:Capability},
                     "native registry schema capability does not match its name")
    ),
    require_key(Input, effect, Effect, schema),
    require_key(Input, arguments, Parameters0, schema),
    json_schema(Parameters0, Parameters),
    (   Parameters.type == "object"
    ->  true
    ;   native_error(schema, unsupported_arguments_schema,
                     _{name:Name},
                     "provider-native function arguments require an object schema")
    ),
    Schema = native_tool_schema{name:Name,
                                description:Description,
                                parameters:Parameters,
                                source:registry,
                                capability:Capability,
                                effect:Effect}.

json_schema(Input, Output) :-
    require_dict(Input, json_schema),
    require_key(Input, type, Type0, json_schema),
    json_schema_type(Type0, Input, Output).

json_schema_type(any, Input, Output) :-
    !,
    json_schema_pairs(Input, Pairs),
    dict_pairs(Output, json, Pairs).
json_schema_type(Type0, Input, Output) :-
    schema_type(Type0, Type),
    json_schema_pairs(Input, Pairs),
    dict_pairs(Fields, json, Pairs),
    put_dict(type, Fields, Type, Output).

json_schema_pairs(Input, Pairs) :-
    findall(Pair,
            json_schema_pair(Input, Pair),
            Pairs).

json_schema_pair(Input, properties-Properties) :-
    get_dict(properties, Input, Properties0),
    require_dict(Properties0, schema_properties),
    dict_pairs(Properties0, _, Pairs0),
    maplist(json_property_pair, Pairs0, Pairs),
    dict_pairs(Properties, json, Pairs).
json_schema_pair(Input, required-Required) :-
    get_dict(required, Input, Required0),
    is_list(Required0),
    maplist(schema_required_name, Required0, Required).
json_schema_pair(Input, additionalProperties-Value) :-
    get_dict(additional_properties, Input, Value),
    memberchk(Value, [true,false]).
json_schema_pair(Input, items-Items) :-
    get_dict(items, Input, Items0),
    json_schema(Items0, Items).
json_schema_pair(Input, description-Description) :-
    get_dict(description, Input, Description0),
    require_text(Description0, Description, description).
json_schema_pair(Input, Key-Value) :-
    member(Key, [minimum,maximum,exclusiveMinimum,exclusiveMaximum]),
    get_dict(Key, Input, Value),
    number(Value).

json_property_pair(Key-Schema0, Key-Schema) :-
    atom(Key),
    json_schema(Schema0, Schema).

schema_required_name(Name0, Name) :-
    normalize_protocol_token(Name0, required_field, Name).

schema_type(list, "array") :- !.
schema_type(array, "array") :- !.
schema_type(Type, Text) :-
    memberchk(Type, [object,string,integer,number,boolean]),
    !,
    atom_string(Type, Text).
schema_type(Type, _) :-
    native_error(schema, unsupported_schema_type,
                 _{type:Type},
                 "runtime schema type cannot be projected to provider JSON Schema").

native_tool_schema_wire(Format, Schema, Outcome) :-
    catch(( native_schema_wire(Format, Schema, Wire),
            Result = ok(Wire)
          ),
          native_tool_fault(Error),
          Result = error(Error)),
    Outcome = Result.

native_schema_wire(openai_compatible, Schema, Wire) :-
    require_native_schema(Schema),
    atom_string(Schema.name, Name),
    Wire = json{type:"function",
                function:json{name:Name,
                              description:Schema.description,
                              parameters:Schema.parameters}},
    !.
native_schema_wire(Format, _, _) :-
    native_error(render, unsupported_provider_tool_format,
                 _{format:Format},
                 "provider native-tool wire format is unsupported").

require_native_schema(Schema) :-
    (   is_dict(Schema, native_tool_schema),
        ground(Schema),
        acyclic_term(Schema),
        atom(Schema.name),
        string(Schema.description),
        is_dict(Schema.parameters)
    ->  true
    ;   native_error(render, invalid_native_schema, _{},
                     "native tool schema is malformed")
    ).

native_tool_result_message(Call, Result, Outcome) :-
    catch(( result_message(Call, Result, Message),
            ResultOutcome = ok(Message)
          ),
          native_tool_fault(Error),
          ResultOutcome = error(Error)),
    Outcome = ResultOutcome.

result_message(Call, Result, Message) :-
    require_normalized_call(Call),
    require_ground_acyclic(Result, result),
    require_dict(Result, result),
    require_key(Result, call_id, ResultId, result),
    (   ResultId == Call.id
    ->  true
    ;   native_error(result, tool_result_id_mismatch,
                     _{expected:Call.id,actual:ResultId},
                     "tool result call ID does not match its request")
    ),
    require_key(Result, name, ResultName, result),
    (   ResultName == Call.name
    ->  true
    ;   native_error(result, tool_result_name_mismatch,
                     _{expected:Call.name,actual:ResultName},
                     "tool result name does not match its request")
    ),
    trace_encode(Result, JsonSafe),
    atom_json_dict(ContentAtom, JsonSafe, [width(0)]),
    atom_string(ContentAtom, Content),
    Message = message{role:tool,
                      tool_call_id:Call.id,
                      name:Call.name,
                      content:Content}.

require_normalized_call(Call) :-
    (   is_dict(Call, native_tool_call),
        ground(Call),
        acyclic_term(Call),
        Call.type == function
    ->  true
    ;   native_error(result, invalid_native_call, _{},
                     "tool result requires a normalized native call")
    ).

canonical_json(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_json_pair, Pairs0, Pairs),
    dict_pairs(Value, json, Pairs).
canonical_json(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_json, Values0, Values).
canonical_json(Value, Value) :-
    ( string(Value) ; number(Value) ; memberchk(Value, [true,false,null]) ),
    !.
canonical_json(Value, String) :-
    atom(Value),
    atom_string(Value, String),
    !.
canonical_json(_, _) :-
    fail.

canonical_json_pair(Key-Value0, Key-Value) :-
    atom(Key),
    canonical_json(Value0, Value).

normalize_tool_name(Name0, Name) :-
    normalize_protocol_token(Name0, tool_name, Text),
    atom_string(Name, Text).

normalize_protocol_token(Value, Field, Text) :-
    require_text(Value, Text, Field),
    string_length(Text, Length),
    Length > 0,
    Length =< 128,
    string_codes(Text, Codes),
    maplist(protocol_token_code, Codes),
    !.
normalize_protocol_token(Value, call_id, _) :-
    native_error(normalize, malformed_call_id, _{value:Value},
                 "native tool call ID must be a bounded protocol token").
normalize_protocol_token(Value, Field, _) :-
    native_error(normalize, malformed_protocol_token,
                 _{field:Field,value:Value},
                 "native tool protocol token is malformed").

protocol_token_code(Code) :-
    ( code_type(Code, alnum)
    ; memberchk(Code, [0'_,0'-,0'.,0':])
    ).

normalize_atom(Value, Atom, _) :-
    atom(Value),
    !,
    Atom = Value.
normalize_atom(Value, Atom, _) :-
    string(Value),
    !,
    atom_string(Atom, Value).
normalize_atom(Value, _, Field) :-
    native_error(normalize, malformed_field, _{field:Field,value:Value},
                 "native tool field must be text").

text_value(Value, Text) :-
    ( string(Value) -> Text = Value
    ; atom(Value) -> atom_string(Value, Text)
    ).

require_text(Value, Text, _) :-
    text_value(Value, Text),
    !.
require_text(Value, _, Field) :-
    native_error(normalize, malformed_field, _{field:Field,value:Value},
                 "native tool field must be text").

require_ground_acyclic(Value, Field) :-
    (   acyclic_term(Value), closed_native_data(Value)
    ->  true
    ;   native_error(normalize, non_ground_data, _{field:Field},
                     "native tool protocol data must be ground and acyclic")
    ).

closed_native_data(Value) :-
    var(Value),
    !,
    fail.
closed_native_data(Value) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    maplist(closed_native_pair, Pairs).
closed_native_data(Values) :-
    is_list(Values),
    !,
    maplist(closed_native_data, Values).
closed_native_data(Value) :-
    atomic(Value),
    !.
closed_native_data(Value) :-
    compound(Value),
    Value =.. [_|Args],
    maplist(closed_native_data, Args).

closed_native_pair(Key-Value) :-
    atom(Key),
    closed_native_data(Value).

require_dict(Value, _) :-
    is_dict(Value),
    !.
require_dict(_, Field) :-
    native_error(normalize, malformed_field, _{field:Field},
                 "native tool protocol field must be an object").

require_key(Dict, Key, Value, _) :-
    get_dict(Key, Dict, Value),
    !.
require_key(_, Key, _, Container) :-
    native_error(normalize, missing_field, _{container:Container,field:Key},
                 "native tool protocol field is missing").

require_allowed_keys(Dict, Allowed, Container) :-
    dict_keys(Dict, Keys),
    subtract(Keys, Allowed, Extra),
    (   Extra == []
    ->  true
    ;   native_error(normalize, unexpected_fields,
                     _{container:Container,fields:Extra},
                     "native tool protocol contains unsupported fields")
    ).

native_error(Phase, Kind, Fields, Message) :-
    put_dict(Fields,
             native_tool_error{phase:Phase,kind:Kind,message:Message},
             Error),
    throw(native_tool_fault(Error)).
