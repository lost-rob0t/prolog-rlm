:- module(rlm_project_source,
          [ rlm_project_source_ready/0,
             project_source_registry_create/1,
             project_source_registry_destroy/1,
             project_source_registry_valid/1,
            project_source_project_register/4,
            project_source_project/3,
            project_source_file_register/4,
            project_source_project_file/3,
            project_source_file/3,
            project_source_language_register/5,
            project_source_language_parser/3,
            project_source_file_language/3,
            project_source_language_evidence/5,
            project_source_file_language_override/5,
            extension_language/2,
            ts_grammar_register/4,
            ts_grammar_unregister/3,
            ts_grammar/3,
            ts_grammars/2,
            ts_grammar_activate/3,
             ts_grammar_deactivate/3,
             parser_for_file/3,
             grammar_for_file/3,
             project_source_tree_parse/5
          ]).

/** <module> Declarative Project/source and Tree-sitter grammar registry

This is the Prolog-side source registry tracked by #95. It owns Project/File/
Language relationships, explicit language-detection evidence, parser backend
selection and declarative Tree-sitter grammar records.

It does not parse source or materialize syntax facts. Grammar registration is
inert data. `ts_grammar_activate/3` is a separate trusted-host operation that can
cross the #94 native boundary only when `rlm_tree_sitter` is already loaded by
the host. Registry data never grants filesystem, process, network, tool or
execution authority.

Project identities here are epistemic source identities. A host can reuse or
reference the canonical security-sensitive ProjectIdentity from #75; this
module does not invent a competing authorization identity.
*/

:- use_module(library(crypto)).
:- use_module(library(gensym)).
:- use_module(library(lists)).
:- use_module(library(pairs)).

:- dynamic project_source_registry_alive/1.
:- dynamic project_source_project_record/3.
:- dynamic project_source_file_record/4.
:- dynamic project_source_language_record/4.
:- dynamic project_source_language_override/4.
:- dynamic project_source_grammar_record/3.
:- dynamic project_source_grammar_active/4.

rlm_project_source_ready.

/* Registry ------------------------------------------------------------ */

project_source_registry_create(project_source_registry(Id)) :-
    with_mutex(rlm_project_source_registry,
               ( gensym(source_registry_, Id),
                 assertz(project_source_registry_alive(Id))
               )).

project_source_registry_destroy(project_source_registry(Id)) :-
    with_mutex(rlm_project_source_registry,
               ( findall(Handle,
                         project_source_grammar_active(Id, _, Handle, _),
                         Handles),
                 retractall(project_source_grammar_active(Id, _, _, _)),
                 retractall(project_source_grammar_record(Id, _, _)),
                 retractall(project_source_language_override(Id, _, _, _)),
                 retractall(project_source_language_record(Id, _, _, _)),
                 retractall(project_source_file_record(Id, _, _, _)),
                 retractall(project_source_project_record(Id, _, _)),
                 retractall(project_source_registry_alive(Id))
                )),
    clear_project_syntax_safely(project_source_registry(Id)),
    maplist(close_language_handle_safely, Handles).

project_source_registry_valid(Registry) :-
    registry_id(Registry, _).

registry_id(project_source_registry(Id), Id) :-
    project_source_registry_alive(Id),
    !.
registry_id(Registry, _) :-
    throw(project_source_fault(invalid_registry(Registry))).

/* Project and file facts --------------------------------------------- */

project_source_project_register(Registry, Project0, Meta0, Outcome) :-
    catch(project_source_project_register_(Registry, Project0, Meta0, Outcome),
          Exception,
          project_source_exception(project_register, Exception, Outcome)).

project_source_project_register_(Registry, Project0, Meta0, Outcome) :-
    registry_id(Registry, Id),
    normalize_identity(project, Project0, Project),
    normalize_meta(project, Meta0, Meta),
    with_mutex(rlm_project_source_registry,
               register_project(Id, Project, Meta, Outcome)).

register_project(Id, Project, Meta, Outcome) :-
    (   project_source_project_record(Id, Project, Existing)
    ->  (   Existing == Meta
        ->  Outcome = ok(existing(project(Project)))
        ;   throw(project_source_fault(project_already_registered(Project)))
        )
    ;   assertz(project_source_project_record(Id, Project, Meta)),
        Outcome = ok(project(Project))
    ).

project_source_project(Registry, Project, Meta) :-
    registry_id(Registry, Id),
    project_source_project_record(Id, Project, Meta).

project_source_file_register(Registry, Project0, Spec0, Outcome) :-
    catch(project_source_file_register_(Registry, Project0, Spec0, Outcome),
          Exception,
          project_source_exception(file_register, Exception, Outcome)).

project_source_file_register_(Registry, Project0, Spec0, Outcome) :-
    registry_id(Registry, Id),
    normalize_identity(project, Project0, Project),
    require_project(Id, Project),
    normalize_file_spec(Project, Spec0, File, Record),
    with_mutex(rlm_project_source_registry,
               register_file(Id, Project, File, Record, Outcome)).

register_file(Id, Project, File, Record, Outcome) :-
    (   project_source_file_record(Id, _, File, Existing)
    ->  (   Existing == Record
        ->  Outcome = ok(existing(File))
        ;   throw(project_source_fault(file_identity_conflict(File)))
        )
    ;   project_source_file_record(Id, Project, ExistingFile, ExistingRecord),
        ExistingRecord.path == Record.path
    ->  throw(project_source_fault(path_already_registered(Project,
                                                            Record.path,
                                                            ExistingFile)))
    ;   assertz(project_source_file_record(Id, Project, File, Record)),
        Outcome = ok(File)
    ).

