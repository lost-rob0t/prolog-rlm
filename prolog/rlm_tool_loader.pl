:- module(rlm_tool_loader,
          [ tool_pack/2,
            tool_pack_manifest/2,
            rlm_tool_packs/1,
            rlm_tool_libraries/1,
            rlm_tool_categories/1,
            rlm_tool_catalog/1,
            rlm_load_tools/3,
            rlm_load_all_tools/2,
            rlm_tool_loader_forget_registry/1
          ]).

/** <module> External tool-library loading boundary

Core owns the loading ABI, registry contract and policy boundary. Concrete tools
remain in external libraries.

The original trusted loader declaration remains supported:

  :- multifile rlm_tool_loader:tool_pack/2.

  rlm_tool_loader:tool_pack(my_filesystem_pack,
                            my_tools:load_filesystem_pack).

Category-aware libraries additionally publish a sanitized declarative manifest:

  :- multifile rlm_tool_loader:tool_pack_manifest/2.

  rlm_tool_loader:tool_pack_manifest(
      my_filesystem_pack,
      tool_pack_manifest{
          library:my_tools,
          category:filesystem,
          tools:[tool_export{name:project_read,
                             capability:tool(project_read),
                             effect:read}]
      }).

A pack is one deterministic loading unit and advertises exactly one category.
A library contributes multiple categories by declaring multiple packs with the
same `library` value. Multiple libraries may contribute packs to one category.

A trusted loader has shape Loader(+Registry,-Outcome). Loader callables are
never returned by catalog/discovery predicates. Loading only makes registered
tools available: it grants no capabilities, changes no authority mode, starts
no services and installs nothing implicitly.

`rlm_load_tools/3` first interprets its selector as a declared category. For
backward compatibility, a selector that is not a category but is an exact pack
name loads that pack directly. Repeated loads reuse the recorded successful pack
load for the same registry and never call the trusted loader twice.
*/

:- use_module(library(lists)).
:- use_module(rlm_authority, []).
:- use_module(rlm_tool, []).

:- multifile tool_pack/2.
:- multifile tool_pack_manifest/2.
:- multifile rlm_tool:tool_registry_destroy_hook/1.

:- dynamic loaded_tool_pack/4.

rlm_tool:tool_registry_destroy_hook(Registry) :-
    rlm_tool_loader:rlm_tool_loader_forget_registry(Registry).

rlm_tool_packs(Packs) :-
    findall(Name, tool_pack(Name, _), Names0),
    sort(Names0, Packs).

rlm_tool_libraries(Libraries) :-
    rlm_tool_packs(Packs),
    findall(Library,
            ( member(Pack, Packs),
              pack_manifest_result(Pack, ok(Info)),
              Library = Info.library
            ),
            Libraries0),
    sort(Libraries0, Libraries).

rlm_tool_categories(Categories) :-
    rlm_tool_packs(Packs),
    findall(Category,
            ( member(Pack, Packs),
              pack_manifest_result(Pack, ok(Info)),
              Category = Info.category,
              Category \== legacy
            ),
            Categories0),
    sort(Categories0, Categories).

rlm_tool_catalog(Catalog) :-
    rlm_tool_packs(Packs),
    maplist(pack_catalog_entry, Packs, Catalog).

pack_catalog_entry(Pack, Entry) :-
    pack_manifest_result(Pack, Result),
    pack_catalog_result(Result, Pack, Entry).

pack_catalog_result(ok(Info), _,
                    tool_pack_info{pack:Info.pack,
                                   library:Info.library,
                                   category:Info.category,
                                   tools:Info.tools,
                                   status:declared}) :- !.
pack_catalog_result(error(Error), Pack,
                    tool_pack_info{pack:Pack,
                                   status:invalid,
                                   error_kind:Error.kind}).

rlm_load_tools(Registry, Selector, Outcome) :-
    catch(rlm_load_tools_(Registry, Selector, Outcome),
          Exception,
          loader_exception(Selector, Exception, Outcome)).

rlm_load_tools_(Registry, Selector, Outcome) :-
    require_selector_name(Selector),
    (   category_declared(Selector)
    ->  load_category(Registry, Selector, Outcome)
    ;   pack_declared(Selector)
    ->  load_pack_selector(Registry, Selector, Outcome)
    ;   rlm_tool_categories(Categories),
        rlm_tool_packs(Packs),
        Outcome = error(tool_loader_error{
                            kind:unknown_tool_category,
                            category:Selector,
                            valid_categories:Categories,
                            declared_packs:Packs,
                            message:"tool category is not declared"
                        })
    ).

