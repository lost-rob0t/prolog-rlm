:- module(rlm_agent_zero_adapter,
          [ rlm_agent_zero_adapter_ready/0,
            agent_zero_context_compile/2,
            agent_zero_tool_pack_manifest/3,
            agent_zero_tool_registry_import/4
          ]).

/** <module> Agent Zero inert metadata and trusted tool-host adapter

This is the canonical Agent Zero adaptation boundary.  Agent Zero contributes
bounded inert DOX, skill and tool declarations.  Prolog converts them to prompt
compiler units, derives activation evidence, applies permanent visibility,
packs the context and returns the provider projection.  Python does not select
units or reproduce compiler policy.

Executable Agent Zero tool bindings enter only through the separate trusted
`agent_zero_tool_registry_import/4` host API.  Model data can name a registered
tool but can never supply the host handler closure, grant its capability or
change authority.
*/

:- use_module(library(lists)).
:- use_module(rlm_prompt_compiler, []).
:- use_module(rlm_tool, []).
:- use_module(rlm_authority, []).

:- meta_predicate agent_zero_tool_registry_import(+, +, 3, -).

rlm_agent_zero_adapter_ready :-
    rlm_prompt_compiler:rlm_prompt_compiler_ready.

agent_zero_context_compile(Request, Outcome) :-
    catch(( require_context_request(Request),
            context_compile(Request, Result),
            Outcome = ok(Result)
          ),
          Exception,
          adapter_exception(context_compile, Exception, Outcome)).

context_compile(Request, Result) :-
    request_message(Request, Message),
    get_dict(units, Request, Units0),
    must_be(list, Units0),
    maplist(agent_zero_unit_spec, Units0, Specs),
    setup_call_cleanup(
        rlm_prompt_compiler:prompt_catalog_create(Catalog),
        compile_catalog(Catalog, Request, Message, Specs, Result),
        rlm_prompt_compiler:prompt_catalog_destroy(Catalog)).

compile_catalog(Catalog, Request, Message, Specs, Result) :-
    maplist(register_spec(Catalog), Specs),
    permanent_units(Specs, Selected),
    tool_capabilities(Specs, Capabilities),
    request_policy(Request, Policy),
    Input = prompt_input{text:Message, selected:Selected},
    Options = [capabilities(Capabilities), policy(Policy), candidate_limit(256)],
    rlm_prompt_compiler:prompt_compile(Catalog, Input, Options, CompileOutcome),
    require_ok(CompileOutcome, Compiled),
    rlm_prompt_compiler:prompt_render(Compiled, openrouter, RenderOutcome),
    require_ok(RenderOutcome, Rendered),
    findall(Name,
            ( member(Unit, Rendered.active_units), active_tool_name(Unit, Name) ),
            ActiveTools0),
    sort(ActiveTools0, ActiveTools),
    Result = agent_zero_context{
                 text:Rendered.text,
                 active_units:Rendered.active_units,
                 active_tools:ActiveTools,
                 tool_schemas:Rendered.tool_schemas,
                 fingerprint:Rendered.fingerprint,
                 token_ledger:Compiled.token_ledger,
                 rejected:Compiled.rejected,
                 warnings:[]
             }.

register_spec(Catalog, Spec) :-
    rlm_prompt_compiler:prompt_catalog_register(Catalog, Spec, Outcome),
    require_ok(Outcome, _).

request_message(Request, Message) :-
    get_dict(message, Request, Message0),
    require_text(Message0, message, Message).

request_policy(Request,
               _{max_context_tokens:Max,
                 provider_context_tokens:Max,
                 reserve_output_tokens:0,
                 safety_margin_tokens:0,
                 min_recent_turns:0,
                 overflow:deny}) :-
    ( get_dict(max_context_tokens, Request, Max0) -> Max = Max0 ; Max = 16384 ),
    must_be(integer, Max),
    ( Max > 0 -> true ; throw(agent_zero_fault(invalid_context_limit(Max))) ).

