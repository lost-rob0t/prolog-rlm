:- module(rlm_runtime_status,
          [ runtime_status/4,
            runtime_status_line/2
          ]).

/** <module> Canonical renderer-neutral runtime status projection

This module projects model identity, cumulative token I/O, and current context
occupancy into frontend-safe status data.  It owns no UI and performs no model,
context, or provider work.

Cumulative usage is deliberately separate from current context occupancy.  A
multi-call RLM trajectory may consume many prompt/completion tokens while only
one bounded context is currently active, so context percentage is accepted only
from an explicit current-context observation.  Unknown capacity stays unknown;
renderers must not guess it from cumulative usage.
*/

runtime_status(Model0, Usage, Context, Status) :-
    model_text(Model0, Model),
    usage_tokens(Usage, prompt_tokens, InputTokens),
    usage_tokens(Usage, completion_tokens, OutputTokens),
    context_status(Context,
                   ContextTokens,
                   ContextWindow,
                   ContextPercent),
    Status = runtime_status{
                 model:Model,
                 input_tokens:InputTokens,
                 output_tokens:OutputTokens,
                 context_tokens:ContextTokens,
                 context_window:ContextWindow,
                 context_percent:ContextPercent
             }.

runtime_status_line(Status, Line) :-
    require_status(Status),
    context_percent_text(Status.context_percent, ContextText),
    format(string(Line),
           '~s · in ~d · out ~d · ctx ~s',
           [Status.model,
            Status.input_tokens,
            Status.output_tokens,
            ContextText]).

model_text(Model, Text) :-
    string(Model),
    Model \== "",
    !,
    Text = Model.
model_text(Model, Text) :-
    atom(Model),
    Model \== '',
    !,
    atom_string(Model, Text).
model_text(Model, _) :-
    throw(error(domain_error(runtime_model, Model),
                context(rlm_runtime_status:runtime_status/4,
                        'model must be a non-empty atom or string'))).

usage_tokens(Usage, Key, Tokens) :-
    is_dict(Usage),
    get_dict(Key, Usage, Value),
    integer(Value),
    Value >= 0,
    !,
    Tokens = Value.
usage_tokens(Usage, Key, _) :-
    throw(error(domain_error(runtime_usage(Key), Usage),
                context(rlm_runtime_status:runtime_status/4,
                        'usage token counters must be non-negative integers'))).

context_status(unknown, unknown, unknown, unknown) :- !.
context_status(context(Current, Window), Current, Window, Percent) :-
    integer(Current),
    Current >= 0,
    integer(Window),
    Window > 0,
    !,
    Percent is round((Current * 100) / Window).
context_status(Context, _, _, _) :-
    throw(error(domain_error(runtime_context, Context),
                context(rlm_runtime_status:runtime_status/4,
                        'context must be unknown or context(Current, Window)'))).

context_percent_text(unknown, "?") :- !.
context_percent_text(Percent, Text) :-
    integer(Percent),
    Percent >= 0,
    !,
    format(string(Text), '~d%', [Percent]).
context_percent_text(Value, _) :-
    throw(error(domain_error(context_percent, Value),
                context(rlm_runtime_status:runtime_status_line/2,
                        'context percent must be unknown or a non-negative integer'))).

require_status(Status) :-
    is_dict(Status, runtime_status),
    string(Status.model),
    integer(Status.input_tokens),
    Status.input_tokens >= 0,
    integer(Status.output_tokens),
    Status.output_tokens >= 0,
    !.
require_status(Status) :-
    throw(error(domain_error(runtime_status, Status),
                context(rlm_runtime_status:runtime_status_line/2,
                        'invalid runtime status projection'))).