category_declared(Category) :-
    rlm_tool_categories(Categories),
    memberchk(Category, Categories).

pack_declared(Pack) :-
    once(tool_pack(Pack, _)).

load_category(Registry, Category, Outcome) :-
    category_pack_infos(Category, InfosOutcome),
    load_category_infos(InfosOutcome, Registry, Category, Outcome).

category_pack_infos(Category, Outcome) :-
    rlm_tool_packs(Packs),
    collect_category_infos(Packs, Category, [], Infos0, CollectOutcome),
    (   CollectOutcome = error(_)
    ->  Outcome = CollectOutcome
    ;   sort_infos(Infos0, Infos),
        Outcome = ok(Infos)
    ).

collect_category_infos([], _, Infos, Infos, ok) :- !.
collect_category_infos([Pack|Packs], Category, Infos0, Infos, Outcome) :-
    pack_manifest_result(Pack, ManifestOutcome),
    collect_category_manifest(ManifestOutcome,
                              Pack,
                              Packs,
                              Category,
                              Infos0,
                              Infos,
                              Outcome).

collect_category_manifest(error(Error), Pack, _, Category, _, _,
                          error(tool_loader_error{
                                    kind:invalid_tool_pack_manifest,
                                    pack:Pack,
                                    category:Category,
                                    cause:Error,
                                    message:"tool pack manifest is invalid"
                                })) :- !.
collect_category_manifest(ok(Info), _, Packs, Category, Infos0, Infos,
                          Outcome) :-
    (   Info.category == Category
    ->  Infos1 = [Info|Infos0]
    ;   Infos1 = Infos0
    ),
    collect_category_infos(Packs, Category, Infos1, Infos, Outcome).

sort_infos(Infos0, Infos) :-
    findall(Pack-Info,
            ( member(Info, Infos0), Pack = Info.pack ),
            Pairs0),
    keysort(Pairs0, Pairs),
    pairs_values(Pairs, Infos).

pairs_values([], []).
pairs_values([_-Value|Pairs], [Value|Values]) :-
    pairs_values(Pairs, Values).

load_category_infos(error(Error), _, _, error(Error)) :- !.
load_category_infos(ok([]), _, Category,
                    error(tool_loader_error{
                              kind:unknown_tool_category,
                              category:Category,
                              valid_categories:[],
                              message:"tool category has no loadable packs"
                          })) :- !.
load_category_infos(ok(Infos), Registry, Category, Outcome) :-
    preflight_infos(Registry, Infos, Preflight),
    load_category_after_preflight(Preflight, Infos, Registry, Category, Outcome).

load_category_after_preflight(error(Error), _, _, _, error(Error)) :- !.
load_category_after_preflight(ok, Infos, Registry, Category, Outcome) :-
    load_infos(Infos, Registry, [], LoadOutcome),
    (   LoadOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   LoadOutcome = ok(Loaded),
        Outcome = ok(tool_category_load{category:Category,
                                        packs:Loaded})
    ).

load_pack_selector(Registry, Pack, Outcome) :-
    pack_manifest_result(Pack, ManifestOutcome),
    load_pack_manifest(ManifestOutcome, Registry, Pack, Outcome).

load_pack_manifest(error(Error), _, Pack,
                   error(tool_loader_error{
                             kind:invalid_tool_pack_manifest,
                             pack:Pack,
                             cause:Error,
                             message:"tool pack manifest is invalid"
                         })) :- !.
load_pack_manifest(ok(Info), Registry, _, Outcome) :-
    preflight_infos(Registry, [Info], Preflight),
    (   Preflight = error(Error)
    ->  Outcome = error(Error)
    ;   load_info(Info, Registry, Outcome)
    ).

rlm_load_all_tools(Registry, Outcome) :-
    catch(rlm_load_all_tools_(Registry, Outcome),
          Exception,
          loader_exception(all, Exception, Outcome)).

rlm_load_all_tools_(Registry, Outcome) :-
    rlm_tool_packs(Packs),
    collect_all_infos(Packs, [], Infos0, CollectOutcome),
    load_all_infos_after_collect(CollectOutcome, Infos0, Registry, Outcome).

