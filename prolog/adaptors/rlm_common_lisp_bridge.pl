:- module(rlm_common_lisp_bridge,
          [ bridge_main/0
          ]).

/** <module> Framed Common Lisp process adapter

The adapter exposes exported predicates from loaded prolog-rlm modules over a
small line protocol.  It is intended for a trusted local host process.

Requests are TAB-separated:

  Id<TAB>OP<TAB>MODULE<TAB>PAYLOAD

CALL payloads use six-hex-digit Unicode scalar framing.  Replies are restricted
Common Lisp s-expressions.  The Lisp client reads them with *READ-EVAL* NIL.

Only exported predicates from loaded modules named rlm or rlm_* may be called.
A CALL payload must be one direct predicate goal; module qualification,
conjunctions, and arbitrary system predicates are rejected.
*/

:- use_module(library(readutil)).
:- use_module('../rlm').
:- use_module('../rlm_symbolic_tool').

bridge_main :-
    set_stream(user_input, encoding(utf8)),
    set_stream(user_output, encoding(utf8)),
    bridge_loop.

bridge_loop :-
    read_line_to_string(user_input, Line),
    (   Line == end_of_file
    ->  true
    ;   bridge_handle_line(Line, Continue),
        (Continue == true -> bridge_loop ; true)
    ).

bridge_handle_line(Line, Continue) :-
    catch(bridge_request(Line, Reply, Continue0),
          Exception,
          ( safe_term_text(Exception, ErrorText),
            Reply = reply{id:0,status:error,error:ErrorText},
            Continue0 = true
          )),
    write_lisp(Reply),
    nl,
    flush_output,
    Continue = Continue0.

bridge_request(Line, Reply, Continue) :-
    split_string(Line, "\t", "", Fields),
    (   Fields = [IdText, OpText, ModuleText, Payload]
    ->  true
    ;   throw(error(domain_error(bridge_request, Line), _))
    ),
    number_string(Id, IdText),
    string_upper(OpText, Op),
    bridge_operation(Op, Id, ModuleText, Payload, Reply, Continue).

bridge_operation("HELLO", Id, _, _, Reply, true) :-
    rlm:rlm_version(Version0),
    atom_string(Version0, Version),
    module_exports(rlm, Exports),
    length(Exports, Count),
    Reply = reply{id:Id,
                  status:ok,
                  protocol:"PROLOG-RLM-CL/1",
                  version:Version,
                  root_exports:Count}.
bridge_operation("EXPORTS", Id, ModuleText, _, Reply, true) :-
    bridge_module(ModuleText, Module),
    module_exports(Module, Exports),
    Reply = reply{id:Id,status:ok,module:ModuleText,exports:Exports}.
bridge_operation("CALL", Id, ModuleText, Payload, Reply, true) :-
    bridge_module(ModuleText, Module),
    uhex_decode(Payload, GoalText),
    call_exported(Module, GoalText, Status, Bindings),
    Reply = reply{id:Id,status:Status,bindings:Bindings}.
bridge_operation("SHUTDOWN", Id, _, _, Reply, false) :-
    Reply = reply{id:Id,status:ok,shutdown:true}.
bridge_operation(Op, _, _, _, _, _) :-
    throw(error(domain_error(bridge_operation, Op), _)).

bridge_module(ModuleText, Module) :-
    atom_string(Module, ModuleText),
    current_module(Module),
    allowed_rlm_module(Module),
    !.
bridge_module(ModuleText, _) :-
    throw(error(permission_error(call, prolog_module, ModuleText), _)).

allowed_rlm_module(rlm).
allowed_rlm_module(Module) :-
    atom(Module),
    atom_concat(rlm_, _, Module).

module_exports(Module, Exports) :-
    findall(Text,
            exported_indicator(Module, Text),
            Exports0),
    sort(Exports0, Exports).

exported_indicator(Module, Text) :-
    predicate_property(Module:Head, exported),
    functor(Head, Name, Arity),
    format(string(Text), "~w/~d", [Name, Arity]).

