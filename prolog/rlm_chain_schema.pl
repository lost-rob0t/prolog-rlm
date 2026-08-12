:- module(rlm_chain_schema,
          [ message_normalize/2,
            messages_normalize/2,
            prompt_compile/2,
            prompt_bind/3,
            structured_schema_compile/2,
            structured_validate/3,
            structured_decode_validate/3
          ]).

/** <module> Canonical chain data and structured-output validation */

:- use_module(library(http/json)).
:- use_module(library(lists)).

/* -------------------------------------------------------------------------
 * Canonical messages
 * ---------------------------------------------------------------------- */

message_normalize(Input, Outcome) :-
    catch(( message_normalize_(Input, Message),
            Result = ok(Message)
          ),
          Exception,
          schema_exception(message, Exception, Result)),
    Outcome = Result.

message_normalize_(message(Role0, Content0), Message) :-
    !,
    normalize_role(Role0, Role),
    normalize_content(Content0, Content),
    Message = message{role:Role, content:Content}.
message_normalize_(Input, Message) :-
    is_dict(Input),
    !,
    require_key(Input, role, Role0),
    require_key(Input, content, Content0),
    normalize_role(Role0, Role),
    normalize_content(Content0, Content),
    canonical_message_extras(Input, Extras),
    put_dict(_{role:Role, content:Content}, Extras, Message0),
    dict_pairs(Message0, _, Pairs),
    dict_pairs(Message, message, Pairs).
message_normalize_(Input, _) :-
    throw(chain_schema_fault(invalid_message(Input))).

messages_normalize(Messages0, Outcome) :-
    (   is_list(Messages0)
    ->  messages_normalize_(Messages0, [], Outcome)
    ;   Outcome = error(chain_schema_error{phase:message,
                                           kind:invalid_messages,
                                           detail:expected_list(Messages0),
                                           message:"messages must be a list"})
    ).

messages_normalize_([], Acc, ok(Messages)) :-
    reverse(Acc, Messages).
messages_normalize_([Input|Inputs], Acc, Outcome) :-
    message_normalize(Input, One),
    (   One = ok(Message)
    ->  messages_normalize_(Inputs, [Message|Acc], Outcome)
    ;   Outcome = One
    ).

normalize_role(Role0, Role) :-
    normalize_atom(Role0, Role),
    memberchk(Role, [system,user,assistant,tool]),
    !.
normalize_role(Role, _) :-
    throw(chain_schema_fault(invalid_message_role(Role))).

normalize_content(Content0, Content) :-
    string(Content0),
    !,
    Content = Content0.
normalize_content(Content0, Content) :-
    atom(Content0),
    !,
    atom_string(Content0, Content).
normalize_content(Content0, Content) :-
    is_list(Content0),
    !,
    maplist(normalize_content_part, Content0, Content).
normalize_content(Content, _) :-
    throw(chain_schema_fault(invalid_message_content(Content))).

normalize_content_part(text(Text0), Part) :-
    !,
    require_text(Text0, Text),
    Part = content_part{type:text, text:Text}.
normalize_content_part(image_url(URL0), Part) :-
    !,
    normalize_content_part(image_url(URL0, auto), Part).
normalize_content_part(image_url(URL0, Detail0), Part) :-
    !,
    require_text(URL0, URL),
    normalize_atom(Detail0, Detail),
    (   memberchk(Detail, [auto,low,high])
    ->  true
    ;   throw(chain_schema_fault(invalid_image_detail(Detail)))
    ),
    Part = content_part{type:image_url,
                        image_url:image{url:URL, detail:Detail}}.
normalize_content_part(Part0, Part) :-
    is_dict(Part0),
    !,
    require_key(Part0, type, Type0),
    normalize_atom(Type0, Type),
    normalize_dict_content_part(Type, Part0, Part).
normalize_content_part(Part, _) :-
    throw(chain_schema_fault(invalid_content_part(Part))).

normalize_dict_content_part(text, Part0, Part) :-
    !,
    require_key(Part0, text, Text0),
    normalize_content_part(text(Text0), Part).
normalize_dict_content_part(image_url, Part0, Part) :-
    !,
    require_key(Part0, image_url, Image0),
    (   is_dict(Image0)
    ->  require_key(Image0, url, URL0),
        dict_default(Image0, detail, auto, Detail0),
        normalize_content_part(image_url(URL0, Detail0), Part)
    ;   normalize_content_part(image_url(Image0), Part)
    ).
normalize_dict_content_part(Type, _, _) :-
    throw(chain_schema_fault(unsupported_content_part(Type))).

canonical_message_extras(Input, Extras) :-
    findall(Key-Value,
            ( member(Key,
                     [ name,
                       tool_call_id,
                       tool_calls,
                       reasoning,
                       reasoning_details
                     ]),
              get_dict(Key, Input, Raw),
              canonical_message_extra(Raw, Value)
            ),
            Pairs),
    dict_pairs(Extras, message_extra, Pairs).

canonical_message_extra(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_message_extra_pair, Pairs0, Pairs),
    dict_pairs(Value, message_data, Pairs).