project_source_project_file(Registry, Project, File) :-
    registry_id(Registry, Id),
    project_source_file_record(Id, Project, File, _).

project_source_file(Registry, File, Record) :-
    registry_id(Registry, Id),
    project_source_file_record(Id, _, File, Record).

normalize_file_spec(Project, Spec0, File, Record) :-
    require_dict(file_spec, Spec0),
    allowed_keys(file_spec,
                 Spec0,
                 [ id, path, hash, generation, excluded, vendor, generated,
                   shebang, embedded_regions, provenance ]),
    require_dict_key(file_spec, Spec0, path, Path0),
    normalize_text(path, Path0, Path),
    (   get_dict(id, Spec0, LocalId0)
    ->  normalize_identity(file, LocalId0, LocalId)
    ;   with_mutex(rlm_project_source_registry, gensym(file_, LocalId))
    ),
    dict_default(Spec0, hash, unknown, Hash0),
    normalize_hash(Hash0, Hash),
    dict_default(Spec0, generation, 1, Generation),
    require_nonnegative_integer(generation, Generation),
    dict_default(Spec0, excluded, false, Excluded),
    require_boolean(excluded, Excluded),
    dict_default(Spec0, vendor, false, Vendor),
    require_boolean(vendor, Vendor),
    dict_default(Spec0, generated, false, Generated),
    require_boolean(generated, Generated),
    dict_default(Spec0, shebang, none, Shebang0),
    normalize_optional_text(shebang, Shebang0, Shebang),
    dict_default(Spec0, embedded_regions, [], Regions0),
    canonical_data(Regions0, Regions),
    dict_default(Spec0, provenance, _{}, Provenance0),
    normalize_meta(file_provenance, Provenance0, Provenance),
    File = source_file(Project, LocalId),
    Record = source_file_record{
                 identity:File,
                 project:Project,
                 path:Path,
                 hash:Hash,
                 generation:Generation,
                 excluded:Excluded,
                 vendor:Vendor,
                 generated:Generated,
                 shebang:Shebang,
                 embedded_regions:Regions,
                 provenance:Provenance
             }.

require_project(Id, Project) :-
    project_source_project_record(Id, Project, _),
    !.
require_project(_, Project) :-
    throw(project_source_fault(unknown_project(Project))).

/* Language registry and evidence ------------------------------------- */

project_source_language_register(Registry, Language0, Backend0, Meta0, Outcome) :-
    catch(project_source_language_register_(Registry,
                                            Language0,
                                            Backend0,
                                            Meta0,
                                            Outcome),
          Exception,
          project_source_exception(language_register, Exception, Outcome)).

project_source_language_register_(Registry, Language0, Backend0, Meta0, Outcome) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    normalize_backend(Backend0, Backend),
    normalize_language_meta(Meta0, Meta),
    with_mutex(rlm_project_source_registry,
               register_language(Id, Language, Backend, Meta, Outcome)).

register_language(Id, Language, Backend, Meta, Outcome) :-
    (   language_backend(Id, Language, ExistingBackend, ExistingMeta)
    ->  (   ExistingBackend == Backend,
            ExistingMeta == Meta
        ->  Outcome = ok(existing(language(Language)))
        ;   throw(project_source_fault(language_already_registered(Language,
                                                                   ExistingBackend)))
        )
    ;   assertz(project_source_language_record(Id, Language, Backend, Meta)),
        Outcome = ok(language(Language))
    ).

project_source_language_parser(Registry, Language0, Backend) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    language_backend(Id, Language, Backend, _).

language_backend(Id, Language, Backend, Meta) :-
    project_source_language_record(Id, Language, Backend, Meta),
    !.
language_backend(_, Language, Backend, language_meta{origin:builtin}) :-
    builtin_language_parser(Language, Backend).

builtin_language_parser(python, tree_sitter).
builtin_language_parser(javascript, tree_sitter).
builtin_language_parser(typescript, tree_sitter).
builtin_language_parser(nim, tree_sitter).
builtin_language_parser(common_lisp, tree_sitter).
builtin_language_parser(markdown, tree_sitter).
builtin_language_parser(json, tree_sitter).
builtin_language_parser(org, tree_sitter).
builtin_language_parser(c, tree_sitter).
builtin_language_parser(cpp, tree_sitter).
builtin_language_parser(lua, tree_sitter).
builtin_language_parser(shell, tree_sitter).
builtin_language_parser(tree_sitter_query, tree_sitter).
builtin_language_parser(prolog, swi_native).

extension_language('.py', python).
extension_language('.pyw', python).
extension_language('.js', javascript).
extension_language('.jsx', javascript).
extension_language('.mjs', javascript).
extension_language('.cjs', javascript).
extension_language('.ts', typescript).
extension_language('.tsx', typescript).
extension_language('.mts', typescript).
extension_language('.cts', typescript).
extension_language('.nim', nim).
extension_language('.lisp', common_lisp).
extension_language('.lsp', common_lisp).
extension_language('.cl', common_lisp).
extension_language('.asd', common_lisp).
extension_language('.md', markdown).
extension_language('.markdown', markdown).
extension_language('.mdown', markdown).
extension_language('.mkd', markdown).
extension_language('.json', json).
extension_language('.jsonc', json).
extension_language('.jsonl', json).
extension_language('.ndjson', json).
extension_language('.org', org).
extension_language('.pl', prolog).
extension_language('.prolog', prolog).
extension_language('.c', c).
extension_language('.h', c).
extension_language('.cc', cpp).
extension_language('.cpp', cpp).
extension_language('.cxx', cpp).
extension_language('.hpp', cpp).
extension_language('.lua', lua).
extension_language('.sh', shell).
extension_language('.bash', shell).

