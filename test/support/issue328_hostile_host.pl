/* Fresh-process hostile-host fixture for issue #328.

   A host/init-file-style `user` module legitimately defines same-named
   helpers. When `rlm_direct` imports helpers from a mid-load `rlm_completion`
   (canonical rlm.pl order: rlm_completion triggers rlm_direct's load), SWI
   resolves those not-yet-defined imports against `user`, registers them as
   imports of `rlm_completion` itself, and rejects rlm_completion's local
   clauses. That silently replaces structured fault semantics
   (`completion_fault(expected_text/1)`) with plain predicate failure.

   Modes:
     rlm               load library(rlm) (canonical entrypoint order)
     completion_first  load library(rlm_completion) only
     direct_first      load library(rlm_direct) first (order independence)

   Exits 0 when the runtime keeps local ownership and fault semantics,
   non-zero with a diagnostic marker otherwise.
*/
:- prolog_load_context(directory, Here),
   absolute_file_name('../../prolog', PrologDir,
                      [file_type(directory), relative_to(Here)]),
   asserta(user:file_search_path(library, PrologDir)).

:- multifile user:text_string/2.
:- dynamic user:text_string/2.
user:text_string(Value, Text) :- string(Value), !, Text = Value.
user:text_string(Value, Text) :- atom(Value), !, atom_string(Value, Text).

:- multifile user:require_options/1.
:- dynamic user:require_options/1.
user:require_options(_).

:- multifile user:zero_usage/1.
:- dynamic user:zero_usage/1.
user:zero_usage(zero).

load_mode(rlm) :-
    load_files(library(rlm), [silent(true)]).
load_mode(completion_first) :-
    load_files(library(rlm_completion), [silent(true)]).
load_mode(direct_first) :-
    load_files(library(rlm_direct), [silent(true)]).

% The core text conversion and shared helpers must be owned by the runtime
% module, never by an import that fell back to the hostile `user` definition.
% text_string/2 is intentionally re-exported from the rlm_text leaf module.
boundary_checks :-
    \+ predicate_property(rlm_completion:text_string(_, _), imported_from(user)),
    \+ predicate_property(rlm_completion:require_options(_), imported_from(user)),
    \+ predicate_property(rlm_completion:zero_usage(_), imported_from(user)),
    predicate_property(rlm_completion:rlm_direct_model_step(_, _, _, _, _,
                                                             _, _, _, _, _),
                       imported_from(rlm_direct)),
    rlm_completion:text_string("abc", "abc"),
    rlm_completion:text_string(hostile_atom, "hostile_atom"),
    catch(rlm_completion:text_string(foo(1), _),
          Fault,
          Fault == completion_fault(expected_text(foo(1)))),
    catch(rlm_direct:text_string(foo(1), _),
          DirectFault,
          DirectFault == completion_fault(expected_text(foo(1)))),
    rlm_completion:require_options([a]),
    catch(rlm_completion:require_options(not_a_list),
          OptionsFault,
          OptionsFault == completion_fault(invalid_options(not_a_list))),
    rlm_completion:zero_usage(Usage),
    is_dict(Usage, usage_summary),
    Usage.cost_usd == 0.0.

boundary_failure_marker(text_string_imported_from_user) :-
    predicate_property(rlm_completion:text_string(_, _), imported_from(user)).
boundary_failure_marker(require_options_imported_from_user) :-
    predicate_property(rlm_completion:require_options(_), imported_from(user)).
boundary_failure_marker(zero_usage_imported_from_user) :-
    predicate_property(rlm_completion:zero_usage(_), imported_from(user)).
boundary_failure_marker(model_step_import_unresolved) :-
    \+ predicate_property(rlm_completion:rlm_direct_model_step(_, _, _, _, _,
                                                               _, _, _, _, _),
                          imported_from(rlm_direct)).
boundary_failure_marker(string_normalization_lost) :-
    \+ rlm_completion:text_string("abc", "abc").
boundary_failure_marker(atom_normalization_lost) :-
    \+ rlm_completion:text_string(hostile_atom, "hostile_atom").
boundary_failure_marker(expected_text_fault_lost) :-
    \+ catch(rlm_completion:text_string(foo(1), _),
             Fault,
             Fault == completion_fault(expected_text(foo(1)))).
boundary_failure_marker(direct_expected_text_fault_lost) :-
    \+ catch(rlm_direct:text_string(foo(1), _),
             DirectFault,
             DirectFault == completion_fault(expected_text(foo(1)))).
boundary_failure_marker(require_options_fault_lost) :-
    \+ catch(rlm_completion:require_options(not_a_list),
             OptionsFault,
             OptionsFault == completion_fault(invalid_options(not_a_list))).
boundary_failure_marker(zero_usage_corrupted) :-
    \+ ( rlm_completion:zero_usage(Usage),
         is_dict(Usage, usage_summary),
         Usage.cost_usd == 0.0 ).

main :-
    current_prolog_flag(argv, [Mode|_]),
    atom_string(ModeAtom, Mode),
    catch(load_mode(ModeAtom),
          LoadError,
          ( print_message(error, LoadError),
            writeln('FAIL:load_error'),
            halt(2) )),
    (   boundary_checks
    ->  writeln('hostile_host_boundary_ok'),
        halt(0)
    ;   (   boundary_failure_marker(Marker)
        ->  format('FAIL:~w~n', [Marker])
        ;   writeln('FAIL:boundary_checks_failed')
        ),
        halt(3)
    ).