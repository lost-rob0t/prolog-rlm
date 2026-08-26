:- encoding(utf8).

:- module(rlm_context_mount,
          [ rlm_context_mount_ready/0,
            context_mount/5,
            context_mount_resolve/5,
            context_mount_metadata/4,
            context_mount_prompt/5,
            context_mount_unmount/4,
            context_mount_runtime_reset/0
          ]).

/** <module> Durable named context mounts

A mount separates context *lifetime* from model *visibility*.

Persistent mounts store only closed source descriptors and policy in the
existing immutable rlm_artifact store. Live context handles are process-local
and are rehydrated after restart. Trusted adapter callbacks are never persisted.

Visibility defaults to `opaque`: persistence never implies prompt injection.
`context_mount_prompt/5` is the explicit bounded opt-in projection for mounts
created with `visibility(prompt)`.
*/

:- use_module(library(crypto)).
:- use_module(library(option)).
:- use_module(rlm_artifact).
:- use_module(rlm_closed_data, []).
:- use_module(rlm_context).

:- dynamic session_mount_record/4.
:- dynamic persistent_mount_cache/3.

rlm_context_mount_ready.

mount_namespace([rlm,context_mount]).

/* Public API ---------------------------------------------------------- */

context_mount(Store, Name0, Source0, Options, Outcome) :-
    mount_outcome(mount,
                  context_mount_(Store, Name0, Source0, Options),
                  Outcome).

context_mount_resolve(Store, Name0, Scope0, Options, Outcome) :-
    mount_outcome(resolve,
                  context_mount_resolve_(Store,
                                         Name0,
                                         Scope0,
                                         Options),
                  Outcome).

context_mount_metadata(Store, Name0, Scope0, Outcome) :-
    mount_outcome(metadata,
                  context_mount_metadata_(Store, Name0, Scope0),
                  Outcome).

context_mount_prompt(Store, Name0, Scope0, Options, Outcome) :-
    mount_outcome(prompt,
                  context_mount_prompt_(Store,
                                        Name0,
                                        Scope0,
                                        Options),
                  Outcome).

context_mount_unmount(Store, Name0, Scope0, Outcome) :-
    mount_outcome(unmount,
                  context_mount_unmount_(Store, Name0, Scope0),
                  Outcome).

context_mount_runtime_reset :-
    with_mutex(rlm_context_mount,
               ( findall(Ref,
                         cached_context_ref(Ref),
                         Refs0),
                 sort(Refs0, Refs),
                 maplist(delete_cached_context, Refs),
                 retractall(session_mount_record(_, _, _, _)),
                 retractall(persistent_mount_cache(_, _, _))
               )).

/* Mount --------------------------------------------------------------- */

context_mount_(Store, Name0, Source0, Options, Binding) :-
    normalize_mount_request(Name0,
                            Source0,
                            Options,
                            Request),
    mount_by_lifetime(Request.lifetime,
                      Store,
                      Request,
                      Binding).

mount_by_lifetime(ephemeral, _, Request, Binding) :-
    !,
    register_descriptor(Request.source,
                        Request.context_options,
                        ContextRef),
    public_mount(Request,
                 none,
                 1,
                 mounted,
                 Public),
    Binding = context_mount_binding{mount:Public,
                                    context_ref:ContextRef}.
mount_by_lifetime(session, _, Request, Binding) :-
    !,
    mount_key(Request.scope, Request.name, Key),
    register_descriptor(Request.source,
                        Request.context_options,
                        ContextRef),
    with_mutex(rlm_context_mount,
               replace_session_mount(Key,
                                     Request,
                                     ContextRef)),
    public_mount(Request,
                 none,
                 1,
                 mounted,
                 Public),
    Binding = context_mount_binding{mount:Public,
                                    context_ref:ContextRef}.
mount_by_lifetime(persistent, Store, Request, Binding) :-
    !,
    require_artifact_store(Store),
    mount_key(Request.scope, Request.name, Key),
    persistent_publish_or_reuse(Store,
                                Key,
                                Request,
                                Artifact),
    ensure_persistent_context(Key,
                              Artifact,
                              Request.context_options,
                              ContextRef),
    public_from_artifact(Artifact, Public),
    Binding = context_mount_binding{mount:Public,
                                    context_ref:ContextRef}.