agent_zero_unit_spec(Unit0, Spec) :-
    require_unit_dict(Unit0),
    unit_format(Unit0, Format),
    unit_kind(Unit0, Format, Kind),
    get_dict(name, Unit0, Name0),
    require_name(Name0, name, Name),
    unit_identity(Kind, Unit0, Name, Unit),
    dict_text(Unit0, description, Name0, Description),
    dict_text(Unit0, content, Description, Content),
    dict_text(Unit0, compact, Description, Compact),
    dict_aliases(Unit0, Aliases),
    unit_triggers(Name, Description, Aliases, Triggers),
    unit_permanent(Unit0, Permanent),
    unit_capability(Unit, Capability),
    unit_schema(Kind, Unit0, Name, Description, Capability, Schema),
    unit_representations(Kind, Compact, Content, Schema, Representations),
    Spec = prompt_unit{unit:Unit,
                       kind:Kind,
                       name:Name,
                       category:Kind,
                       description:Description,
                       available:true,
                       aliases:Aliases,
                       triggers:Triggers,
                       requires:[],
                       suggests:[],
                       conflicts:[],
                       supersedes:[],
                       requires_capability:Capability,
                       priority:100,
                       provider_visible:true,
                       mandatory_context:Permanent,
                       schema:Schema,
                       content:Content,
                       representations:Representations,
                       provenance:Format}.

require_unit_dict(Unit) :- is_dict(Unit), !.
require_unit_dict(Unit) :- throw(agent_zero_fault(invalid_unit(Unit))).

unit_format(Unit, Format) :-
    ( get_dict(format, Unit, Format0) -> require_name(Format0, format, Format)
    ; Format = agent_zero_context
    ),
    ( memberchk(Format, [agent_zero_context, agent_zero_tool, agent_zero_skill, dox])
    -> true
    ; throw(agent_zero_fault(unsupported_format(Format)))
    ).

unit_kind(Unit, dox, instruction) :- !,
    optional_declared_kind(Unit, dox).
unit_kind(Unit, agent_zero_skill, skill) :- !,
    optional_declared_kind(Unit, skill).
unit_kind(Unit, agent_zero_tool, Kind) :- !,
    get_dict(kind, Unit, Kind0),
    require_name(Kind0, kind, Kind),
    ( memberchk(Kind, [tool,mcp_tool]) -> true
    ; throw(agent_zero_fault(invalid_tool_kind(Kind)))
    ).
unit_kind(Unit, agent_zero_context, Kind) :-
    get_dict(kind, Unit, Kind0),
    require_name(Kind0, kind, Kind),
    ( memberchk(Kind, [instruction,skill,tool,mcp_tool,resource]) -> true
    ; throw(agent_zero_fault(invalid_context_kind(Kind)))
    ).

optional_declared_kind(Unit, Expected) :-
    ( get_dict(kind, Unit, Actual0)
    -> require_name(Actual0, kind, Actual),
       ( Actual == Expected ; Expected == instruction, Actual == dox )
    ; true
    ),
    !.
optional_declared_kind(_, Expected) :-
    throw(agent_zero_fault(format_kind_mismatch(Expected))).

unit_identity(instruction, _, Name, instruction(Name)).
unit_identity(skill, _, Name, skill(Name)).
unit_identity(tool, _, Name, tool(Name)).
unit_identity(resource, _, Name, resource(Name)).
unit_identity(mcp_tool, Unit, Name, mcp_tool(Server, Name)) :-
    get_dict(server, Unit, Server0),
    require_name(Server0, server, Server).

unit_capability(tool(Name), tool(Name)) :- !.
unit_capability(mcp_tool(_, Name), tool(Name)) :- !.
unit_capability(_, none).

unit_schema(tool, Unit, Name, Description, Capability, Schema) :-
    !,
    declared_schema(Unit, Arguments),
    declared_effect(Unit, Effect),
    Schema = tool_schema{name:Name,
                         description:Description,
                         capability:Capability,
                         effect:Effect,
                         arguments:Arguments,
                         result:_{type:object,
                                  properties:_{},
                                  additional_properties:true},
                         limits:_{}}.