project_source_language_evidence(Registry, File, Language, Source, Confidence) :-
    registry_id(Registry, Id),
    file_record(Id, File, Record),
    file_language_evidence(Id, Record, Language, Source, Confidence).

file_language_evidence(_, Record, Language, extension(Extension), 0.75) :-
    path_extension(Record.path, Extension),
    extension_language(Extension, Language).
file_language_evidence(Id,
                       Record,
                       Language,
                       registered_extension(Extension),
                       0.9) :-
    path_extension(Record.path, Extension),
    project_source_language_record(Id, Language, _, Meta),
    get_dict(extensions, Meta, Extensions),
    memberchk(Extension, Extensions).
file_language_evidence(_, Record, Language, shebang(Shebang), 0.95) :-
    Record.shebang \== none,
    Shebang = Record.shebang,
    shebang_language(Shebang, Language).

project_source_file_language_override(Registry,
                                      File,
                                      Language0,
                                      Provenance0,
                                      Outcome) :-
    catch(project_source_file_language_override_(Registry,
                                                 File,
                                                 Language0,
                                                 Provenance0,
                                                 Outcome),
          Exception,
          project_source_exception(language_override, Exception, Outcome)).

project_source_file_language_override_(Registry,
                                       File,
                                       Language0,
                                       Provenance0,
                                       Outcome) :-
    registry_id(Registry, Id),
    file_record(Id, File, _),
    normalize_language(Language0, Language),
    normalize_meta(language_override, Provenance0, Provenance),
    with_mutex(rlm_project_source_registry,
               ( retractall(project_source_language_override(Id, File, _, _)),
                 assertz(project_source_language_override(Id,
                                                          File,
                                                          Language,
                                                          Provenance))
               )),
    Outcome = ok(language_override{file:File,
                                   language:Language,
                                   provenance:Provenance}).

project_source_file_language(Registry, File, Outcome) :-
    catch(project_source_file_language_(Registry, File, Outcome),
          Exception,
          project_source_exception(language_resolve, Exception, Outcome)).

project_source_file_language_(Registry, File, Outcome) :-
    registry_id(Registry, Id),
    file_record(Id, File, Record),
    findall(language_evidence{language:Language,
                               source:Source,
                               confidence:Confidence},
            file_language_evidence(Id,
                                   Record,
                                   Language,
                                   Source,
                                   Confidence),
            Evidence),
    (   project_source_language_override(Id, File, Override, Provenance)
    ->  override_resolution(Id,
                            File,
                            Record,
                            Override,
                            Provenance,
                            Evidence,
                            Resolution)
    ;   evidence_resolution(Id, File, Record, Evidence, Resolution)
    ),
    Outcome = ok(Resolution).

override_resolution(Id,
                    File,
                    Record,
                    Language,
                    Provenance,
                    Evidence,
                    Resolution) :-
    (   language_backend(Id, Language, Backend, _)
    ->  Support = known(Backend)
    ;   Support = unsupported(no_parser_backend)
    ),
    Resolution = file_language{
                     file:File,
                     status:explicit_override,
                     language:Language,
                     support:Support,
                     candidates:[Language],
                     evidence:Evidence,
                     override_provenance:Provenance,
                     hash:Record.hash,
                     generation:Record.generation
                 }.

evidence_resolution(Id, File, Record, Evidence, Resolution) :-
    findall(Language,
            ( member(Item, Evidence),
              Language = Item.language
            ),
            Languages0),
    sort(Languages0, Languages),
    evidence_candidates_resolution(Id,
                                   File,
                                   Record,
                                   Evidence,
                                   Languages,
                                   Resolution).

evidence_candidates_resolution(_, File, Record, Evidence, [], Resolution) :-
    Resolution = file_language{
                     file:File,
                     status:unknown,
                     language:unknown,
                     candidates:[],
                     evidence:Evidence,
                     hash:Record.hash,
                     generation:Record.generation
                 }.
evidence_candidates_resolution(Id,
                               File,
                               Record,
                               Evidence,
                               [Language],
                               Resolution) :-
    (   language_backend(Id, Language, Backend, _)
    ->  Resolution = file_language{
                         file:File,
                         status:known,
                         language:Language,
                         backend:Backend,
                         candidates:[Language],
                         evidence:Evidence,
                         hash:Record.hash,
                         generation:Record.generation
                     }
    ;   Resolution = file_language{
                         file:File,
                         status:unsupported,
                         language:Language,
                         reason:no_parser_backend,
                         candidates:[Language],
                         evidence:Evidence,
                         hash:Record.hash,
                         generation:Record.generation
                     }
    ).
evidence_candidates_resolution(_, File, Record, Evidence, Languages, Resolution) :-
    Languages = [_,_|_],
    Resolution = file_language{
                     file:File,
                     status:ambiguous,
                     language:ambiguous,
                     candidates:Languages,
                     evidence:Evidence,
                     hash:Record.hash,
                     generation:Record.generation
                 }.

/* Tree-sitter grammar registry --------------------------------------- */

