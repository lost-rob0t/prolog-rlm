:- module(rlm_project_semantic_pack,
          [ rlm_project_semantic_pack_ready/0,
            project_semantic_pack_languages/1,
            project_semantic_pack_register/3,
            project_semantic_pack_activate/3,
            project_semantic_pack_source/3,
            project_semantic_standard_purposes/1,
            language_analysis_capability/2,
            project_semantic_adapter_register/3
          ]).

/** <module> Inert standard semantic adapter packs

This module is the language adapter table above the generic query-pack
system.  Each entry binds a language and analysis purpose to a Tree-sitter
query source whose capture names carry the semantic protocol:

```text
@<relation>                    principal observation node
@<relation>.<kind>             principal with an explicit closed symbol_kind
@<relation>.name               defining/using name text
@<relation>.callee             call target name
@<relation>.target             import target text
@<relation>.alias              import alias name
@<relation>.keyword            language keyword text (kind disambiguation)
```

Pack sources are inert data consumed by Tree-sitter exactly like the #97
query packs; they are never parsed as Prolog, called, or consulted.  Register
and activate are separate trusted-host operations.  Registration never grants
filesystem, process, network, tool, capability, or authority access.

`language_analysis_capability/2` is the closed per-language capability
declaration from issue #98: a purpose without a capability row reports
`unsupported` instead of masquerading as zero matches.
*/

:- use_module(library(apply)).
:- use_module(library(lists)).
:- use_module(rlm_project_query).
:- use_module(rlm_project_source).

:- dynamic semantic_adapter_entry_/3.

rlm_project_semantic_pack_ready.

/* Standard adapter table ---------------------------------------------- */

%% Host-registered adapters shadow the standard table per language: a
%% language with registered entries never falls through to the standard
%% clauses, so a host can replace pack data for a standard language too.
project_semantic_pack_source(Language, Purpose, Source) :-
    semantic_adapter_entry_(Language, Purpose, Source),
    !.

% Python: definitions, references (attribute usage), calls, imports.
project_semantic_pack_source(python, definitions,
                             "(function_definition name: (identifier) @definition.name) @definition.function\n\c                              (class_definition name: (identifier) @definition.name) @definition.class").
project_semantic_pack_source(python, references,
                             "(attribute attribute: (identifier) @reference.name) @reference").
project_semantic_pack_source(python, calls,
                             "(call function: (identifier) @call.callee) @call").
project_semantic_pack_source(python, imports,
                             "(import_statement name: (dotted_name) @import.target) @import\n\c                              (import_statement name: (aliased_import name: (dotted_name) @import.target alias: (identifier) @import.alias)) @import\n\c                              (import_from_statement module_name: (dotted_name) @import.target) @import").

% JavaScript/TypeScript share the javascript grammar path here; TypeScript
% grammars may be host-registered and flow through the same packs.
project_semantic_pack_source(javascript, definitions,
                             "(function_declaration name: (identifier) @definition.name) @definition.function\n\c                              (class_declaration name: (identifier) @definition.name) @definition.class\n\c                              (method_definition name: (property_identifier) @definition.name) @definition.method\n\c                              (variable_declarator name: (identifier) @definition.name value: (arrow_function)) @definition.function").
project_semantic_pack_source(javascript, references,
                             "(member_expression property: (property_identifier) @reference.name) @reference").
project_semantic_pack_source(javascript, calls,
                             "(call_expression function: (identifier) @call.callee) @call").
project_semantic_pack_source(javascript, imports,
                             "(import_statement source: (string) @import.target) @import").
project_semantic_pack_source(javascript, exports,
                             "(export_statement (function_declaration (identifier) @export.name)) @export\n\c                              (export_statement (class_declaration (identifier) @export.name)) @export").

% Common Lisp: S-expression family with keyword-disambiguated definitions.
% Calls require a following element so parameter lists such as (x) are not
% mistaken for zero-argument calls; zero-argument calls are an explicit
% limitation of this initial adapter.  Package systems live outside source
% syntax, so imports/exports are declared unsupported.
project_semantic_pack_source(common_lisp, definitions,
                             "(defun (defun_header (defun_keyword) @definition.keyword . (sym_lit) @definition.name)) @definition").
project_semantic_pack_source(common_lisp, calls,
                             "(list_lit . \"(\" (sym_lit) @call.callee (_)) @call").

%% Host-registered adapters ------------------------------------------------
%% Additional languages (e.g. a host-registered tree-sitter-typescript
%% grammar mapped onto the `typescript` language identity) flow through the
%% same protocol via project_semantic_adapter_register/3.  This is a
%% trusted-host inert-data operation: it declares capabilities and pack
%% sources and never loads a grammar, activates a pack, or grants any
%% authority.  Registered adapters shadow the standard table per language;
%% the standard languages keep their declarations.

project_semantic_adapter_register(Language0, PackSources0, Outcome) :-
    catch(project_semantic_adapter_register_(Language0,
                                             PackSources0,
                                             Outcome),
          Exception,
          semantic_pack_exception(adapter_register, Exception, Outcome)).

project_semantic_adapter_register_(Language0, PackSources0, Outcome) :-
    normalize_language(Language0, Language),
    require_pack_source_list(PackSources0, PackSources),
    retractall(semantic_adapter_entry_(Language, _, _)),
    forall(member(Purpose-Source, PackSources),
           assertz(semantic_adapter_entry_(Language, Purpose, Source))),
    Outcome = ok(registered(Language)).