unit_schema(mcp_tool, Unit, Name, Description, Capability, Schema) :-
    !,
    declared_schema(Unit, Arguments),
    declared_effect(Unit, Effect),
    Schema = tool_schema{name:Name,
                         description:Description,
                         capability:Capability,
                         effect:Effect,
                         arguments:Arguments,
                         result:_{type:object,
                                  properties:_{},
                                  additional_properties:true},
                         limits:_{}}.
unit_schema(_, _, _, _, _, none).

declared_schema(Unit, Schema) :-
    ( get_dict(schema, Unit, Schema0) -> json_schema(Schema0, Schema)
    ; Schema = _{type:object, properties:_{}, additional_properties:true}
    ).

declared_effect(Unit, Effect) :-
    ( get_dict(effect, Unit, Effect0) -> require_name(Effect0, effect, Raw)
    ; Raw = write
    ),
    normalize_agent_zero_effect(Raw, Effect),
    ( rlm_authority:rlm_effect_class(Effect) -> true
    ; throw(agent_zero_fault(invalid_effect(Effect)))
    ).

normalize_agent_zero_effect(network, network_write) :- !.
normalize_agent_zero_effect(Effect, Effect).

unit_representations(Kind, Compact, Content, _Schema,
                     [prompt_representation{kind:full,
                                            text:Content,
                                            utility:1000000},
                      prompt_representation{kind:compact,
                                            text:Compact,
                                            utility:1000001}]) :-
    memberchk(Kind, [tool,mcp_tool]),
    !.
unit_representations(_, _, _, _, []).

unit_permanent(Unit, Permanent) :-
    ( get_dict(permanent, Unit, Permanent0) -> Permanent = Permanent0
    ; get_dict(mandatory, Unit, Mandatory0) -> Permanent = Mandatory0
    ; Permanent = false
    ),
    ( memberchk(Permanent, [true,false]) -> true
    ; throw(agent_zero_fault(invalid_permanent_marker(Permanent)))
    ).

permanent_units(Specs, Selected) :-
    findall(Unit,
            ( member(Spec, Specs),
              Spec.mandatory_context == true,
              Unit = Spec.unit ),
            Selected0),
    sort(Selected0, Selected).

tool_capabilities(Specs, Capabilities) :-
    findall(Capability,
            ( member(Spec, Specs),
              Capability = Spec.requires_capability,
              Capability \== none ),
            Caps0),
    sort(Caps0, Capabilities).

active_tool_name(tool(Name), Name).
active_tool_name(mcp_tool(_, Name), Name).

dict_text(Dict, Key, Default, Text) :-
    ( get_dict(Key, Dict, Value) -> require_text(Value, Key, Text)
    ; require_text(Default, Key, Text)
    ).

dict_aliases(Dict, Aliases) :-
    ( get_dict(aliases, Dict, Aliases0) -> must_be(list, Aliases0)
    ; Aliases0 = []
    ),
    maplist(require_alias, Aliases0, Aliases).

require_alias(Value, Text) :- require_text(Value, alias, Text).

require_text(Value, _, Text) :- string(Value), !, Text = Value.
require_text(Value, _, Text) :- atom(Value), !, atom_string(Value, Text).
require_text(Value, Field, _) :-
    throw(agent_zero_fault(non_text_field(Field, Value))).

require_name(Value, Field, Name) :-
    require_text(Value, Field, Text),
    ( Text \== "" -> atom_string(Name, Text)
    ; throw(agent_zero_fault(empty_name(Field)))
    ).