ts_grammar_register(Registry, Language0, Spec0, Outcome) :-
    catch(ts_grammar_register_(Registry, Language0, Spec0, Outcome),
          Exception,
          project_source_exception(grammar_register, Exception, Outcome)).

ts_grammar_register_(Registry, Language0, Spec0, Outcome) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    require_tree_sitter_language(Id, Language),
    normalize_grammar(Language, Spec0, Grammar),
    with_mutex(rlm_project_source_registry,
               register_grammar(Id, Language, Grammar, Outcome)).

register_grammar(Id, Language, Grammar, Outcome) :-
    (   project_source_grammar_record(Id, Language, Existing)
    ->  (   Existing == Grammar
        ->  Outcome = ok(existing(Grammar.ref))
        ;   throw(project_source_fault(grammar_already_registered(Language,
                                                                  Existing.ref)))
        )
    ;   assertz(project_source_grammar_record(Id, Language, Grammar)),
        Outcome = ok(Grammar.ref)
    ).

ts_grammar_unregister(Registry, Language0, Outcome) :-
    catch(ts_grammar_unregister_(Registry, Language0, Outcome),
          Exception,
          project_source_exception(grammar_unregister, Exception, Outcome)).

ts_grammar_unregister_(Registry, Language0, Outcome) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    with_mutex(rlm_project_source_registry,
               retract_grammar(Id, Language, Grammar, Handle, Activation)),
    close_optional_handle(Handle),
    (   Grammar == none
    ->  Outcome = ok(not_registered(Language))
    ;   Outcome = ok(unregistered(Grammar.ref, Activation))
    ).

retract_grammar(Id, Language, Grammar, Handle, Activation) :-
    (   retract(project_source_grammar_record(Id, Language, Stored))
    ->  Grammar = Stored
    ;   Grammar = none
    ),
    (   retract(project_source_grammar_active(Id,
                                             Language,
                                             ActiveHandle,
                                             ActiveState))
    ->  Handle = ActiveHandle,
        Activation = ActiveState
    ;   Handle = none,
        Activation = inactive
    ).

ts_grammar(Registry, Language0, Grammar) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    project_source_grammar_record(Id, Language, Stored),
    public_grammar(Id, Language, Stored, Grammar).

ts_grammars(Registry, Grammars) :-
    registry_id(Registry, Id),
    findall(Language-Grammar,
            ( project_source_grammar_record(Id, Language, Stored),
              public_grammar(Id, Language, Stored, Grammar)
            ),
            Pairs),
    keysort(Pairs, Sorted),
    pairs_values(Sorted, Grammars).

public_grammar(Id, Language, Stored, Grammar) :-
    (   project_source_grammar_active(Id, Language, _, Activation)
    ->  put_dict(_{state:active, activation:Activation}, Stored, Grammar)
    ;   put_dict(_{state:configured, activation:inactive}, Stored, Grammar)
    ).

ts_grammar_activate(Registry, Language0, Outcome) :-
    catch(ts_grammar_activate_(Registry, Language0, Outcome),
          Exception,
          project_source_exception(grammar_activate, Exception, Outcome)).

ts_grammar_activate_(Registry, Language0, Outcome) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    require_grammar(Id, Language, Grammar),
    (   project_source_grammar_active(Id, Language, _, ExistingActivation)
    ->  Outcome = ok(already_active(ExistingActivation))
    ;   require_tree_sitter_api,
        load_grammar_handle(Grammar, Handle, Activation),
        publish_grammar_activation(Id,
                                   Language,
                                   Grammar,
                                   Handle,
                                   Activation,
                                   Outcome)
    ).

load_grammar_handle(Grammar, Handle, Activation) :-
    catch(rlm_tree_sitter:ts_language_load(Grammar.library,
                                          Grammar.symbol,
                                          Handle0),
          Exception,
          rethrow_grammar_load_exception(Grammar.ref, Exception)),
    catch(validate_loaded_grammar(Grammar, Handle0, Activation0),
          Exception,
          ( close_language_handle_safely(Handle0),
            throw(Exception)
          )),
    Handle = Handle0,
    Activation = Activation0.

rethrow_grammar_load_exception(Ref,
                               error(tree_sitter_error(incompatible_language_abi,
                                                       Detail),
                                     _)) :-
    throw(project_source_fault(incompatible_grammar(Ref, Detail))).
rethrow_grammar_load_exception(Ref, Exception) :-
    throw(project_source_fault(grammar_load_failed(Ref, Exception))).

validate_loaded_grammar(Grammar, Handle, Activation) :-
    rlm_tree_sitter:ts_language_abi(Handle, Abi),
    rlm_tree_sitter:ts_language_compatible(Handle, Compatibility),
    require_compatibility(Grammar.ref, Compatibility),
    require_declared_abi(Grammar, Abi),
    rlm_tree_sitter:ts_runtime_abi(Minimum, Maximum),
    Activation = grammar_activation{
                     grammar_ref:Grammar.ref,
                     language:Grammar.language,
                     abi:Abi,
                     runtime_minimum_abi:Minimum,
                     runtime_maximum_abi:Maximum,
                     version:Grammar.version,
                     provenance:Grammar.provenance
                 }.

publish_grammar_activation(Id,
                           Language,
                           Grammar,
                           Handle,
                           Activation,
                           Outcome) :-
    with_mutex(rlm_project_source_registry,
               publish_grammar_activation_locked(Id,
                                                Language,
                                                Grammar,
                                                Handle,
                                                Activation,
                                                Action)),
    activation_action(Action, Handle, Activation, Outcome).