replace_session_mount(Key, Request, ContextRef) :-
    (   retract(session_mount_record(Key, _, OldRef, _))
    ->  delete_cached_context(OldRef)
    ;   true
    ),
    assertz(session_mount_record(Key,
                                 Request,
                                 ContextRef,
                                 mounted)).

persistent_publish_or_reuse(Store, Key, Request, Artifact) :-
    mount_namespace(Namespace),
    artifact_latest(Store, Namespace, Key, LatestOutcome),
    (   LatestOutcome = ok(Latest),
        reusable_artifact(Latest, Request)
    ->  Artifact = Latest
    ;   persistent_value(Request, mounted, Value),
        Provenance = _{producer:rlm_context_mount,
                       operation:mount},
        artifact_put(Store,
                     Namespace,
                     Key,
                     context_mount,
                     Value,
                     Provenance,
                     PutOutcome),
        require_artifact_outcome(PutOutcome, Artifact)
    ).

reusable_artifact(Artifact, Request) :-
    Value = Artifact.value,
    Value.state == mounted,
    Value.name == Request.name,
    Value.scope == Request.scope,
    Value.lifetime == persistent,
    Value.visibility == Request.visibility,
    Value.source_fingerprint == Request.source_fingerprint.

persistent_value(Request, State,
                 context_mount_record{
                     schema_version:1,
                     name:Request.name,
                     scope:Request.scope,
                     lifetime:persistent,
                     visibility:Request.visibility,
                     state:State,
                     source_kind:Request.source_kind,
                     source_fingerprint:Request.source_fingerprint,
                     source:Request.source
                 }).

/* Resolve ------------------------------------------------------------- */

context_mount_resolve_(Store, Name0, Scope0, Options, Resolution) :-
    normalize_name(Name0, Name),
    normalize_scope(Scope0, Scope),
    context_options(Options, ContextOptions),
    mount_key(Scope, Name, Key),
    (   session_mount_record(Key, Request, ContextRef0, mounted)
    ->  ensure_live_context(ContextRef0,
                            Request.source,
                            ContextOptions,
                            ContextRef),
        public_mount(Request,
                     none,
                     1,
                     mounted,
                     Public),
        Resolution = context_mount_resolution{mount:Public,
                                              context_ref:ContextRef}
    ;   require_artifact_store(Store),
        latest_persistent_mount(Store, Key, Artifact),
        require_identity(Artifact.value, Name, Scope),
        require_mounted(Artifact.value),
        ensure_persistent_context(Key,
                                  Artifact,
                                  ContextOptions,
                                  ContextRef),
        public_from_artifact(Artifact, Public),
        Resolution = context_mount_resolution{mount:Public,
                                              context_ref:ContextRef}
    ).

ensure_live_context(ContextRef0, _, _, ContextRef0) :-
    context_metadata(ContextRef0.handle, ok(_)),
    !.
ensure_live_context(_, Descriptor, ContextOptions, ContextRef) :-
    register_descriptor(Descriptor, ContextOptions, ContextRef).

ensure_persistent_context(Key, Artifact, ContextOptions, ContextRef) :-
    Version = Artifact.version,
    (   persistent_mount_cache(Key, Version, Cached),
        context_metadata(Cached.handle, ok(_))
    ->  ContextRef = Cached
    ;   register_descriptor(Artifact.value.source,
                            ContextOptions,
                            Fresh),
        with_mutex(rlm_context_mount,
                   replace_persistent_cache(Key,
                                            Version,
                                            Fresh)),
        ContextRef = Fresh
    ).

replace_persistent_cache(Key, Version, ContextRef) :-
    findall(Old,
            retract(persistent_mount_cache(Key, _, Old)),
            OldRefs),
    maplist(delete_cached_context, OldRefs),
    assertz(persistent_mount_cache(Key, Version, ContextRef)).

latest_persistent_mount(Store, Key, Artifact) :-
    mount_namespace(Namespace),
    artifact_latest(Store, Namespace, Key, Outcome),
    require_artifact_outcome(Outcome, Artifact).