collect_all_infos([], Infos, Infos, ok) :- !.
collect_all_infos([Pack|Packs], Infos0, Infos, Outcome) :-
    pack_manifest_result(Pack, ManifestOutcome),
    (   ManifestOutcome = error(Error)
    ->  Outcome = error(tool_loader_error{
                            kind:invalid_tool_pack_manifest,
                            pack:Pack,
                            cause:Error,
                            message:"tool pack manifest is invalid"
                        })
    ;   ManifestOutcome = ok(Info),
        collect_all_infos(Packs, [Info|Infos0], Infos, Outcome)
    ).

load_all_infos_after_collect(error(Error), _, _, error(Error)) :- !.
load_all_infos_after_collect(ok, Infos0, Registry, Outcome) :-
    sort_infos(Infos0, Infos),
    preflight_infos(Registry, Infos, Preflight),
    load_all_infos_after_preflight(Preflight, Infos, Registry, Outcome).

load_all_infos_after_preflight(error(Error), _, _, error(Error)) :- !.
load_all_infos_after_preflight(ok, Infos, Registry, Outcome) :-
    load_infos(Infos, Registry, [], LoadOutcome),
    (   LoadOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   LoadOutcome = ok(Loaded),
        Outcome = ok(tool_pack_load_all{packs:Loaded})
    ).

load_infos([], _, Loaded, ok(Loaded)) :- !.
load_infos([Info|Infos], Registry, Loaded0, Outcome) :-
    load_info(Info, Registry, OneOutcome),
    (   OneOutcome = error(Error)
    ->  Outcome = error(Error)
    ;   OneOutcome = ok(Value),
        append(Loaded0, [Value], Loaded),
        load_infos(Infos, Registry, Loaded, Outcome)
    ).

load_info(Info, Registry, Outcome) :-
    Pack = Info.pack,
    (   loaded_tool_pack(Registry, Pack, StoredInfo, StoredResult)
    ->  Outcome = ok(tool_pack_load{pack:Pack,
                                    library:StoredInfo.library,
                                    category:StoredInfo.category,
                                    status:reused,
                                    result:StoredResult})
    ;   findall(Loader, tool_pack(Pack, Loader), Loaders),
        load_declared_pack(Loaders, Registry, Info, Outcome)
    ).

load_declared_pack([], _, Info,
                   error(tool_loader_error{
                             kind:unknown_tool_pack,
                             pack:Info.pack,
                             message:"tool pack has no loader declaration"
                         })) :- !.
load_declared_pack([Loader], Registry, Info, Outcome) :-
    !,
    require_pack_loader(Loader),
    call_pack_loader(Loader, Registry, Info, Outcome).
load_declared_pack(Loaders, _, Info,
                   error(tool_loader_error{
                             kind:ambiguous_tool_pack,
                             pack:Info.pack,
                             declarations:Count,
                             message:"tool pack has multiple loader declarations"
                         })) :-
    length(Loaders, Count).

call_pack_loader(Loader, Registry, Info, Outcome) :-
    Pack = Info.pack,
    (   call(Loader, Registry, RawOutcome)
    ->  normalize_loader_outcome(RawOutcome, Pack, Normalized),
        remember_successful_load(Normalized, Registry, Info, Outcome)
    ;   Outcome = error(tool_loader_error{
                           kind:loader_failed,
                           pack:Pack,
                           message:"tool pack loader failed without an outcome"
                       })
    ).

remember_successful_load(error(Error), _, _, error(Error)) :- !.
remember_successful_load(ok(Value), Registry, Info, Outcome) :-
    assertz(loaded_tool_pack(Registry, Info.pack, Info, Value)),
    finalize_successful_load(Registry, Info, Value, Outcome).

finalize_successful_load(Registry, Info, Value, Outcome) :-
    (   registry_still_alive(Registry)
    ->  Outcome = ok(tool_pack_load{pack:Info.pack,
                                    library:Info.library,
                                    category:Info.category,
                                    status:loaded,
                                    result:Value})
    ;   rlm_tool_loader_forget_registry(Registry),
        Outcome = error(tool_loader_error{
                            kind:registry_destroyed,
                            pack:Info.pack,
                            message:"tool registry was destroyed while pack was loading"
                        })
    ).

registry_still_alive(tool_registry(Id)) :-
    rlm_tool:tool_registry_alive(Id).