publish_grammar_activation_locked(Id,
                                  Language,
                                  Grammar,
                                  _,
                                  _,
                                  stale) :-
    \+ project_source_grammar_record(Id, Language, Grammar),
    !.
publish_grammar_activation_locked(Id,
                                  Language,
                                  _,
                                  _,
                                  _,
                                  existing(Existing)) :-
    project_source_grammar_active(Id, Language, _, Existing),
    !.
publish_grammar_activation_locked(Id,
                                  Language,
                                  _,
                                  Handle,
                                  Activation,
                                  stored) :-
    assertz(project_source_grammar_active(Id, Language, Handle, Activation)).

activation_action(stored, _, Activation, ok(activated(Activation))).
activation_action(existing(Existing), Handle, _, ok(already_active(Existing))) :-
    close_language_handle_safely(Handle).
activation_action(stale, Handle, Activation, _) :-
    close_language_handle_safely(Handle),
    throw(project_source_fault(stale_grammar_registration(Activation.grammar_ref))).

ts_grammar_deactivate(Registry, Language0, Outcome) :-
    catch(ts_grammar_deactivate_(Registry, Language0, Outcome),
          Exception,
          project_source_exception(grammar_deactivate, Exception, Outcome)).

ts_grammar_deactivate_(Registry, Language0, Outcome) :-
    registry_id(Registry, Id),
    normalize_language(Language0, Language),
    with_mutex(rlm_project_source_registry,
               (   retract(project_source_grammar_active(Id,
                                                         Language,
                                                         Handle,
                                                         Activation))
               ->  true
               ;   Handle = none,
                   Activation = inactive
               )),
    close_optional_handle(Handle),
    (   Activation == inactive
    ->  Outcome = ok(already_inactive(Language))
    ;   Outcome = ok(deactivated(Activation))
    ).

require_grammar(Id, Language, Grammar) :-
    project_source_grammar_record(Id, Language, Grammar),
    !.
require_grammar(_, Language, _) :-
    throw(project_source_fault(grammar_not_registered(Language))).

require_tree_sitter_language(Id, Language) :-
    (   language_backend(Id, Language, tree_sitter, _)
    ->  true
    ;   language_backend(Id, Language, Backend, _)
    ->  throw(project_source_fault(language_backend_mismatch(Language,
                                                             Backend,
                                                             tree_sitter)))
    ;   throw(project_source_fault(unsupported_language(Language)))
    ).

require_tree_sitter_api :-
    current_predicate(rlm_tree_sitter:ts_language_load/3),
    current_predicate(rlm_tree_sitter:ts_language_compatible/2),
    !.
require_tree_sitter_api :-
    throw(project_source_fault(tree_sitter_runtime_not_loaded)).

require_compatibility(_, ok(compatible(_, _, _))) :- !.
require_compatibility(Ref, error(Reason)) :-
    throw(project_source_fault(incompatible_grammar(Ref, Reason))).
require_compatibility(Ref, Other) :-
    throw(project_source_fault(invalid_compatibility_result(Ref, Other))).

require_declared_abi(Grammar, Abi) :-
    (   Grammar.abi == unknown
    ->  true
    ;   Grammar.abi =:= Abi
    ->  true
    ;   throw(project_source_fault(declared_abi_mismatch(Grammar.ref,
                                                         Grammar.abi,
                                                         Abi)))
    ).

normalize_grammar(Language, Spec0, Grammar) :-
    require_dict(grammar, Spec0),
    allowed_keys(grammar,
                 Spec0,
                 [identity, library, symbol, abi, version, provenance]),
    require_dict_key(grammar, Spec0, library, Library0),
    normalize_text(library, Library0, Library),
    require_dict_key(grammar, Spec0, symbol, Symbol0),
    normalize_atom(symbol, Symbol0, Symbol),
    dict_default(Spec0, abi, unknown, Abi0),
    normalize_abi(Abi0, Abi),
    require_dict_key(grammar, Spec0, version, Version0),
    canonical_data(Version0, Version),
    dict_default(Spec0, provenance, _{}, Provenance0),
    normalize_meta(grammar_provenance, Provenance0, Provenance),
    grammar_base_hash(Language,
                      Library,
                      Symbol,
                      Abi,
                      Version,
                      Provenance,
                      BaseHash),
    dict_default(Spec0, identity, content_hash(BaseHash), Identity0),
    normalize_identity(grammar, Identity0, Identity),
    grammar_ref(Language,
                Identity,
                Library,
                Symbol,
                Abi,
                Version,
                Provenance,
                Ref),
    Grammar = tree_sitter_grammar{
                  ref:Ref,
                  language:Language,
                  identity:Identity,
                  library:Library,
                  symbol:Symbol,
                  abi:Abi,
                  version:Version,
                  provenance:Provenance
              }.

grammar_base_hash(Language, Library, Symbol, Abi, Version, Provenance, Hash) :-
    content_hash(grammar(Language, Library, Symbol, Abi, Version, Provenance), Hash).

grammar_ref(Language, Identity, Library, Symbol, Abi, Version, Provenance, Ref) :-
    content_hash(grammar_ref(Language,
                             Identity,
                             Library,
                             Symbol,
                             Abi,
                             Version,
                             Provenance),
                 Hash),
    Ref = grammar_ref(Language, Hash).

content_hash(Term, Hash) :-
    with_output_to(string(Text), write_canonical(Term)),
    crypto_data_hash(Text, Hash, [algorithm(sha256), encoding(utf8)]).