require_pack_source_list(PackSources0, PackSources) :-
    (   is_list(PackSources0),
        PackSources0 \== []
    ->  maplist(validate_pack_source, PackSources0),
        findall(Purpose, member(Purpose-_, PackSources0), Purposes0),
        sort(Purposes0, UniquePurposes),
        length(UniquePurposes, PurposeCount),
        length(PackSources0, SourceCount),
        (   SourceCount == PurposeCount
        ->  sort(PackSources0, PackSources)
        ;   throw(project_semantic_fault(invalid_pack_source(duplicate)))
        )
    ;   throw(project_semantic_fault(invalid_pack_source(PackSources0)))
    ).

validate_pack_source(Purpose-Source) :-
    semantic_purpose_valid(Purpose),
    (   ( string(Source) ; ( atom(Source), Source \== '' ) )
    ->  true
    ;   throw(project_semantic_fault(invalid_pack_source(Purpose)))
    ).
validate_pack_source(Other) :-
    throw(project_semantic_fault(invalid_pack_source(Other))).

semantic_purpose_valid(Purpose) :-
    memberchk(Purpose,
              [definitions, references, calls, imports, exports]).

/* Capabilities ---------------------------------------------------------- */

language_analysis_capability(Language, Purpose) :-
    semantic_adapter_entry_(Language, Purpose, _).

language_analysis_capability(python, definitions).
language_analysis_capability(python, references).
language_analysis_capability(python, calls).
language_analysis_capability(python, imports).
language_analysis_capability(javascript, definitions).
language_analysis_capability(javascript, references).
language_analysis_capability(javascript, calls).
language_analysis_capability(javascript, imports).
language_analysis_capability(javascript, exports).
language_analysis_capability(common_lisp, definitions).
language_analysis_capability(common_lisp, calls).

project_semantic_pack_languages([common_lisp, javascript, python]).

project_semantic_standard_purposes([calls, definitions, exports, imports, references]).

/* Registration ------------------------------------------------------------ */

project_semantic_pack_register(Registry, Language0, Outcome) :-
    catch(project_semantic_pack_register_(Registry, Language0, Outcome),
          Exception,
          semantic_pack_exception(pack_register, Exception, Outcome)).

project_semantic_pack_register_(Registry, Language0, Outcome) :-
    normalize_language(Language0, Language),
    capability_languages(Language),
    findall(Purpose-RegisterOutcome,
            ( project_semantic_pack_source(Language, Purpose, Source),
              project_query_pack_register(Registry,
                                          Language,
                                          Purpose,
                                          Source,
                                          _{version:semantic_pack_version,
                                            provenance:_{origin:prolog_rlm_standard_semantic_pack}},
                                          RegisterOutcome)
            ),
            RegisterOutcomes),
    require_pack_outcomes(RegisterOutcomes),
    Outcome = ok(registered(Language)).

require_pack_outcomes([]).
require_pack_outcomes([_-ok(_)|Rest]) :- !,
    require_pack_outcomes(Rest).
require_pack_outcomes([_-Outcome|_]) :-
    var(Outcome),
    !,
    throw(project_semantic_fault(pack_registration_failed(unbound, Outcome))).
require_pack_outcomes([Purpose-Outcome|_]) :-
    throw(project_semantic_fault(pack_registration_failed(Purpose, Outcome))).

capability_languages(Language) :-
    language_analysis_capability(Language, _),
    !.
capability_languages(Language) :-
    throw(project_semantic_fault(no_semantic_adapter(Language))).

normalize_language(Value, Language) :-
    ( atom(Value) ; string(Value) ),
    \+ ( string(Value), Value == "" ),
    \+ ( atom(Value), Value == '' ),
    !,
    normalize_text(Value, Language).
normalize_language(Value, _) :-
    throw(project_semantic_fault(invalid_language(Value))).

normalize_text(Value, Atom) :-
    atom(Value),
    !,
    Atom = Value.
normalize_text(Value, Atom) :-
    string(Value),
    !,
    atom_string(Atom, Value).

project_semantic_pack_activate(Registry, Language0, Outcome) :-
    catch(project_semantic_pack_activate_(Registry, Language0, Outcome),
          Exception,
          semantic_pack_exception(pack_activate, Exception, Outcome)).

project_semantic_pack_activate_(Registry, Language0, Outcome) :-
    normalize_language(Language0, Language),
    capability_languages(Language),
    findall(Purpose-ActivateOutcome,
            ( language_analysis_capability(Language, Purpose),
              project_semantic_pack_source(Language, Purpose, _),
              project_query_pack_activate(Registry, Language, Purpose, ActivateOutcome)
            ),
            ActivateOutcomes),
    require_pack_outcomes(ActivateOutcomes),
    Outcome = ok(activated(Language)).

semantic_pack_exception(Operation, project_semantic_fault(Fault), error(Error)) :-
    !,
    Error = project_semantic_error{kind:pack_fault,
                                   operation:Operation,
                                   detail:Fault,
                                   message:"project semantic pack operation failed"}.
semantic_pack_exception(Operation, Exception, error(Error)) :-
    Error = project_semantic_error{kind:pack_exception,
                                   operation:Operation,
                                   exception:Exception,
                                   message:"project semantic pack operation raised an exception"}.
