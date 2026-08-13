:- module(rlm_mcp_compat,
          [ mcp_compat_cache_clear/0,
            mcp_compat_cache_lookup/5,
            mcp_compat_cache_store/7,
            mcp_compat_cache_invalidate/2
          ]).

/** <module> Replaceable MCP endpoint compatibility cache

The cache stores only protocol-selection evidence.  It deliberately excludes
session identifiers and other adapter state.  Callers supply a monotonically
increasing generation so stale-entry behavior is deterministic and testable.
*/

:- dynamic compatibility_entry/2.

mcp_compat_cache_clear :-
    retractall(compatibility_entry(_, _)).

mcp_compat_cache_lookup(Endpoint, Transport, Generation, MaxAge, Outcome) :-
    catch(cache_lookup(Endpoint, Transport, Generation, MaxAge, Outcome),
          Exception,
          cache_exception(lookup, Exception, Outcome)).

cache_lookup(Endpoint, Transport, Generation, MaxAge, Outcome) :-
    require_endpoint(Endpoint),
    require_transport(Transport),
    require_generation(Generation),
    require_max_age(MaxAge),
    (   compatibility_entry(Endpoint, Entry0)
    ->  (   valid_entry(Entry0),
            Entry0.transport == Transport,
            Age is Generation-Entry0.generation,
            Age >= 0,
            Age =< MaxAge
        ->  Outcome = ok(Entry0)
        ;   retractall(compatibility_entry(Endpoint, _)),
            Outcome = miss
        )
    ;   Outcome = miss
    ).

mcp_compat_cache_store(Endpoint,
                       Transport,
                       Versions0,
                       Selected,
                       Source,
                       Generation,
                       Outcome) :-
    catch(cache_store(Endpoint,
                      Transport,
                      Versions0,
                      Selected,
                      Source,
                      Generation,
                      Outcome),
          Exception,
          cache_exception(store, Exception, Outcome)).

cache_store(Endpoint, Transport, Versions0, Selected, Source, Generation,
            ok(Entry)) :-
    require_endpoint(Endpoint),
    require_transport(Transport),
    normalize_versions(Versions0, Versions),
    require_selected(Selected, Versions),
    require_source(Source),
    require_generation(Generation),
    Entry = mcp_compatibility{
                endpoint:Endpoint,
                transport:Transport,
                verified_versions:Versions,
                selected:Selected,
                source:Source,
                generation:Generation
            },
    retractall(compatibility_entry(Endpoint, _)),
    assertz(compatibility_entry(Endpoint, Entry)).

mcp_compat_cache_invalidate(Endpoint, Outcome) :-
    catch((require_endpoint(Endpoint),
           retractall(compatibility_entry(Endpoint, _)),
           Outcome = ok(invalidated)),
          Exception,
          cache_exception(invalidate, Exception, Outcome)).

valid_entry(Entry) :-
    is_dict(Entry, mcp_compatibility),
    get_dict(endpoint, Entry, Endpoint),
    get_dict(transport, Entry, Transport),
    get_dict(verified_versions, Entry, Versions),
    get_dict(selected, Entry, Selected),
    get_dict(source, Entry, Source),
    get_dict(generation, Entry, Generation),
    catch((require_endpoint(Endpoint),
           require_transport(Transport),
           normalize_versions(Versions, Normalized),
           Normalized == Versions,
           require_selected(Selected, Versions),
           require_source(Source),
           require_generation(Generation)),
          _,
          fail).

normalize_versions(Versions0, Versions) :-
    (   is_list(Versions0), Versions0 \== []
    ->  maplist(normalize_version, Versions0, Versions1),
        sort(Versions1, Versions)
    ;   throw(mcp_compat_fault(invalid_versions(Versions0)))
    ).

normalize_version(Value, Value) :- atom(Value), Value \== '', !.
normalize_version(Value, Version) :-
    string(Value),
    Value \== "",
    !,
    atom_string(Version, Value).
normalize_version(Value, _) :-
    throw(mcp_compat_fault(invalid_version(Value))).

require_endpoint(Endpoint) :-
    (   ground(Endpoint)
    ->  true
    ;   throw(mcp_compat_fault(non_ground_endpoint))
    ).

require_transport(Transport) :-
    (   memberchk(Transport, [stdio, streamable_http])
    ->  true
    ;   throw(mcp_compat_fault(invalid_transport(Transport)))
    ).

require_generation(Generation) :-
    (   integer(Generation), Generation >= 0
    ->  true
    ;   throw(mcp_compat_fault(invalid_generation(Generation)))
    ).

require_max_age(MaxAge) :-
    (   integer(MaxAge), MaxAge >= 0
    ->  true
    ;   throw(mcp_compat_fault(invalid_max_age(MaxAge)))
    ).

require_selected(Selected, Versions) :-
    normalize_version(Selected, Version),
    (   memberchk(Version, Versions)
    ->  true
    ;   throw(mcp_compat_fault(selected_not_verified(Version)))
    ).

require_source(Source) :-
    (   memberchk(Source, [discovery, initialize, unsupported_version,
                           explicit, command_success])
    ->  true
    ;   throw(mcp_compat_fault(invalid_source(Source)))
    ).

cache_exception(Operation, mcp_compat_fault(Detail), error(Error)) :-
    !,
    Error = mcp_error{phase:compatibility_cache,
                      kind:cache_error,
                      operation:Operation,
                      detail:Detail,
                      message:"MCP compatibility cache operation failed"}.
cache_exception(Operation, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = mcp_error{phase:compatibility_cache,
                      kind:exception,
                      operation:Operation,
                      exception:Safe,
                      message:"MCP compatibility cache raised an exception"}.