unit_triggers(Name, Description, Aliases, Triggers) :-
    atom_string(Name, NameText),
    string_concat(NameText, " ", Prefix),
    string_concat(Prefix, Description, Material),
    split_string(Material, " _-/.,:;()[]{}", " \t\n", Words0),
    include(relevant_word, Words0, Words1),
    maplist(lower_word_trigger, Words1, WordTriggers0),
    maplist(alias_trigger, Aliases, AliasTriggers),
    append(WordTriggers0, AliasTriggers, Triggers0),
    sort(Triggers0, Triggers1),
    first_n(24, Triggers1, Triggers).

relevant_word(Word) :-
    string_length(Word, Length),
    Length >= 3,
    string_lower(Word, Lower),
    \+ stop_word(Lower).

stop_word("and"). stop_word("the"). stop_word("for"). stop_word("with").
stop_word("from"). stop_word("this"). stop_word("that"). stop_word("tool").
stop_word("use"). stop_word("uses"). stop_word("return").

lower_word_trigger(Word, trigger(keyword(Lower), 50)) :- string_lower(Word, Lower).
alias_trigger(Alias, trigger(phrase(Alias), 80)).

first_n(N, List, Prefix) :- length(Prefix, N), append(Prefix, _, List), !.
first_n(_, List, List).

/* Agent Zero JSON Schema -> closed rlm_tool schema -------------------- */

json_schema(Schema0, Schema) :-
    ( is_dict(Schema0) -> json_schema_dict(Schema0, Schema)
    ; throw(agent_zero_fault(invalid_json_schema(Schema0)))
    ).

json_schema_dict(Schema0, Schema) :-
    dict_pairs(Schema0, _, Pairs0),
    maplist(json_schema_pair, Pairs0, Pairs),
    dict_pairs(Schema1, json_schema, Pairs),
    ( get_dict(type, Schema1, _) -> Schema = Schema1
    ; put_dict(type, Schema1, object, Schema)
    ).

json_schema_pair(Key0-Value0, Key-Value) :-
    schema_key(Key0, Key),
    schema_value(Key, Value0, Value).

schema_key(additionalProperties, additional_properties) :- !.
schema_key(Key, Key).

schema_value(type, Value0, Value) :- !, require_name(Value0, schema_type, Value).
schema_value(required, Values0, Values) :-
    !,
    must_be(list, Values0),
    maplist(require_required_name, Values0, Values).
schema_value(properties, Value0, Value) :-
    !,
    ( is_dict(Value0) -> json_schema_properties(Value0, Value)
    ; throw(agent_zero_fault(invalid_schema_properties(Value0)))
    ).
schema_value(items, Value0, Value) :- !, json_schema(Value0, Value).
schema_value(_, Value, Value) :- ground(Value), !.
schema_value(Key, Value, _) :-
    throw(agent_zero_fault(non_ground_schema_value(Key, Value))).

require_required_name(Value, Name) :- require_name(Value, required, Name).

json_schema_properties(Properties0, Properties) :-
    dict_pairs(Properties0, _, Pairs0),
    maplist(json_schema_property, Pairs0, Pairs),
    dict_pairs(Properties, json_schema, Pairs).

json_schema_property(Key-Schema0, Key-Schema) :- json_schema(Schema0, Schema).

/* Trusted executable binding import ----------------------------------- */

agent_zero_tool_pack_manifest(Units, Category0, Outcome) :-
    catch(( must_be(list, Units),
            require_name(Category0, category, Category),
            findall(Export,
                    ( member(Unit, Units),
                      declaration_category(Unit, Category),
                      agent_zero_tool_declaration(Unit, Declaration),
                      declaration_export(Declaration, Export) ),
                    Exports0),
            sort(Exports0, Exports),
            unique_export_names(Exports),
            Outcome = ok(tool_pack_manifest{library:agent_zero,
                                            category:Category,
                                            tools:Exports})
          ),
          Exception,
          adapter_exception(tool_pack_manifest, Exception, Outcome)).

declaration_category(Unit, Category) :-
    ( get_dict(category, Unit, Category0)
    -> require_name(Category0, category, Declared)
    ; Declared = agent_zero
    ),
    Declared == Category.