canonical_message_extra(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_message_extra, Values0, Values).
canonical_message_extra(Value, Value) :-
    ground(Value),
    !.
canonical_message_extra(Value, _) :-
    throw(chain_schema_fault(non_ground(message_extra, Value))).

canonical_message_extra_pair(Key-Value0, Key-Value) :-
    canonical_message_extra(Value0, Value).

/* -------------------------------------------------------------------------
 * Prompt templates
 * ---------------------------------------------------------------------- */

prompt_compile(Spec, Outcome) :-
    catch(( prompt_compile_(Spec, Compiled),
            Result = ok(Compiled)
          ),
          Exception,
          schema_exception(prompt, Exception, Result)),
    Outcome = Result.

prompt_compile_(prompt(Segments0), Compiled) :-
    !,
    require_list(Segments0, prompt_segments),
    maplist(normalize_prompt_segment, Segments0, Segments),
    findall(Name, member(slot(Name), Segments), Slots0),
    sort(Slots0, Slots),
    Compiled = compiled_prompt{segments:Segments, slots:Slots}.
prompt_compile_(Spec, _) :-
    throw(chain_schema_fault(invalid_prompt_template(Spec))).

normalize_prompt_segment(text(Text0), text(Text)) :-
    !,
    require_text(Text0, Text).
normalize_prompt_segment(slot(Name0), slot(Name)) :-
    !,
    normalize_atom(Name0, Name),
    (   Name \== ''
    ->  true
    ;   throw(chain_schema_fault(empty_prompt_slot))
    ).
normalize_prompt_segment(Segment, _) :-
    throw(chain_schema_fault(invalid_prompt_segment(Segment))).

prompt_bind(Compiled, Bindings, Outcome) :-
    catch(( prompt_bind_(Compiled, Bindings, Text),
            Result = ok(Text)
          ),
          Exception,
          schema_exception(prompt, Exception, Result)),
    Outcome = Result.

prompt_bind_(Compiled, Bindings, Text) :-
    is_dict(Compiled),
    get_dict(segments, Compiled, Segments),
    is_dict(Bindings),
    maplist(bind_prompt_segment(Bindings), Segments, Fragments),
    atomics_to_string(Fragments, Text).

bind_prompt_segment(_, text(Text), Text).
bind_prompt_segment(Bindings, slot(Name), Text) :-
    (   get_dict(Name, Bindings, Value)
    ->  prompt_value_text(Value, Text)
    ;   throw(chain_schema_fault(missing_prompt_binding(Name)))
    ).

prompt_value_text(Value, Value) :- string(Value), !.
prompt_value_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
prompt_value_text(Value, Text) :- number(Value), !, number_string(Value, Text).
prompt_value_text(Value, Text) :-
    memberchk(Value, [true,false]),
    !,
    atom_string(Value, Text).
prompt_value_text(Value, _) :-
    throw(chain_schema_fault(invalid_prompt_binding(Value))).

/* -------------------------------------------------------------------------
 * Structured-output schema algebra
 * ---------------------------------------------------------------------- */

structured_schema_compile(Spec, Outcome) :-
    catch(( compile_schema(Spec, Compiled),
            Result = ok(Compiled)
          ),
          Exception,
          schema_exception(structured_output, Exception, Result)),
    Outcome = Result.

compile_schema(any, schema(any)) :- !.
compile_schema(string, schema(string)) :- !.
compile_schema(integer, schema(integer)) :- !.
compile_schema(number, schema(number)) :- !.
compile_schema(boolean, schema(boolean)) :- !.
compile_schema(enum(Values0), schema(enum(Values))) :-
    !,
    require_list(Values0, enum_values),
    (   Values0 \== []
    ->  true
    ;   throw(chain_schema_fault(empty_enum))
    ),
    maplist(require_ground_value, Values0),
    sort(Values0, Values),
    length(Values0, Count),
    length(Values, Count),
    !.
compile_schema(enum(Values), _) :-
    !,
    throw(chain_schema_fault(duplicate_enum_values(Values))).
compile_schema(list(Item0), schema(list(Item))) :-
    !,
    compile_schema(Item0, Item).
compile_schema(object(Fields0), schema(object(Fields))) :-
    !,
    require_list(Fields0, object_fields),
    maplist(compile_field, Fields0, Fields),
    findall(Name, member(schema_field(Name,_,_), Fields), Names),
    require_unique(Names, schema_field).
compile_schema(Spec, _) :-
    throw(chain_schema_fault(unsupported_schema(Spec))).

compile_field(field(Name0, Schema0, required),
              schema_field(Name, Schema, required)) :-
    !,
    normalize_atom(Name0, Name),
    compile_schema(Schema0, Schema).
compile_field(field(Name0, Schema0, optional(Default)),
              schema_field(Name, Schema, optional(Default))) :-
    !,
    normalize_atom(Name0, Name),
    compile_schema(Schema0, Schema),
    require_ground(Default, optional_default(Name)),
    validate_schema_value(Schema, Default, [Name]).
compile_field(Field, _) :-
    throw(chain_schema_fault(invalid_schema_field(Field))).