/* Metadata / explicit prompt projection ------------------------------ */

context_mount_metadata_(Store, Name0, Scope0, Public) :-
    normalize_name(Name0, Name),
    normalize_scope(Scope0, Scope),
    mount_key(Scope, Name, Key),
    (   session_mount_record(Key, Request, _, State)
    ->  public_mount(Request, none, 1, State, Public)
    ;   require_artifact_store(Store),
        latest_persistent_mount(Store, Key, Artifact),
        require_identity(Artifact.value, Name, Scope),
        public_from_artifact(Artifact, Public)
    ).

context_mount_prompt_(Store, Name0, Scope0, Options, Projection) :-
    normalize_name(Name0, Name),
    normalize_scope(Scope0, Scope),
    prompt_limit(Options, MaxChars),
    mount_record(Store, Name, Scope, Record, Public),
    require_mounted(Record),
    (   Record.visibility == prompt
    ->  true
    ;   throw(context_mount_fault(visibility_denied(Record.visibility)))
    ),
    prompt_source_text(Record.source, Text0),
    bounded_text(Text0, MaxChars, Text, Truncated),
    Projection = context_mount_prompt{
                     mount:Public,
                     text:Text,
                     truncated:Truncated,
                     max_chars:MaxChars
                 }.

mount_record(Store, Name, Scope, Record, Public) :-
    mount_key(Scope, Name, Key),
    (   session_mount_record(Key, Request, _, State)
    ->  request_record(Request, State, Record),
        public_mount(Request, none, 1, State, Public)
    ;   require_artifact_store(Store),
        latest_persistent_mount(Store, Key, Artifact),
        Record = Artifact.value,
        require_identity(Record, Name, Scope),
        public_from_artifact(Artifact, Public)
    ).

request_record(Request, State,
               context_mount_record{
                   schema_version:1,
                   name:Request.name,
                   scope:Request.scope,
                   lifetime:Request.lifetime,
                   visibility:Request.visibility,
                   state:State,
                   source_kind:Request.source_kind,
                   source_fingerprint:Request.source_fingerprint,
                   source:Request.source
               }).

prompt_source_text(context_source{kind:text,value:Text}, Text) :- !.
prompt_source_text(context_source{kind:terms,value:Terms}, Text) :-
    !,
    term_string(Terms, Text, [quoted(true),numbervars(true)]).
prompt_source_text(context_source{kind:adapter,name:Name}, _) :-
    !,
    throw(context_mount_fault(adapter_prompt_projection_requires_context_operation(Name))).
prompt_source_text(Source, _) :-
    throw(context_mount_fault(unsupported_prompt_source(Source))).

bounded_text(Text0, MaxChars, Text, Truncated) :-
    string_length(Text0, Length),
    (   Length =< MaxChars
    ->  Text = Text0,
        Truncated = false
    ;   sub_string(Text0, 0, MaxChars, _, Text),
        Truncated = true
    ).

/* Unmount ------------------------------------------------------------- */

context_mount_unmount_(Store, Name0, Scope0, Public) :-
    normalize_name(Name0, Name),
    normalize_scope(Scope0, Scope),
    mount_key(Scope, Name, Key),
    (   retract(session_mount_record(Key, Request, ContextRef, mounted))
    ->  delete_cached_context(ContextRef),
        public_mount(Request, none, 1, unmounted, Public)
    ;   require_artifact_store(Store),
        latest_persistent_mount(Store, Key, Artifact),
        require_identity(Artifact.value, Name, Scope),
        require_mounted(Artifact.value),
        tombstone_value(Artifact.value, Tombstone),
        mount_namespace(Namespace),
        Provenance = _{producer:rlm_context_mount,
                       operation:unmount,
                       previous_ref:Artifact.ref},
        artifact_put(Store,
                     Namespace,
                     Key,
                     context_mount,
                     Tombstone,
                     Provenance,
                     PutOutcome),
        require_artifact_outcome(PutOutcome, TombstoneArtifact),
        clear_persistent_cache(Key),
        public_from_artifact(TombstoneArtifact, Public)
    ).