call_exported(Module, GoalText, Status, Bindings) :-
    term_string(Goal, GoalText,
                [ variable_names(Variables),
                  syntax_errors(error)
                ]),
    require_direct_goal(Goal),
    require_exported(Module, Goal),
    (   once(call(Module:Goal))
    ->  Status = ok,
        binding_rows(Variables, Bindings)
    ;   Status = failure,
        Bindings = []
    ).

require_direct_goal(Goal) :-
    callable(Goal),
    \+ Goal = (_:_),
    \+ Goal = (_,_),
    \+ Goal = (_;_),
    \+ Goal = (_->_),
    \+ Goal = (\+_),
    !.
require_direct_goal(Goal) :-
    throw(error(permission_error(call, compound_goal, Goal), _)).

require_exported(Module, Goal) :-
    predicate_property(Module:Goal, exported),
    !.
require_exported(Module, Goal) :-
    functor(Goal, Name, Arity),
    throw(error(permission_error(call, exported_predicate,
                                 Module:Name/Arity), _)).

binding_rows([], []).
binding_rows([Name=Value|Variables],
             [binding{name:NameText,term:ValueText}|Bindings]) :-
    atom_string(Name, NameText),
    safe_term_text(Value, ValueText),
    binding_rows(Variables, Bindings).

safe_term_text(Value, Text) :-
    catch(term_string(Value, Text,
                      [ quoted(true),
                        numbervars(true),
                        ignore_ops(true),
                        max_depth(64)
                      ]),
          _,
          Text = "<unprintable>").

uhex_decode("-", "") :- !.
uhex_decode(Hex, Text) :-
    string_length(Hex, Length),
    0 is Length mod 6,
    uhex_codes(Hex, 0, Length, Codes),
    string_codes(Text, Codes).

uhex_codes(_, Offset, Length, []) :-
    Offset >= Length,
    !.
uhex_codes(Hex, Offset, Length, [Code|Codes]) :-
    sub_string(Hex, Offset, 6, _, Chunk),
    atom_string(ChunkAtom, Chunk),
    atom_concat('0x', ChunkAtom, NumberAtom),
    atom_number(NumberAtom, Code),
    valid_unicode_scalar(Code),
    Next is Offset+6,
    uhex_codes(Hex, Next, Length, Codes).

valid_unicode_scalar(Code) :-
    integer(Code),
    Code >= 0,
    Code =< 0x10ffff,
    \+ (Code >= 0xd800, Code =< 0xdfff).

write_lisp(Value) :-
    is_dict(Value),
    !,
    dict_pairs(Value, _, Pairs),
    put_char('('),
    write_lisp_pairs(Pairs),
    put_char(')').
write_lisp(Value) :-
    is_list(Value),
    !,
    put_char('('),
    write_lisp_list(Value),
    put_char(')').
write_lisp(Value) :-
    string(Value),
    !,
    write_lisp_string(Value).
write_lisp(Value) :-
    number(Value),
    !,
    write(Value).
write_lisp(true) :- !, write(t).
write_lisp(false) :- !, write(nil).
write_lisp(Value) :-
    atom(Value),
    !,
    write(':'),
    write(Value).
write_lisp(Value) :-
    safe_term_text(Value, Text),
    write_lisp_string(Text).

write_lisp_pairs([]).
write_lisp_pairs([Key-Value|Pairs]) :-
    write(':'),
    write(Key),
    write(' '),
    write_lisp(Value),
    (Pairs == [] -> true ; write(' ')),
    write_lisp_pairs(Pairs).

write_lisp_list([]).
write_lisp_list([Value|Values]) :-
    write_lisp(Value),
    (Values == [] -> true ; write(' ')),
    write_lisp_list(Values).

write_lisp_string(Text) :-
    string_codes(Text, Codes),
    put_code(0'"),
    maplist(write_lisp_string_code, Codes),
    put_code(0'").

write_lisp_string_code(0'") :- !, write('\\\"').
write_lisp_string_code(0'\\) :- !, write('\\\\').
write_lisp_string_code(10) :- !, write('\\n').
write_lisp_string_code(13) :- !, write('\\r').
write_lisp_string_code(9) :- !, write('\\t').
write_lisp_string_code(Code) :- put_code(Code).
