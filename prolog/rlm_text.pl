:- module(rlm_text,
          [ text_string/2
          ]).

/** <module> Shared text normalization leaf */

% Leaf module for the text/value normalization contract shared by the
% completion and direct runtimes (issue #328). This module depends on no
% other runtime module: both rlm_completion and rlm_direct import from it,
% and it must never import back. Keeping text_string/2 here also keeps a
% hostile host that defines user:text_string/2 from shadowing the runtime's
% own normalization through SWI's user-module import fallback.

% Strings pass through unchanged, atoms convert, and any other value raises
% the structured completion fault instead of failing silently.

text_string(Value, String) :- string(Value), !, String = Value.
text_string(Value, String) :- atom(Value), !, atom_string(Value, String).
text_string(Value, _) :-
    throw(completion_fault(expected_text(Value))).