tombstone_value(Value,
                context_mount_record{
                    schema_version:1,
                    name:Value.name,
                    scope:Value.scope,
                    lifetime:persistent,
                    visibility:Value.visibility,
                    state:unmounted,
                    source_kind:Value.source_kind,
                    source_fingerprint:Value.source_fingerprint,
                    source:none
                }).

clear_persistent_cache(Key) :-
    with_mutex(rlm_context_mount,
               ( findall(Ref,
                         retract(persistent_mount_cache(Key, _, Ref)),
                         Refs),
                 maplist(delete_cached_context, Refs)
               )).

/* Request normalization ---------------------------------------------- */

normalize_mount_request(Name0, Source0, Options,
                        context_mount_request{
                            name:Name,
                            scope:Scope,
                            lifetime:Lifetime,
                            visibility:Visibility,
                            source:Source,
                            source_kind:SourceKind,
                            source_fingerprint:Fingerprint,
                            context_options:ContextOptions
                        }) :-
    require_options(Options),
    normalize_name(Name0, Name),
    option(lifetime(Lifetime0), Options, session),
    normalize_lifetime(Lifetime0, Lifetime),
    option(scope(Scope0), Options, runtime),
    normalize_scope(Scope0, Scope),
    option(visibility(Visibility0), Options, opaque),
    normalize_visibility(Visibility0, Visibility),
    context_options(Options, ContextOptions),
    normalize_source_descriptor(Source0, Source, SourceKind),
    source_fingerprint(Source, Fingerprint).

normalize_source_descriptor(text(Text0),
                            context_source{kind:text,value:Text},
                            text) :-
    !,
    normalize_text(Text0, Text).
normalize_source_descriptor(terms(Terms0),
                            context_source{kind:terms,value:Terms},
                            terms) :-
    !,
    closed_data(Terms0, Terms).
normalize_source_descriptor(adapter(Name0, SourceRef0),
                            context_source{kind:adapter,
                                           name:Name,
                                           source_ref:SourceRef},
                            adapter) :-
    !,
    normalize_name(Name0, Name),
    closed_data(SourceRef0, SourceRef).
normalize_source_descriptor(Source, _, _) :-
    throw(context_mount_fault(unsupported_source(Source))).

register_descriptor(context_source{kind:text,value:Text},
                    Options,
                    ContextRef) :-
    !,
    context_register(text(Text), Options, Outcome),
    require_context_outcome(Outcome, ContextRef).
register_descriptor(context_source{kind:terms,value:Terms},
                    Options,
                    ContextRef) :-
    !,
    context_register(terms(Terms), Options, Outcome),
    require_context_outcome(Outcome, ContextRef).
register_descriptor(context_source{kind:adapter,
                                   name:Name,
                                   source_ref:SourceRef},
                    Options,
                    ContextRef) :-
    !,
    context_register_adapter(Name, SourceRef, Options, Outcome),
    require_context_outcome(Outcome, ContextRef).

source_fingerprint(Source, Fingerprint) :-
    term_string(Source,
                Canonical,
                [quoted(true),numbervars(true),ignore_ops(true)]),
    crypto_data_hash(Canonical,
                     Fingerprint,
                     [algorithm(sha256),encoding(utf8)]).

mount_key(Scope, Name, Key) :-
    term_string(mount(Scope, Name),
                Canonical,
                [quoted(true),numbervars(true),ignore_ops(true)]),
    crypto_data_hash(Canonical,
                     Hash,
                     [algorithm(sha256),encoding(utf8)]),
    atom_concat(mount_, Hash, Key).

normalize_name(Value, Name) :-
    atom(Value),
    Value \== '',
    !,
    Name = Value.
normalize_name(Value, Name) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Name, Value).
normalize_name(Value, _) :-
    throw(context_mount_fault(invalid_name(Value))).

normalize_scope(runtime, runtime) :- !.
normalize_scope(session(Id0), session(Id)) :-
    !,
    normalize_name(Id0, Id).
normalize_scope(project(Id0), project(Id)) :-
    !,
    normalize_name(Id0, Id).
normalize_scope(Value, _) :-
    throw(context_mount_fault(invalid_scope(Value))).

