:- module(rlm_tool_async,
          [ tool_invoke_async/6
          ]).

/** <module> Asynchronous facade for tool invocation

The future resolves to a single tool_async_result dict containing the ordinary
Outcome and Trace returned by tool_invoke/7.  This keeps the async API to one
opaque future while preserving the complete synchronous result surface.
*/

:- use_module(rlm_async).
:- use_module(rlm_tool).

tool_invoke_async(Registry, Capabilities, Name, Args, Options, Future) :-
    rlm_async_submit(tool_invoke_task(Registry,
                                      Capabilities,
                                      Name,
                                      Args,
                                      Options),
                     Future).

tool_invoke_task(Registry,
                 Capabilities,
                 Name,
                 Args,
                 Options,
                 Result) :-
    rlm_tool:tool_invoke(Registry,
                         Capabilities,
                         Name,
                         Args,
                         Options,
                         Outcome,
                         Trace),
    Result = tool_async_result{outcome:Outcome, trace:Trace}.