/* Parser/grammar selection ------------------------------------------- */

parser_for_file(Registry, File, Outcome) :-
    catch(parser_for_file_(Registry, File, Outcome),
          Exception,
          project_source_exception(parser_for_file, Exception, Outcome)).

parser_for_file_(Registry, File, Outcome) :-
    registry_id(Registry, Id),
    project_source_file_language_(Registry, File, ok(LanguageResolution)),
    selection_provenance(LanguageResolution, Provenance),
    parser_selection(Id, LanguageResolution, Provenance, Selection),
    Outcome = ok(Selection).

parser_selection(_, Resolution, Provenance, Selection) :-
    Resolution.status == unknown,
    !,
    Selection = parser_selection{file:Resolution.file,
                                 status:unknown,
                                 language:unknown,
                                 backend:unknown,
                                 provenance:Provenance}.
parser_selection(_, Resolution, Provenance, Selection) :-
    Resolution.status == ambiguous,
    !,
    Selection = parser_selection{file:Resolution.file,
                                 status:ambiguous,
                                 language:ambiguous,
                                 backend:unknown,
                                 candidates:Resolution.candidates,
                                 provenance:Provenance}.
parser_selection(_, Resolution, Provenance, Selection) :-
    Resolution.status == unsupported,
    !,
    Selection = parser_selection{file:Resolution.file,
                                 status:unsupported,
                                 language:Resolution.language,
                                 backend:unknown,
                                 reason:Resolution.reason,
                                 provenance:Provenance}.
parser_selection(Id, Resolution, Provenance, Selection) :-
    resolution_language_backend(Resolution, Language, Backend, Support),
    parser_backend_selection(Id,
                             Resolution,
                             Provenance,
                             Language,
                             Backend,
                             Support,
                             Selection).

resolution_language_backend(Resolution, Language, Backend, known) :-
    Resolution.status == known,
    !,
    Language = Resolution.language,
    Backend = Resolution.backend.
resolution_language_backend(Resolution, Language, Backend, known) :-
    Resolution.status == explicit_override,
    Resolution.support = known(Backend),
    !,
    Language = Resolution.language.
resolution_language_backend(Resolution, Language, unknown, unsupported) :-
    Resolution.status == explicit_override,
    Resolution.support = unsupported(_),
    !,
    Language = Resolution.language.

parser_backend_selection(_, Resolution, Provenance, Language, _, unsupported, Selection) :-
    Selection = parser_selection{file:Resolution.file,
                                 status:unsupported,
                                 language:Language,
                                 backend:unknown,
                                 reason:no_parser_backend,
                                 provenance:Provenance}.
parser_backend_selection(Id,
                         Resolution,
                         Provenance,
                         Language,
                         tree_sitter,
                         known,
                         Selection) :-
    !,
    (   project_source_grammar_record(Id, Language, Grammar)
    ->  (   project_source_grammar_active(Id, Language, _, Activation)
        ->  Status = ready,
            GrammarState = active,
            ActivationState = Activation
        ;   Status = configured,
            GrammarState = configured,
            ActivationState = inactive
        ),
        Selection = parser_selection{
                        file:Resolution.file,
                        status:Status,
                        language:Language,
                        backend:tree_sitter,
                        grammar_ref:Grammar.ref,
                        grammar_state:GrammarState,
                        activation:ActivationState,
                        provenance:Provenance
                    }
    ;   Selection = parser_selection{
                        file:Resolution.file,
                        status:unsupported,
                        language:Language,
                        backend:tree_sitter,
                        reason:missing_grammar,
                        provenance:Provenance
                    }
    ).
parser_backend_selection(_, Resolution, Provenance, Language, Backend, known, Selection) :-
    Selection = parser_selection{file:Resolution.file,
                                 status:ready,
                                 language:Language,
                                 backend:Backend,
                                 provenance:Provenance}.

grammar_for_file(Registry, File, Outcome) :-
    catch(grammar_for_file_(Registry, File, Outcome),
          Exception,
          project_source_exception(grammar_for_file, Exception, Outcome)).

grammar_for_file_(Registry, File, Outcome) :-
    registry_id(Registry, Id),
    parser_for_file_(Registry, File, ok(ParserSelection)),
    grammar_selection(Id, ParserSelection, Selection),
    Outcome = ok(Selection).

/* Trusted native parse operation ------------------------------------- */

project_source_tree_parse(Registry, File, Source0, Tree, Outcome) :-
    catch(project_source_tree_parse_(Registry, File, Source0, Tree, Outcome),
          Exception,
          project_source_exception(tree_parse, Exception, Outcome)).

project_source_tree_parse_(Registry, File, Source0, Tree, Outcome) :-
    registry_id(Registry, Id),
    normalize_source_text(Source0, Source),
    file_record(Id, File, FileRecord),
    parser_for_file_(Registry, File, ok(Selection)),
    require_active_tree_sitter_parser(Id, Selection, LanguageHandle),
    require_tree_sitter_loaded,
    setup_call_cleanup(
        rlm_tree_sitter:ts_parser_create(Parser),
        ( rlm_tree_sitter:ts_parser_set_language(Parser,
                                                 LanguageHandle,
                                                 ok(configured)),
          rlm_tree_sitter:ts_parse_string(Parser, Source, Tree)
        ),
        rlm_tree_sitter:ts_parser_close(Parser, _)
    ),
    Outcome = ok(project_source_parse{
                     project:FileRecord.project,
                     file:File,
                     file_hash:FileRecord.hash,
                     file_generation:FileRecord.generation,
                     language:Selection.language,
                     backend:tree_sitter,
                     grammar_ref:Selection.grammar_ref,
                     grammar_state:Selection.grammar_state,
                     activation:Selection.activation,
                     selection_provenance:Selection.provenance
                 }).

