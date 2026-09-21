:- begin_tests(rlm_source_structure).
:- use_module('../prolog/rlm_source_structure').

test(prolog_module_calls_dcg) :-
    source_structure(prolog,":- module(demo,[hello/1]).\nhello(X) :- other:world(X), writeln(X).\nword --> [a], tail.\n",ok(A)),
    assertion(A.status == complete),
    member(D,A.definitions), D.name == "hello", assertion(D.scope == "demo"), assertion(D.arity == 1),
    member(C,A.references), C.name == "world", assertion(C.scope == "other"),
    member(G,A.definitions), G.name == "word", assertion(G.arity == 2).

test(no_directive_execution) :-
    source_structure(prolog,":- initialization(throw(executed)).\np(ok).",ok(A)),
    assertion(A.status == complete), assertion(A.definitions = [_]).

test(prolog_syntax_error) :-
    source_structure(prolog,"p( :- .",ok(A)),
    assertion(A.status == incomplete), assertion(A.diagnostics = [_|_]).

test(custom_operator_explicitly_unsupported) :-
    source_structure(prolog,":- op(500,xfx,likes).\na likes b.",ok(A)),
    assertion(A.status == incomplete).

test(lisp_forms_packages_calls) :-
    source_structure(common_lisp,"(in-package :demo)\n(defun greet (name) (format nil \"hi ~a\" name))\n(defmacro twice (x) `(progn ,x ,x))",ok(A)),
    assertion(A.status == complete),
    member(D,A.definitions), D.name == "GREET", assertion(D.scope == "DEMO"),
    member(M,A.definitions), M.name == "TWICE", assertion(M.kind == macro),
    member(C,A.references), C.name == "FORMAT".

test(lisp_comments_and_strings) :-
    source_structure(common_lisp,"; (fake)\n#| nested #| comment |# |#\n(defun real () \"not (a form)\")",ok(A)),
    assertion(A.status == complete), A.definitions = [D], assertion(D.name == "REAL").

test(lisp_reader_eval_denied) :-
    source_structure(common_lisp,"#.(delete-file \"anything\")",ok(A)),
    assertion(A.status == incomplete), assertion(A.definitions == []).

test(lisp_unbalanced) :-
    source_structure(common_lisp,"(defun nope (x) (+ x 1)",ok(A)),
    assertion(A.status == incomplete).

test(span_is_exact_unicode) :-
    Source="; λ\n(defun x () 1)\n(defun y () 2)",
    source_structure(common_lisp,Source,ok(A)), member(D,A.definitions),D.name=="X",
    Length is D.end-D.start, sub_string(Source,D.start,Length,_,Text),
    assertion(Text == "(defun x () 1)").

test(unsupported_language) :- source_structure(python,"x=1",error(_)).

test(local_predicate_resolution) :-
    source_structure(prolog,"p(a).\np(b).\nq(X) :- p(X).",ok(A)),
    A.references=[Ref],assertion(Ref.resolution==local_predicate),
    assertion(Ref.definition_starts=[_,_]).

test(local_lisp_resolution_and_quotes) :-
    source_structure(common_lisp,"(defun helper () 1)\n(defun run () (helper) '(fake call))",ok(A)),
    A.references=[Ref],assertion(Ref.name=="HELPER"),assertion(Ref.resolution==local_definition).

test(lisp_reader_conditional_is_incomplete) :-
    source_structure(common_lisp,"#+sbcl (defun x () 1)",ok(A)),assertion(A.status==incomplete).

test(prolog_quasi_quote_is_not_executed) :-
    source_structure(prolog,"p({|anything||some text|}).",ok(A)),assertion(A.status==incomplete).

test(package_exports_and_uses) :-
    source_structure(common_lisp,"(defpackage #:demo (:use #:cl) (:export #:run))",ok(A)),
    A.declarations=[D],assertion(D.name=="DEMO"),assertion(D.exports==["RUN"]),assertion(D.uses==["CL"]).

test(qualified_compound_prolog_body) :-
    source_structure(prolog,"p :- other:(a,b).",ok(A)),A.references=[ARef,BRef],
    assertion(ARef.name=="a"),assertion(BRef.name=="b"),assertion(ARef.scope=="other").

test(lisp_character_parenthesis) :-
    source_structure(common_lisp,"(defun close-char () #\\))",ok(A)),assertion(A.status==complete).

test(literal_end_of_file_is_a_predicate) :-
    source_structure(prolog,"end_of_file. p(a). % final comment",ok(A)),
    A.definitions=[First,Second],assertion(First.name=="end_of_file"),assertion(Second.name=="p").

test(local_function_shadowing_never_resolves_to_global) :-
    source_structure(common_lisp,"(defun helper () 1) (defun run () (flet ((helper () 2)) (helper)))",ok(A)),
    assertion(\+ (member(R,A.references),get_dict(name,R,"HELPER"))).
:- end_tests(rlm_source_structure).