normalize_loader_outcome(ok(Value), _, ok(Value)) :- !.
normalize_loader_outcome(error(Error), _, error(Error)) :- !.
normalize_loader_outcome(Raw, Pack,
                         error(tool_loader_error{
                                   kind:invalid_loader_outcome,
                                   pack:Pack,
                                   detail:Shape,
                                   message:"tool pack loader must return ok/1 or error/1"
                               })) :-
    value_shape(Raw, Shape).

preflight_infos(Registry, Infos, Outcome) :-
    candidate_conflict(Infos, CandidateConflict),
    preflight_after_candidate(CandidateConflict, Registry, Infos, Outcome).

preflight_after_candidate(error(Error), _, _, error(Error)) :- !.
preflight_after_candidate(ok, Registry, Infos, Outcome) :-
    loaded_conflict(Registry, Infos, LoadedConflict),
    preflight_after_loaded(LoadedConflict, Registry, Infos, Outcome).

preflight_after_loaded(error(Error), _, _, error(Error)) :- !.
preflight_after_loaded(ok, Registry, Infos, Outcome) :-
    registry_conflict(Registry, Infos, Outcome).

candidate_conflict(Infos, Outcome) :-
    (   member(InfoA, Infos),
        member(InfoB, Infos),
        InfoA.pack @< InfoB.pack,
        shared_tool_name(InfoA, InfoB, Name)
    ->  conflict_error(Name, InfoA, InfoB, Outcome)
    ;   Outcome = ok
    ).

loaded_conflict(Registry, Infos, Outcome) :-
    (   member(Info, Infos),
        \+ loaded_tool_pack(Registry, Info.pack, _, _),
        loaded_tool_pack(Registry, OtherPack, OtherInfo, _),
        OtherPack \== Info.pack,
        shared_tool_name(Info, OtherInfo, Name)
    ->  conflict_error(Name, Info, OtherInfo, Outcome)
    ;   Outcome = ok
    ).

registry_conflict(Registry, Infos, Outcome) :-
    (   member(Info, Infos),
        \+ loaded_tool_pack(Registry, Info.pack, _, _),
        tool_name_in_info(Info, Name),
        rlm_tool:tool_lookup(Registry, Name, ok(_)),
        \+ loaded_tool_name(Registry, Name)
    ->  Outcome = error(tool_loader_error{
                            kind:tool_name_conflict,
                            tool:Name,
                            contributors:[tool_contributor{pack:Info.pack,
                                                           library:Info.library,
                                                           category:Info.category},
                                          existing_registry],
                            message:"declared tool name is already registered outside this loader"
                        })
    ;   Outcome = ok
    ).

loaded_tool_name(Registry, Name) :-
    loaded_tool_pack(Registry, _, Info, _),
    tool_name_in_info(Info, Name),
    !.

conflict_error(Name, InfoA, InfoB,
               error(tool_loader_error{
                         kind:tool_name_conflict,
                         tool:Name,
                         contributors:[tool_contributor{pack:InfoA.pack,
                                                        library:InfoA.library,
                                                        category:InfoA.category},
                                       tool_contributor{pack:InfoB.pack,
                                                        library:InfoB.library,
                                                        category:InfoB.category}],
                         message:"multiple tool packs advertise the same tool name"
                     })).

shared_tool_name(InfoA, InfoB, Name) :-
    tool_name_in_info(InfoA, Name),
    tool_name_in_info(InfoB, Name),
    !.

tool_name_in_info(Info, Name) :-
    member(Export, Info.tools),
    Name = Export.name.

pack_manifest_result(Pack, Outcome) :-
    findall(Manifest, tool_pack_manifest(Pack, Manifest), Manifests),
    manifest_declarations(Pack, Manifests, Outcome).

manifest_declarations(Pack, [],
                      ok(tool_pack_info{pack:Pack,
                                        library:Pack,
                                        category:legacy,
                                        tools:[]})) :- !.
manifest_declarations(Pack, [Manifest], Outcome) :-
    !,
    catch(( normalize_manifest(Pack, Manifest, Info), Outcome = ok(Info) ),
          Exception,
          manifest_exception(Pack, Exception, Outcome)).
manifest_declarations(Pack, Manifests,
                      error(tool_loader_error{
                                kind:duplicate_tool_pack_manifest,
                                pack:Pack,
                                declarations:Count,
                                message:"tool pack has multiple manifest declarations"
                            })) :-
    length(Manifests, Count).