require_active_tree_sitter_parser(Id, Selection, LanguageHandle) :-
    Selection.status == ready,
    Selection.backend == tree_sitter,
    project_source_grammar_active(Id,
                                  Selection.language,
                                  LanguageHandle,
                                  Activation),
    Activation.grammar_ref == Selection.grammar_ref,
    !.
require_active_tree_sitter_parser(_, Selection, _) :-
    throw(project_source_fault(parser_not_ready(Selection.status,
                                                 Selection.backend))).

require_tree_sitter_loaded :-
    current_predicate(rlm_tree_sitter:ts_parser_create/1),
    !.
require_tree_sitter_loaded :-
    throw(project_source_fault(tree_sitter_not_loaded)).

grammar_selection(Id, Parser, Selection) :-
    Parser.backend == tree_sitter,
    memberchk(Parser.status, [configured, ready]),
    !,
    project_source_grammar_record(Id, Parser.language, Stored),
    public_grammar(Id, Parser.language, Stored, Grammar),
    Selection = grammar_selection{file:Parser.file,
                                  status:Parser.status,
                                  language:Parser.language,
                                  grammar:Grammar,
                                  provenance:Parser.provenance}.
grammar_selection(_, Parser, Selection) :-
    Parser.backend == tree_sitter,
    Parser.status == unsupported,
    !,
    Selection = grammar_selection{file:Parser.file,
                                  status:unsupported,
                                  language:Parser.language,
                                  reason:Parser.reason,
                                  provenance:Parser.provenance}.
grammar_selection(_, Parser, Selection) :-
    Parser.status == ready,
    Parser.backend \== tree_sitter,
    !,
    Selection = grammar_selection{file:Parser.file,
                                  status:not_applicable,
                                  language:Parser.language,
                                  backend:Parser.backend,
                                  provenance:Parser.provenance}.
grammar_selection(_, Parser, Selection) :-
    Selection = grammar_selection{file:Parser.file,
                                  status:Parser.status,
                                  language:Parser.language,
                                  provenance:Parser.provenance}.

selection_provenance(Resolution, Provenance) :-
    Provenance = source_selection_provenance{
                     file:Resolution.file,
                     hash:Resolution.hash,
                     generation:Resolution.generation,
                     resolution_status:Resolution.status,
                     language_evidence:Resolution.evidence
                 }.

/* Safe closed data ---------------------------------------------------- */

canonical_data(Value0, _) :-
    var(Value0),
    !,
    throw(project_source_fault(non_ground_data)).
canonical_data(Value0, Value) :-
    is_dict(Value0),
    !,
    dict_pairs(Value0, _, Pairs0),
    maplist(canonical_data_pair, Pairs0, Pairs),
    dict_pairs(Value, source_data, Pairs).
canonical_data(Values0, Values) :-
    is_list(Values0),
    !,
    maplist(canonical_data, Values0, Values).
canonical_data(Value0, Value) :-
    compound(Value0),
    !,
    (   acyclic_term(Value0)
    ->  Value0 =.. [Functor|Args0],
        maplist(canonical_data, Args0, Args),
        Value =.. [Functor|Args]
    ;   throw(project_source_fault(cyclic_data))
    ).
canonical_data(Value, Value) :-
    atomic(Value),
    !.
canonical_data(Value, _) :-
    throw(project_source_fault(unsupported_data(Value))).

canonical_data_pair(Key-Value0, Key-Value) :-
    atom(Key),
    !,
    canonical_data(Value0, Value).
canonical_data_pair(Key-_, _) :-
    throw(project_source_fault(invalid_dict_key(Key))).

/* Helpers ------------------------------------------------------------- */

file_record(Id, File, Record) :-
    project_source_file_record(Id, _, File, Record),
    !.
file_record(_, File, _) :-
    throw(project_source_fault(unknown_file(File))).

path_extension(Path, Extension) :-
    atom_string(PathAtom, Path),
    file_name_extension(_, RawExtension, PathAtom),
    RawExtension \== '',
    downcase_atom(RawExtension, Lower),
    atom_concat('.', Lower, Extension).

shebang_language(Shebang, python) :- text_contains(Shebang, 'python'), !.
shebang_language(Shebang, javascript) :- text_contains(Shebang, 'node'), !.
shebang_language(Shebang, javascript) :- text_contains(Shebang, 'deno'), !.
shebang_language(Shebang, javascript) :- text_contains(Shebang, 'bun'), !.
shebang_language(Shebang, shell) :- text_contains(Shebang, 'bash'), !.
shebang_language(Shebang, shell) :- text_contains(Shebang, 'zsh'), !.
shebang_language(Shebang, shell) :- text_contains(Shebang, '/sh'), !.

text_contains(Text, Needle) :-
    atom_string(TextAtom, Text),
    downcase_atom(TextAtom, Lower),
    sub_atom(Lower, _, _, _, Needle).

normalize_identity(Name, Value0, Value) :-
    catch(canonical_data(Value0, Value),
          project_source_fault(Fault),
          throw(project_source_fault(invalid_identity(Name, Fault)))),
    Value \== '',
    Value \== "",
    !.