normalize_lifetime(ephemeral, ephemeral) :- !.
normalize_lifetime(session, session) :- !.
normalize_lifetime(persistent, persistent) :- !.
normalize_lifetime(Value, _) :-
    throw(context_mount_fault(invalid_lifetime(Value))).

normalize_visibility(opaque, opaque) :- !.
normalize_visibility(prompt, prompt) :- !.
normalize_visibility(Value, _) :-
    throw(context_mount_fault(invalid_visibility(Value))).

context_options(Options, ContextOptions) :-
    option(context_options(ContextOptions), Options, []),
    require_options(ContextOptions).

prompt_limit(Options, MaxChars) :-
    require_options(Options),
    option(max_chars(MaxChars), Options, 2048),
    (   integer(MaxChars), MaxChars > 0
    ->  true
    ;   throw(context_mount_fault(invalid_max_chars(MaxChars)))
    ).

closed_data(Value0, Value) :-
    catch(rlm_closed_data:closed_data_normalize(Value0, Value),
          Exception,
          throw(context_mount_fault(non_closed_data(Exception)))).

normalize_text(Value, Text) :-
    string(Value),
    !,
    Text = Value.
normalize_text(Value, Text) :-
    atom(Value),
    !,
    atom_string(Value, Text).
normalize_text(Value, _) :-
    throw(context_mount_fault(invalid_text(Value))).

/* Public redacted records -------------------------------------------- */

public_mount(Request, ArtifactRef, Version, State,
             context_mount{
                 schema_version:1,
                 name:Request.name,
                 scope:Request.scope,
                 lifetime:Request.lifetime,
                 visibility:Request.visibility,
                 state:State,
                 source_kind:Request.source_kind,
                 source_fingerprint:Request.source_fingerprint,
                 artifact_ref:ArtifactRef,
                 version:Version
             }).

public_from_artifact(Artifact,
                     context_mount{
                         schema_version:1,
                         name:Value.name,
                         scope:Value.scope,
                         lifetime:Value.lifetime,
                         visibility:Value.visibility,
                         state:Value.state,
                         source_kind:Value.source_kind,
                         source_fingerprint:Value.source_fingerprint,
                         artifact_ref:Artifact.ref,
                         version:Artifact.version
                     }) :-
    Value = Artifact.value.

require_identity(Value, Name, Scope) :-
    (   Value.name == Name,
        Value.scope == Scope
    ->  true
    ;   throw(context_mount_fault(identity_mismatch(Name,
                                                    Scope,
                                                    Value.name,
                                                    Value.scope)))
    ).

require_mounted(Value) :-
    (   Value.state == mounted
    ->  true
    ;   throw(context_mount_fault(not_mounted(Value.state)))
    ).

/* Outcome and cleanup helpers ---------------------------------------- */

require_artifact_store(Store) :-
    (   nonvar(Store), Store \== none
    ->  true
    ;   throw(context_mount_fault(persistent_store_required))
    ).

require_artifact_outcome(ok(Value), Value) :- !.
require_artifact_outcome(error(Error), _) :-
    throw(context_mount_fault(artifact_error(Error))).

require_context_outcome(ok(Value), Value) :- !.
require_context_outcome(error(Error), _) :-
    throw(context_mount_fault(context_error(Error))).

require_options(Options) :- is_list(Options), !.
require_options(Value) :-
    throw(context_mount_fault(invalid_options(Value))).

cached_context_ref(Ref) :- session_mount_record(_, _, Ref, _).
cached_context_ref(Ref) :- persistent_mount_cache(_, _, Ref).

delete_cached_context(Ref) :-
    (   is_dict(Ref), get_dict(handle, Ref, Handle)
    ->  catch(context_delete(Handle, _), _, true)
    ;   true
    ).

mount_outcome(Operation, Goal, Outcome) :-
    catch(( call(Goal, Value), Outcome = ok(Value) ),
          Exception,
          mount_exception(Operation, Exception, Outcome)).

mount_exception(Operation, Exception,
                error(context_mount_error{
                          operation:Operation,
                          detail:Safe
                      })) :-
    term_string(Exception, Safe, [quoted(true),numbervars(true)]).