declaration_export(Declaration, Export) :-
    get_dict(name, Declaration, Name),
    get_dict(schema, Declaration, Schema),
    get_dict(capability, Schema, Capability),
    get_dict(effect, Schema, Effect),
    Export = tool_export{name:Name,
                         capability:Capability,
                         effect:Effect}.

unique_export_names(Exports) :-
    findall(Name, (member(Export, Exports), Name = Export.name), Names),
    sort(Names, Unique),
    length(Names, Count),
    length(Unique, Count),
    !.
unique_export_names(_) :- throw(agent_zero_fault(duplicate_tool_name)).

agent_zero_tool_registry_import(Registry, Units, HostHandler, Outcome) :-
    catch(( must_be(list, Units),
            callable(HostHandler),
            ground(HostHandler),
            findall(Declaration,
                    ( member(Unit, Units),
                      agent_zero_tool_declaration(Unit, Declaration) ),
                    Declarations),
            unique_declaration_names(Declarations),
            register_declarations(Declarations, Registry, HostHandler, Schemas),
            length(Schemas, Count),
            Outcome = ok(agent_zero_tool_import{count:Count, schemas:Schemas})
          ),
          Exception,
          adapter_exception(tool_registry_import, Exception, Outcome)).

agent_zero_tool_declaration(Unit, declaration{name:Name, schema:Schema}) :-
    require_unit_dict(Unit),
    unit_format(Unit, Format),
    memberchk(Format, [agent_zero_tool,agent_zero_context]),
    unit_kind(Unit, Format, Kind),
    memberchk(Kind, [tool,mcp_tool]),
    get_dict(name, Unit, Name0),
    require_name(Name0, name, Name),
    dict_text(Unit, description, Name0, Description),
    unit_capability(tool(Name), Capability),
    unit_schema(tool, Unit, Name, Description, Capability, Schema).

unique_declaration_names(Declarations) :-
    findall(Name, member(declaration{name:Name}, Declarations), Names),
    sort(Names, Unique),
    length(Names, Count),
    length(Unique, Count),
    !.
unique_declaration_names(_) :- throw(agent_zero_fault(duplicate_tool_name)).

register_declarations([], _, _, []).
register_declarations([Declaration|Declarations], Registry, HostHandler,
                      [Schema|Schemas]) :-
    Declaration = declaration{name:Name, schema:Schema},
    Handler = rlm_agent_zero_adapter:call_host_tool(HostHandler, Name),
    rlm_tool:tool_register(Registry, Schema, Handler, Registration),
    require_ok(Registration, _),
    register_declarations(Declarations, Registry, HostHandler, Schemas).

call_host_tool(HostHandler, Name, Args, Result) :-
    call(HostHandler, Name, Args, Result).

/* Outcomes ------------------------------------------------------------- */

require_context_request(Request) :-
    ( is_dict(Request), get_dict(message, Request, _), get_dict(units, Request, _)
    -> true
    ; throw(agent_zero_fault(invalid_request(Request)))
    ).

require_ok(ok(Value), Value) :- !.
require_ok(error(Error), _) :- throw(agent_zero_fault(dependency_error(Error))).
require_ok(Outcome, _) :- throw(agent_zero_fault(unexpected_outcome(Outcome))).

adapter_exception(Operation, agent_zero_fault(Detail), error(Error)) :-
    !,
    Error = agent_zero_adapter_error{kind:invalid_agent_zero_context,
                                     operation:Operation,
                                     detail:Detail,
                                     message:"Agent Zero metadata was rejected"}.
adapter_exception(Operation, error(Type, Context), error(Error)) :-
    !,
    Error = agent_zero_adapter_error{kind:invalid_agent_zero_context,
                                     operation:Operation,
                                     detail:Type,
                                     context:Context,
                                     message:"Agent Zero metadata was rejected"}.
adapter_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = agent_zero_adapter_error{kind:agent_zero_adapter_failure,
                                     operation:Operation,
                                     exception:Safe,
                                     message:"Agent Zero adaptation failed"}.