normalize_manifest(Pack, Manifest,
                   tool_pack_info{pack:Pack,
                                  library:Library,
                                  category:Category,
                                  tools:Tools}) :-
    is_dict(Manifest),
    !,
    require_manifest_key(Manifest, library, Library),
    require_manifest_key(Manifest, category, Category),
    require_manifest_key(Manifest, tools, Tools0),
    require_nonempty_atom(Library, library),
    require_nonempty_atom(Category, category),
    require_tool_exports(Tools0, Tools).
normalize_manifest(_, Manifest, _) :-
    throw(tool_manifest_fault(invalid_manifest(Manifest))).

require_manifest_key(Manifest, Key, Value) :-
    (   get_dict(Key, Manifest, Value)
    ->  true
    ;   throw(tool_manifest_fault(missing_field(Key)))
    ).

require_nonempty_atom(Value, _) :-
    atom(Value),
    Value \== '',
    !.
require_nonempty_atom(Value, Field) :-
    throw(tool_manifest_fault(invalid_atom(Field, Value))).

require_tool_exports(Tools0, Tools) :-
    is_list(Tools0),
    !,
    maplist(normalize_tool_export, Tools0, Tools),
    maplist(export_name, Tools, Names),
    sort(Names, Unique),
    length(Names, Count),
    length(Unique, Count),
    !.
require_tool_exports(Tools, _) :-
    throw(tool_manifest_fault(invalid_tool_exports(Tools))).

normalize_tool_export(Export0,
                      tool_export{name:Name,
                                  capability:Capability,
                                  effect:Effect}) :-
    is_dict(Export0),
    !,
    require_manifest_key(Export0, name, Name),
    require_manifest_key(Export0, capability, Capability),
    require_manifest_key(Export0, effect, Effect),
    require_nonempty_atom(Name, tool_name),
    ground(Capability),
    rlm_tool:capabilities_normalize([Capability], ok(_)),
    atom(Effect),
    rlm_authority:rlm_effect_class(Effect),
    !.
normalize_tool_export(Export, _) :-
    throw(tool_manifest_fault(invalid_tool_export(Export))).

export_name(Export, Export.name).

manifest_exception(_, tool_manifest_fault(Detail), error(Error)) :-
    !,
    Error = tool_loader_error{kind:invalid_tool_pack_manifest,
                              detail:Detail,
                              message:"tool pack manifest is invalid"}.
manifest_exception(_, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = tool_loader_error{kind:invalid_tool_pack_manifest,
                              exception:Safe,
                              message:"tool pack manifest validation failed"}.

require_selector_name(Name) :-
    atom(Name),
    Name \== '',
    !.
require_selector_name(Name) :-
    throw(tool_loader_fault(invalid_selector_name(Name))).

require_pack_loader(Loader) :-
    callable(Loader),
    ground(Loader),
    !.
require_pack_loader(Loader) :-
    throw(tool_loader_fault(invalid_pack_loader(Loader))).

rlm_tool_loader_forget_registry(Registry) :-
    retractall(loaded_tool_pack(Registry, _, _, _)).

loader_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
loader_exception(Selector, tool_loader_fault(Detail), error(Error)) :-
    !,
    Error = tool_loader_error{
                kind:invalid_tool_pack_operation,
                selector:Selector,
                detail:Detail,
                message:"tool loading operation is invalid"
            }.
loader_exception(Selector, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = tool_loader_error{
                kind:loader_exception,
                selector:Selector,
                exception:Safe,
                message:"tool pack loader raised an exception"
            }.

value_shape(Value, variable) :- var(Value), !.
value_shape(Value, dict) :- is_dict(Value), !.
value_shape(Value, list) :- is_list(Value), !.
value_shape(Value, Name/Arity) :- compound(Value), !, functor(Value, Name, Arity).
value_shape(Value, atom) :- atom(Value), !.
value_shape(Value, string) :- string(Value), !.
value_shape(Value, number) :- number(Value), !.
value_shape(_, other).

control_exception(rlm_async_cancelled(_)).
control_exception(rlm_cancelled(_)).
control_exception(chain_cancelled(_)).
control_exception(graph_cancelled(_)).
control_exception(cancelled(_)).
control_exception('$aborted').
control_exception(abort).
