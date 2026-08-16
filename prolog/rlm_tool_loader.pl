:- module(rlm_tool_loader,
          [ tool_pack/2,
            rlm_tool_packs/1,
            rlm_load_tools/3,
            rlm_load_all_tools/2
          ]).

/** <module> External tool-pack loading boundary

Core owns the loading ABI, not concrete filesystem/process/git/network tools.
External trusted libraries contribute pack declarations using multifile facts:

  :- multifile rlm_tool_loader:tool_pack/2.

  rlm_tool_loader:tool_pack(filesystem,
                            my_filesystem_tools:load_tool_pack).

A loader has the shape Loader(Registry, Outcome). Loading may register schemas
and handlers in the supplied rlm_tool registry, but it does not grant any
capability and it must not start unrelated services. Authorization remains an
independent invocation-time runtime decision.

Pack discovery and loading are immediate host configuration operations and are
intentionally not forced through Futures.
*/

:- multifile tool_pack/2.

rlm_tool_packs(Packs) :-
    findall(Name, tool_pack(Name, _), Names0),
    sort(Names0, Packs).

rlm_load_tools(Registry, Pack, Outcome) :-
    catch(rlm_load_tools_(Registry, Pack, Outcome),
          Exception,
          loader_exception(Pack, Exception, Outcome)).

rlm_load_tools_(Registry, Pack, Outcome) :-
    require_pack_name(Pack),
    findall(Loader, tool_pack(Pack, Loader), Loaders),
    load_declared_pack(Loaders, Registry, Pack, Outcome).

load_declared_pack([], _, Pack,
                   error(tool_loader_error{
                             kind:unknown_tool_pack,
                             pack:Pack,
                             message:"tool pack is not declared"
                         })) :- !.
load_declared_pack([Loader], Registry, Pack, Outcome) :-
    !,
    require_pack_loader(Loader),
    call_pack_loader(Loader, Registry, Pack, Outcome).
load_declared_pack(Loaders, _, Pack,
                   error(tool_loader_error{
                             kind:ambiguous_tool_pack,
                             pack:Pack,
                             declarations:Count,
                             message:"tool pack has multiple loader declarations"
                         })) :-
    length(Loaders, Count).

call_pack_loader(Loader, Registry, Pack, Outcome) :-
    (   call(Loader, Registry, RawOutcome)
    ->  normalize_loader_outcome(RawOutcome, Pack, Outcome)
    ;   Outcome = error(tool_loader_error{
                           kind:loader_failed,
                           pack:Pack,
                           message:"tool pack loader failed without an outcome"
                       })
    ).

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

rlm_load_all_tools(Registry, Outcome) :-
    rlm_tool_packs(Packs),
    load_all_packs(Packs, Registry, [], Outcome).

load_all_packs([], _, Loaded,
               ok(tool_pack_load{loaded:Loaded})) :- !.
load_all_packs([Pack|Packs], Registry, Loaded0, Outcome) :-
    rlm_load_tools(Registry, Pack, PackOutcome),
    load_all_after_one(PackOutcome,
                       Pack,
                       Packs,
                       Registry,
                       Loaded0,
                       Outcome).

load_all_after_one(error(Error), _, _, _, _, error(Error)) :- !.
load_all_after_one(ok(Value), Pack, Packs, Registry, Loaded0, Outcome) :-
    append(Loaded0, [tool_pack_loaded{pack:Pack, result:Value}], Loaded),
    load_all_packs(Packs, Registry, Loaded, Outcome).

require_pack_name(Pack) :-
    atom(Pack),
    Pack \== '',
    !.
require_pack_name(Pack) :-
    throw(tool_loader_fault(invalid_pack_name(Pack))).

require_pack_loader(Loader) :-
    callable(Loader),
    ground(Loader),
    !.
require_pack_loader(Loader) :-
    throw(tool_loader_fault(invalid_pack_loader(Loader))).

loader_exception(_, Exception, _) :-
    control_exception(Exception),
    !,
    throw(Exception).
loader_exception(Pack, tool_loader_fault(Detail), error(Error)) :-
    !,
    Error = tool_loader_error{
                kind:invalid_tool_pack_operation,
                pack:Pack,
                detail:Detail,
                message:"tool pack loading operation is invalid"
            }.
loader_exception(Pack, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = tool_loader_error{
                kind:loader_exception,
                pack:Pack,
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
