:- module(rlm_symbolic_tool,
          [ rlm_symbolic_tool_ready/0,
            symbolic_program_validate/2,
            symbolic_eval/3,
            symbolic_tool_register/5
          ]).

/** <module> Closed symbolic programs as trusted RLM read tools

This adapter lets trusted hosts describe pure decision logic as closed data and
register that logic through the canonical rlm_tool registry.  Symbolic programs
are interpreted by code-owned predicates; program data is never meta-called.

The expression language is deliberately small.  It can read tool arguments,
compare values, combine booleans, perform bounded arithmetic, and construct
result templates.  It cannot name predicates, modules, files, processes,
networks, or arbitrary callables.

A symbolic tool is always read-only.  Visibility still belongs to the prompt
compiler and execution still passes through rlm_tool capability, authority,
schema, timeout, and output-size checks.
*/

:- use_module(library(error)).
:- use_module(library(lists)).
:- use_module(rlm_tool, []).

rlm_symbolic_tool_ready :-
    symbolic_program_validate(
        symbolic_program([], json{ready:true}),
        ok(_)).

symbolic_program_validate(Program0, Outcome) :-
    catch(( normalize_program(Program0, Program),
            Outcome = ok(Program)
          ),
          Exception,
          symbolic_exception(validate, Exception, Outcome)).

symbolic_eval(Program0, Args, Outcome) :-
    catch(( normalize_program(Program0, Program),
            require_args(Args),
            evaluate_program(Program, Args, Value),
            Outcome = ok(Value)
          ),
          Exception,
          symbolic_exception(evaluate, Exception, Outcome)).

symbolic_tool_register(Registry, Schema, Program0, Options, Outcome) :-
    catch(( must_be(list, Options),
            normalize_program(Program0, Program),
            require_read_schema(Schema),
            Handler = rlm_symbolic_tool:symbolic_handler(Program),
            rlm_tool:tool_register(Registry, Schema, Handler, Outcome)
          ),
          Exception,
          symbolic_exception(register, Exception, Outcome)).

symbolic_handler(Program, Args, Value) :-
    symbolic_eval(Program, Args, Outcome),
    (   Outcome = ok(Value)
    ->  true
    ;   Outcome = error(Error),
        throw(symbolic_tool_fault(Error))
    ).

normalize_program(Program0, Program) :-
    require_closed_term(Program0, program),
    (   Program0 = symbolic_program(Rules, Default)
    ->  true
    ;   throw(symbolic_fault(invalid_program_shape(Program0)))
    ),
    must_be(list, Rules),
    maplist(validate_rule, Rules),
    validate_template(Default),
    Program = symbolic_program(Rules, Default).

validate_rule(rule(Condition, Template)) :-
    !,
    validate_condition(Condition),
    validate_template(Template).
validate_rule(Rule) :-
    throw(symbolic_fault(invalid_rule(Rule))).

validate_condition(true) :- !.
validate_condition(false) :- !.
validate_condition(and(Conditions)) :-
    !,
    must_be(list, Conditions),
    maplist(validate_condition, Conditions).
validate_condition(or(Conditions)) :-
    !,
    must_be(list, Conditions),
    maplist(validate_condition, Conditions).
validate_condition(not(Condition)) :-
    !,
    validate_condition(Condition).
