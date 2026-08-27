:- module(rlm_tool_projection,
          [ result_visibility_preset/2,
            result_projection_normalize/2,
            tool_message_projection/3,
            tool_result_projection/3
          ]).

/** <module> Canonical provider projection policy for tool observations

Tool execution, durable retention, and provider-visible projection are separate
concerns.  This module defines the public result-visibility presets and compiles
them to inert canonical projection data.  It does not itself alter conversation
packing or tool execution.

The public presets are `full`, `once`, `reference`, and `hidden`.
*/

:- use_module(rlm_chain_schema, [message_normalize/2]).

result_visibility_preset(Preset0, Outcome) :-
    catch(( normalize_preset(Preset0, Preset),
            preset_projection(Preset, Projection),
            Outcome = ok(Projection)
          ),
          Exception,
          projection_exception(preset, Exception, Outcome)).

result_projection_normalize(Input, Outcome) :-
    catch(( projection_normalize(Input, Projection),
            Outcome = ok(Projection)
          ),
          Exception,
          projection_exception(normalize, Exception, Outcome)).

tool_message_projection(Message0, Visibility, Outcome) :-
    catch(( canonical_tool_message(Message0, Message),
            projection_normalize(Visibility, Projection),
            put_dict(result_projection, Message, Projection, Projected),
            Outcome = ok(Projected)
          ),
          Exception,
          projection_exception(tool_message, Exception, Outcome)).

tool_result_projection(Result0, Visibility, Outcome) :-
    catch(( canonical_tool_result(Result0, Result),
            projection_normalize(Visibility, Projection),
            put_dict(result_projection, Result, Projection, Projected),
            Outcome = ok(Projected)
          ),
          Exception,
          projection_exception(tool_result, Exception, Outcome)).

/* -------------------------------------------------------------------------
 * Public presets -> canonical internal policy
 * ---------------------------------------------------------------------- */

preset_projection(full,
                  result_projection{
                      initial:full,
                      after_consumption:full,
                      retention:durable,
                      retrievable:true
                  }).
preset_projection(once,
                  result_projection{
                      initial:full,
                      after_consumption:none,
                      retention:durable,
                      retrievable:true
                  }).
preset_projection(reference,
                  result_projection{
                      initial:reference,
                      after_consumption:reference,
                      retention:durable,
                      retrievable:true
                  }).
preset_projection(hidden,
                  result_projection{
                      initial:none,
                      after_consumption:none,
                      retention:durable,
                      retrievable:true
                  }).

projection_normalize(Input, Projection) :-
    preset_input(Input),
    !,
    normalize_preset(Input, Preset),
    preset_projection(Preset, Projection).
projection_normalize(Input, Projection) :-
    is_dict(Input),
    !,
    canonical_projection_dict(Input, Projection).
projection_normalize(Input, _) :-
    throw(tool_projection_fault(invalid_projection(Input))).

preset_input(Value) :- atom(Value), !.
preset_input(Value) :- string(Value).

normalize_preset(Value, Preset) :-
    normalize_atom(Value, Preset),
    (   memberchk(Preset, [full, once, reference, hidden])
    ->  true
    ;   throw(tool_projection_fault(invalid_visibility_preset(Preset)))
    ).

canonical_projection_dict(Input, Projection) :-
    require_projection_keys(Input),
    get_dict(initial, Input, Initial0),
    get_dict(after_consumption, Input, After0),
    get_dict(retention, Input, Retention0),
    get_dict(retrievable, Input, Retrievable),
    normalize_projection_state(Initial0, Initial),
    normalize_projection_state(After0, After),
    normalize_atom(Retention0, Retention),
    require_retention(Retention),
    require_retrievable(Retrievable),
    Projection = result_projection{
                     initial:Initial,
                     after_consumption:After,
                     retention:Retention,
                     retrievable:Retrievable
                 }.

require_projection_keys(Input) :-
    dict_pairs(Input, _, Pairs),
    pairs_keys(Pairs, Keys0),
    sort(Keys0, Keys),
    Expected = [after_consumption, initial, retention, retrievable],
    (   Keys == Expected
    ->  true
    ;   throw(tool_projection_fault(invalid_projection_keys(Keys)))
    ).

pairs_keys([], []).
pairs_keys([Key-_|Pairs], [Key|Keys]) :-
    pairs_keys(Pairs, Keys).

normalize_projection_state(Value, State) :-
    normalize_atom(Value, State),
    (   memberchk(State, [full, reference, none])
    ->  true
    ;   throw(tool_projection_fault(invalid_projection_state(State)))
    ).

require_retention(durable) :- !.
require_retention(Retention) :-
    throw(tool_projection_fault(invalid_retention(Retention))).

require_retrievable(true) :- !.
require_retrievable(Value) :-
    throw(tool_projection_fault(invalid_retrievable(Value))).

/* -------------------------------------------------------------------------
 * Canonical message/result metadata
 * ---------------------------------------------------------------------- */

canonical_tool_message(Message0, Message) :-
    message_normalize(Message0, MessageOutcome),
    require_message_outcome(MessageOutcome, Message),
    (   Message.role == tool
    ->  true
    ;   throw(tool_projection_fault(expected_tool_message(Message.role)))
    ).

require_message_outcome(ok(Message), Message) :- !.
require_message_outcome(error(Error), _) :-
    throw(tool_projection_fault(invalid_tool_message(Error))).
require_message_outcome(Outcome, _) :-
    throw(tool_projection_fault(invalid_message_outcome(Outcome))).

canonical_tool_result(Result0, Result) :-
    (   is_dict(Result0)
    ->  dict_pairs(Result0, _, Pairs),
        require_ground_result_pairs(Pairs, Result0),
        dict_pairs(Result, tool_result, Pairs)
    ;   throw(tool_projection_fault(invalid_tool_result(Result0)))
    ).

require_ground_result_pairs(Pairs, _) :-
    ground(Pairs),
    !.
require_ground_result_pairs(_, Result0) :-
    throw(tool_projection_fault(invalid_tool_result(Result0))).

/* -------------------------------------------------------------------------
 * Errors / helpers
 * ---------------------------------------------------------------------- */

projection_exception(Phase,
                     tool_projection_fault(Detail),
                     error(Error)) :-
    !,
    Error = tool_projection_error{
                phase:Phase,
                kind:validation_error,
                detail:Detail,
                message:"tool result projection validation failed"
            }.
projection_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = tool_projection_error{
                phase:Phase,
                kind:exception,
                exception:Safe,
                message:"tool result projection processing raised an exception"
            }.

normalize_atom(Value, Atom) :- atom(Value), !, Atom = Value.
normalize_atom(Value, Atom) :- string(Value), !, atom_string(Atom, Value).
normalize_atom(Value, _) :-
    throw(tool_projection_fault(expected_atom(Value))).

safe_exception(Exception, Safe) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]).