normalize_identity(Name, Value, _) :-
    throw(project_source_fault(invalid_identity(Name, Value))).

normalize_language(Value0, Language) :-
    normalize_atom(language, Value0, Language),
    Language \== '',
    !.
normalize_language(Value, _) :-
    throw(project_source_fault(invalid_language(Value))).

normalize_backend(tree_sitter, tree_sitter) :- !.
normalize_backend(swi_native, swi_native) :- !.
normalize_backend(external(Name0), external(Name)) :-
    !,
    normalize_atom(external_backend, Name0, Name).
normalize_backend(Value, _) :-
    throw(project_source_fault(invalid_parser_backend(Value))).

normalize_meta(Name, Meta0, Meta) :-
    require_dict(Name, Meta0),
    canonical_data(Meta0, Meta).

normalize_language_meta(Meta0, Meta) :-
    normalize_meta(language, Meta0, Meta1),
    (   get_dict(extensions, Meta1, Extensions0)
    ->  (   is_list(Extensions0)
        ->  maplist(normalize_language_extension,
                    Extensions0,
                    Extensions1),
            sort(Extensions1, Extensions),
            Meta = Meta1.put(extensions, Extensions)
        ;   throw(project_source_fault(invalid_language_extensions(Extensions0)))
        )
    ;   Meta = Meta1
    ).

normalize_language_extension(Value0, Extension) :-
    normalize_atom(language_extension, Value0, Extension0),
    downcase_atom(Extension0, Extension),
    atom_concat('.', Suffix, Extension),
    Suffix \== '',
    \+ sub_atom(Suffix, _, _, _, '/'),
    \+ sub_atom(Suffix, _, _, _, '\\'),
    !.
normalize_language_extension(Value, _) :-
    throw(project_source_fault(invalid_language_extension(Value))).

normalize_hash(unknown, unknown) :- !.
normalize_hash(Value0, Value) :- normalize_text(hash, Value0, Value).

normalize_optional_text(_, none, none) :- !.
normalize_optional_text(Name, Value0, Value) :- normalize_text(Name, Value0, Value).

normalize_text(Name, Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   throw(project_source_fault(invalid_text(Name, Value)))
    ),
    Text \== "",
    !.
normalize_text(Name, Value, _) :-
    throw(project_source_fault(invalid_text(Name, Value))).

normalize_source_text(Value, Text) :-
    (   string(Value)
    ->  Text = Value
    ;   atom(Value)
    ->  atom_string(Value, Text)
    ;   throw(project_source_fault(invalid_text(source, Value)))
    ).

normalize_atom(_, Value, Value) :- atom(Value), !.
normalize_atom(_, Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_atom(Name, Value, _) :-
    throw(project_source_fault(invalid_atom(Name, Value))).

normalize_abi(unknown, unknown) :- !.
normalize_abi(Abi, Abi) :- integer(Abi), Abi >= 0, !.
normalize_abi(Value, _) :-
    throw(project_source_fault(invalid_grammar_abi(Value))).

require_boolean(_, true) :- !.
require_boolean(_, false) :- !.
require_boolean(Name, Value) :-
    throw(project_source_fault(invalid_boolean(Name, Value))).

require_nonnegative_integer(_, Value) :-
    integer(Value),
    Value >= 0,
    !.
require_nonnegative_integer(Name, Value) :-
    throw(project_source_fault(invalid_nonnegative_integer(Name, Value))).

require_dict(_, Value) :- is_dict(Value), !.
require_dict(Name, Value) :-
    throw(project_source_fault(invalid_dict(Name, Value))).

require_dict_key(_, Dict, Key, Value) :- get_dict(Key, Dict, Value), !.
require_dict_key(Name, _, Key, _) :-
    throw(project_source_fault(missing_key(Name, Key))).

allowed_keys(Name, Dict, Allowed) :-
    dict_keys(Dict, Keys),
    subtract(Keys, Allowed, Unknown),
    (   Unknown == []
    ->  true
    ;   throw(project_source_fault(unknown_keys(Name, Unknown)))
    ).

dict_default(Dict, Key, Default, Value) :-
    (   get_dict(Key, Dict, Existing)
    ->  Value = Existing
    ;   Value = Default
    ).

close_optional_handle(none) :- !.
close_optional_handle(Handle) :- close_language_handle_safely(Handle).

close_language_handle_safely(Handle) :-
    (   current_predicate(rlm_tree_sitter:ts_language_close/2)
    ->  catch(rlm_tree_sitter:ts_language_close(Handle, _), _, true)
    ;   true
    ).

clear_project_syntax_safely(Registry) :-
    (   current_predicate(rlm_project_syntax:project_syntax_registry_clear/1)
    ->  catch(rlm_project_syntax:project_syntax_registry_clear(Registry), _, true)
    ;   true
    ).

project_source_exception(Operation,
                         project_source_fault(Fault),
                         error(Error)) :-
    !,
    fault_kind(Fault, Kind),
    Error = project_source_error{
                kind:Kind,
                operation:Operation,
                detail:Fault,
                message:"project/source registry operation failed"
            }.
project_source_exception(Operation, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = project_source_error{
                kind:project_source_exception,
                operation:Operation,
                exception:Safe,
                message:"project/source registry operation raised an exception"
            }.

fault_kind(Fault, Kind) :-
    compound(Fault),
    !,
    functor(Fault, Kind, _).
fault_kind(Fault, Fault).

safe_exception(error(Formal, _), Formal) :- !.
safe_exception(Exception, Exception).