validate_condition(eq(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(neq(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(lt(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(lte(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(gt(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(gte(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(in(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_condition(present(A)) :- !, validate_expression(A).
validate_condition(Condition) :-
    throw(symbolic_fault(unsupported_condition(Condition))).

validate_expression(const(Value)) :-
    !,
    validate_closed_value(Value).
validate_expression(field(Key)) :-
    !,
    validate_key(Key).
validate_expression(path(Keys)) :-
    !,
    must_be(list, Keys),
    maplist(validate_key, Keys).
validate_expression(add(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(sub(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(mul(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(div(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(min(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(max(A, B)) :- !, validate_expression(A), validate_expression(B).
validate_expression(Expression) :-
    throw(symbolic_fault(unsupported_expression(Expression))).

validate_template(expr(Expression)) :-
    !,
    validate_expression(Expression).
validate_template(Value) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    maplist(validate_template_pair, Pairs).
validate_template(Value) :-
    is_list(Value),
    !,
    maplist(validate_template, Value).
validate_template(Value) :-
    validate_closed_scalar(Value),
    !.
validate_template(Value) :-
    throw(symbolic_fault(unsupported_template(Value))).

validate_template_pair(_-Value) :-
    validate_template(Value).

validate_closed_value(Value) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    maplist(validate_closed_pair, Pairs).
validate_closed_value(Value) :-
    is_list(Value),
    !,
    maplist(validate_closed_value, Value).
validate_closed_value(Value) :-
    validate_closed_scalar(Value),
    !.
validate_closed_value(Value) :-
    throw(symbolic_fault(non_data_constant(Value))).

validate_closed_pair(_-Value) :-
    validate_closed_value(Value).

validate_closed_scalar(Value) :- atom(Value), !.
validate_closed_scalar(Value) :- string(Value), !.
validate_closed_scalar(Value) :- number(Value), !.

validate_key(Key) :-
    (atom(Key) ; string(Key)),
    !.
validate_key(Key) :-
    throw(symbolic_fault(invalid_key(Key))).

require_closed_term(Value, _Label) :-
    ground(Value),
    acyclic_term(Value),
    !.
require_closed_term(_, Label) :-
    throw(symbolic_fault(open_or_cyclic(Label))).

require_args(Args) :-
    is_dict(Args),
    ground(Args),
    acyclic_term(Args),
    !.
require_args(Args) :-
    throw(symbolic_fault(invalid_arguments(Args))).

require_read_schema(Schema) :-
    is_dict(Schema),
    get_dict(effect, Schema, read),
    !.
require_read_schema(Schema) :-
    throw(symbolic_fault(symbolic_tools_must_be_read_only(Schema))).

evaluate_program(symbolic_program(Rules, Default), Args, Value) :-
    (   first_matching_rule(Rules, Args, Template)
    ->  render_template(Template, Args, Value)
    ;   render_template(Default, Args, Value)
    ).

first_matching_rule([rule(Condition, Template)|_], Args, Template) :-
    evaluate_condition(Condition, Args),
    !.
first_matching_rule([_|Rules], Args, Template) :-
    first_matching_rule(Rules, Args, Template).

evaluate_condition(true, _) :- !.
evaluate_condition(false, _) :- !, fail.
evaluate_condition(and(Conditions), Args) :-
    !,
    maplist(condition_holds(Args), Conditions).
evaluate_condition(or(Conditions), Args) :-
    !,
    member(Condition, Conditions),
    evaluate_condition(Condition, Args).
evaluate_condition(not(Condition), Args) :-
    !,
    \+ evaluate_condition(Condition, Args).
evaluate_condition(eq(A, B), Args) :-
    !,
    expression_value(A, Args, AV),
    expression_value(B, Args, BV),
    AV == BV.
evaluate_condition(neq(A, B), Args) :-
    !,
    expression_value(A, Args, AV),
    expression_value(B, Args, BV),
    AV \== BV.
evaluate_condition(lt(A, B), Args) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    AV < BV.
evaluate_condition(lte(A, B), Args) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    AV =< BV.
evaluate_condition(gt(A, B), Args) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    AV > BV.
evaluate_condition(gte(A, B), Args) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    AV >= BV.
evaluate_condition(in(A, B), Args) :-
    !,
    expression_value(A, Args, AV),
    expression_value(B, Args, Values),
    must_be(list, Values),
    memberchk(AV, Values).
evaluate_condition(present(Expression), Args) :-
    !,
    catch(expression_value(Expression, Args, _), _, fail).

condition_holds(Args, Condition) :-
    evaluate_condition(Condition, Args).

numeric_pair(A, B, Args, AV, BV) :-
    expression_value(A, Args, AV),
    expression_value(B, Args, BV),
    require_number(AV),
    require_number(BV).

expression_value(const(Value), _, Value) :- !.
expression_value(field(Key0), Args, Value) :-
    !,
    key_atom(Key0, Key),
    (   get_dict(Key, Args, Value)
    ->  true
    ;   throw(symbolic_fault(missing_field(Key)))
    ).
expression_value(path(Keys0), Args, Value) :-
    !,
    maplist(key_atom, Keys0, Keys),
    path_value(Keys, Args, Value).
expression_value(add(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    Value is AV+BV.
expression_value(sub(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    Value is AV-BV.
expression_value(mul(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    Value is AV*BV.
expression_value(div(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    (   BV =:= 0
    ->  throw(symbolic_fault(division_by_zero))
    ;   Value is AV/BV
    ).
expression_value(min(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    Value is min(AV, BV).
expression_value(max(A, B), Args, Value) :-
    !,
    numeric_pair(A, B, Args, AV, BV),
    Value is max(AV, BV).

path_value([], Value, Value).
path_value([Key|Keys], Dict, Value) :-
    (   is_dict(Dict),
        get_dict(Key, Dict, Next)
    ->  path_value(Keys, Next, Value)
    ;   throw(symbolic_fault(missing_path(Key)))
    ).

key_atom(Key, Key) :- atom(Key), !.
key_atom(Key0, Key) :- string(Key0), !, atom_string(Key, Key0).

require_number(Value) :-
    number(Value),
    !.
require_number(Value) :-
    throw(symbolic_fault(expected_number(Value))).

render_template(expr(Expression), Args, Value) :-
    !,
    expression_value(Expression, Args, Value).
render_template(Template, Args, Value) :-
    is_dict(Template),
    !,
    dict_pairs(Template, Tag, Pairs0),
    maplist(render_pair(Args), Pairs0, Pairs),
    dict_pairs(Value, Tag, Pairs).
render_template(Template, Args, Value) :-
    is_list(Template),
    !,
    maplist(render_item(Args), Template, Value).
render_template(Value, _, Value).

render_pair(Args, Key-Template, Key-Value) :-
    render_template(Template, Args, Value).

render_item(Args, Template, Value) :-
    render_template(Template, Args, Value).

symbolic_exception(Phase, symbolic_fault(Detail), error(Error)) :-
    !,
    Error = symbolic_error{
                phase:Phase,
                kind:invalid_symbolic_program,
                detail:Detail,
                message:"symbolic program is invalid or cannot be evaluated"
            }.
symbolic_exception(Phase, symbolic_tool_fault(Cause), error(Error)) :-
    !,
    Error = symbolic_error{
                phase:Phase,
                kind:symbolic_tool_failed,
                cause:Cause,
                message:"symbolic tool execution failed"
            }.
symbolic_exception(Phase, error(Formal, _), error(Error)) :-
    !,
    Error = symbolic_error{
                phase:Phase,
                kind:domain_error,
                detail:Formal,
                message:"symbolic program violated a runtime domain constraint"
            }.
symbolic_exception(Phase, Exception, error(Error)) :-
    safe_exception(Exception, Safe),
    Error = symbolic_error{
                phase:Phase,
                kind:symbolic_error,
                detail:Safe,
                message:"symbolic tool processing failed"
            }.

safe_exception(Exception, Safe) :-
    catch(term_string(Exception, Safe,
                      [quoted(true), numbervars(true), max_depth(8)]),
          _,
          Safe = "<unprintable>").