structured_validate(Compiled, Value, Outcome) :-
    catch(( validate_schema_value(Compiled, Value, []),
            Result = ok(Value)
          ),
          Exception,
          schema_exception(structured_output, Exception, Result)),
    Outcome = Result.

structured_decode_validate(Compiled, Text0, Outcome) :-
    catch(( structured_decode_validate_(Compiled, Text0, Value),
            Result = ok(Value)
          ),
          Exception,
          schema_exception(structured_output, Exception, Result)),
    Outcome = Result.

structured_decode_validate_(Compiled, Text0, Value) :-
    require_text(Text0, Text),
    atom_string(Atom, Text),
    catch(atom_json_dict(Atom, Raw, []),
          Exception,
          throw(chain_schema_fault(invalid_json(Exception)))),
    canonical_json_value(Raw, Value),
    validate_schema_value(Compiled, Value, []).

validate_schema_value(schema(any), Value, _) :-
    ground(Value),
    !.
validate_schema_value(schema(string), Value, _) :- string(Value), !.
validate_schema_value(schema(integer), Value, _) :- integer(Value), !.
validate_schema_value(schema(number), Value, _) :- number(Value), !.
validate_schema_value(schema(boolean), Value, _) :- memberchk(Value, [true,false]), !.
validate_schema_value(schema(enum(Values)), Value, _) :-
    memberchk(Value, Values),
    !.
validate_schema_value(schema(list(Item)), Value, Path) :-
    is_list(Value),
    !,
    validate_list_items(Value, Item, Path, 0).
validate_schema_value(schema(object(Fields)), Value, Path) :-
    is_dict(Value),
    !,
    validate_object_fields(Fields, Value, Path),
    dict_pairs(Value, _, Pairs),
    findall(Name, member(schema_field(Name,_,_), Fields), Allowed),
    forall(member(Key-_, Pairs),
           (   memberchk(Key, Allowed)
           ->  true
           ;   throw(chain_schema_fault(unexpected_field([Key|Path])))
           )).
validate_schema_value(Schema, Value, Path) :-
    throw(chain_schema_fault(schema_mismatch(Path, Schema, Value))).

validate_list_items([], _, _, _).
validate_list_items([Value|Values], Schema, Path, Index) :-
    validate_schema_value(Schema, Value, [Index|Path]),
    Next is Index+1,
    validate_list_items(Values, Schema, Path, Next).

validate_object_fields([], _, _).
validate_object_fields([schema_field(Name, Schema, required)|Fields], Value, Path) :-
    (   get_dict(Name, Value, FieldValue)
    ->  validate_schema_value(Schema, FieldValue, [Name|Path])
    ;   throw(chain_schema_fault(missing_required_field([Name|Path])))
    ),
    validate_object_fields(Fields, Value, Path).
validate_object_fields([schema_field(Name, Schema, optional(Default))|Fields], Value, Path) :-
    (   get_dict(Name, Value, FieldValue)
    ->  validate_schema_value(Schema, FieldValue, [Name|Path])
    ;   validate_schema_value(Schema, Default, [Name|Path])
    ),
    validate_object_fields(Fields, Value, Path).

canonical_json_value(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_json_pair, Pairs0, Pairs),
    dict_pairs(Value, json, Pairs).
canonical_json_value(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_json_value, Values0, Values).
canonical_json_value(Value, Value) :- atomic(Value), !.
canonical_json_value(Value, _) :-
    throw(chain_schema_fault(non_json_value(Value))).

canonical_json_pair(Key-Value0, Key-Value) :-
    atom(Key),
    canonical_json_value(Value0, Value).

/* -------------------------------------------------------------------------
 * Errors / helpers
 * ---------------------------------------------------------------------- */

schema_exception(Phase, chain_schema_fault(Detail), error(Error)) :-
    !,
    Error = chain_schema_error{phase:Phase,
                               kind:validation_error,
                               detail:Detail,
                               message:"chain data validation failed"}.
schema_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = chain_schema_error{phase:Phase,
                               kind:exception,
                               exception:Safe,
                               message:"chain data processing raised an exception"}.

require_key(Dict, Key, Value) :-
    (   get_dict(Key, Dict, Value)
    ->  true
    ;   throw(chain_schema_fault(missing_key(Key)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Found)
    ->  Value = Found
    ;   Value = Default
    ).

normalize_atom(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_atom(Value, _) :- throw(chain_schema_fault(expected_atom(Value))).

require_text(Value, Text) :- string(Value), !, Text = Value.
require_text(Value, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, _) :- throw(chain_schema_fault(expected_text(Value))).

require_list(Value, _) :- is_list(Value), !.
require_list(Value, Name) :- throw(chain_schema_fault(expected_list(Name, Value))).

require_ground(Value, _) :- ground(Value), !.
require_ground(Value, Name) :- throw(chain_schema_fault(non_ground(Name, Value))).
require_ground_value(Value) :- require_ground(Value, enum_value).

require_unique(Values, _Kind) :-
    sort(Values, Unique),
    length(Values, Count),
    length(Unique, Count),
    !.
require_unique(Values, Kind) :-
    throw(chain_schema_fault(duplicate(Kind, Values))).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
