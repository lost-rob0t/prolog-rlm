:- module(rlm_tool_async,
          [ tool_invoke_async/6
          ]).

/** <module> Compatibility facade for canonical asynchronous tool invocation

The canonical async/task implementation lives in rlm_tool. This module remains
for callers that import the historical async facade directly and delegates only
to the asynchronous predicate. It never enters the synchronous public wrapper.
*/

:- use_module(rlm_tool, []).

tool_invoke_async(Registry, Capabilities, Name, Args, Options, Future) :-
    rlm_tool:tool_invoke_async(Registry,
                               Capabilities,
                               Name,
                               Args,
                               Options,
                               Future).
