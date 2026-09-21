:- module(rlm_source_structure, [source_structure/3]).

/** <module> Inert, file-local structural observations

Consumes source strings, never consults files or executes reader/directive
code. This is a bounded inspection adapter, not the canonical project KB or
a replacement for Tree-sitter/semantic provenance and freshness contracts.
Offsets are Unicode character offsets, end-exclusive (not byte offsets).
*/
:- use_module(library(error)).
:- use_module(library(crypto)).
:- use_module(library(readutil)).

source_structure(Language, Source, Outcome) :-
    catch((must_be(atom,Language),must_be(string,Source), string_length(Source,N),
           (N =< 65536 -> true ; resource_error(source_size)),
           (memberchk(Language,[prolog,common_lisp]) -> true
           ; domain_error(source_language,Language)),
           call_with_inference_limit(once(analyze(Language,Source,Analysis)),2000000,Limit),
           (Limit == inference_limit_exceeded -> resource_error(source_inferences); true),
           Outcome=ok(Analysis)),
          E, source_exception(E,Outcome)).

source_exception(E, _) :-
    (E=rlm_async_cancelled(_); E=rlm_cancelled(_); E=error(rlm_cancelled(_),_);
     E=time_limit_exceeded; E='$aborted'), !, throw(E).
source_exception(E,error(source_error{kind:analysis_error,detail:Text})) :-
    term_string(E,Text,[quoted(true),max_depth(8)]).

analyze(Language,Source,Analysis) :-
    crypto_data_hash(Source,HashAtom,[algorithm(sha256),encoding(utf8)]),
    atom_string(HashAtom,Hash),
    ( Language == prolog
    -> setup_call_cleanup(open_string(Source,Stream),
           prolog_terms(Stream,"user",Definitions,Refs,Declarations,Diagnostics),close(Stream))
    ; string_codes(Source,Codes),
      catch((lex(Codes,0,Tokens),forms(Tokens,Nodes),
             lisp_top(Nodes,"CL-USER",Definitions,Refs,Declarations),Diagnostics=[]),
            structure_fault(At,Reason),
            (Definitions=[],Refs=[],Declarations=[],
             Diagnostics=[diagnostic{severity:error,start:At,message:Reason}])) ),
    (Diagnostics=[] -> Status=complete ; Status=incomplete),
    maplist(resolve_reference(Language,Definitions),Refs,Resolved),
    Analysis=source_analysis{language:Language,sha256:Hash,status:Status,
        offset_unit:unicode_character,definitions:Definitions,references:Resolved,
        declarations:Declarations,diagnostics:Diagnostics,
        resolution:file_local_syntactic}.

resolve_reference(Language,Definitions,R,Resolved) :-
    findall(Start,(member(D,Definitions),Start=D.start,D.name==R.name,D.scope==R.scope,
                     D.arity==R.arity,
                     memberchk(D.kind,[predicate,dcg,function,macro,method,generic])),Targets),
    ( Targets=[] -> State=unresolved
    ; Language==prolog -> State=local_predicate
    ; Targets=[_] -> State=local_definition
    ; State=ambiguous ),
    Resolved=R.put(_{resolution:State,definition_starts:Targets}).

/* SWI's reader does not execute directives. Returning quasi_quotations/1
   prevents invocation of user quasi-quotation handlers. No op declarations
   or source modules are installed into the reader's operator environment. */
prolog_terms(S,Scope,Defs,Refs,Decls,Diagnostics) :-
    stream_property(S,position(P0)),stream_position_data(char_count,P0,At),
    catch(read_term(S,T,[module(rlm_source_structure),syntax_errors(error),
                        subterm_positions(Pos),quasi_quotations(Q)]),E,Problem=E),
    stream_property(S,position(P1)),stream_position_data(char_count,P1,End),
    ( nonvar(Problem)
    -> message_to_string(Problem,Text),Defs=[],Refs=[],Decls=[],
       Diagnostics=[diagnostic{severity:error,start:At,message:Text}]
    ; T == end_of_file,Pos=(_-TermEnd),TermEnd >= End
    -> Defs=[],Refs=[],Decls=[],Diagnostics=[]
    ; pos_start(Pos,Start),
      ( Q \== [] -> Why="quasi quotations require a trusted parser adapter"
      ; unsupported_directive(T) -> Why="operator/conditional/reader directives require a trusted project parser"
      ; Why=none ),
      ( Why \== none
      -> Defs=[],Refs=[],Decls=[],Diagnostics=[diagnostic{severity:error,start:Start,message:Why}]
      ; prolog_observation(T,Scope,Start,End,Next,D,R,C),
        prolog_terms(S,Next,Ds,Rs,Cs,Diagnostics),
        append(D,Ds,Defs),append(R,Rs,Refs),append(C,Cs,Decls) ) ).

pos_start(Pos,Start) :- compound(Pos),arg(1,Pos,Start),integer(Start),!.
pos_start(_,0).
unsupported_directive((:- Goal)) :-
    nonvar(Goal),functor(Goal,Name,_),
    memberchk(Name,[op,if,elif,else,endif,set_prolog_flag,encoding]).

prolog_observation((:- module(Name,Exports)),_,S,E,Scope,[],[],[C]) :-
    atom(Name),!,atom_string(Name,Scope),term_string(Exports,Text),
    C=declaration{kind:module,name:Scope,exports:Text,start:S,end:E}.
prolog_observation((:- Directive),Scope,S,E,Scope,[],[],[C]) :- !,
    term_string(Directive,Text,[numbervars(true),max_depth(8)]),
    C=declaration{kind:directive,text:Text,start:S,end:E}.
prolog_observation((Head --> Body),Scope,S,E,Scope,[D],Refs,[]) :- !,
    predicate_identity(Head,Scope,Name,Actual,A0),A is A0+2,
    D=definition{kind:dcg,name:Name,scope:Actual,arity:A,start:S,end:E},
    body_refs(Body,Actual,2,S,E,Refs).
prolog_observation((Head :- Body),Scope,S,E,Scope,[D],Refs,[]) :- !,
    predicate_identity(Head,Scope,Name,Actual,A),
    D=definition{kind:predicate,name:Name,scope:Actual,arity:A,start:S,end:E},
    body_refs(Body,Actual,0,S,E,Refs).
prolog_observation(Head,Scope,S,E,Scope,[D],[],[]) :-
    predicate_identity(Head,Scope,Name,Actual,A),
    D=definition{kind:predicate,name:Name,scope:Actual,arity:A,start:S,end:E}.

predicate_identity(M:H,_,Name,Scope,A) :- atom(M),nonvar(H),!,
    atom_string(M,Scope),functor(H,N,A),atom_string(N,Name).
predicate_identity(H,Scope,Name,Scope,A) :-
    (callable(H) -> functor(H,N,A),atom_string(N,Name)
    ; domain_error(predicate_head,H)).

body_refs(T,_,_,_,_,[]) :- var(T),!.
body_refs(M:T,_,Extra,S,E,Refs) :- atom(M),!,
    atom_string(M,Scope),body_refs(T,Scope,Extra,S,E,Refs).
body_refs(T,Scope,Extra,S,E,Refs) :-
    nonvar(T), T=..[Op,L,R],memberchk(Op,[',',';','->','*->']),!,
    body_refs(L,Scope,Extra,S,E,A),body_refs(R,Scope,Extra,S,E,B),append(A,B,Refs).
body_refs(\+ T,Scope,Extra,S,E,Refs) :- !,body_refs(T,Scope,Extra,S,E,Refs).
body_refs({T},Scope,2,S,E,Refs) :- !,body_refs(T,Scope,0,S,E,Refs).
body_refs(T,_,2,_,_,[]) :- (is_list(T);string(T)),!.
body_refs(!,_,_,_,_,[]) :- !.
body_refs(T,Scope,Extra,S,E,[R]) :-
    predicate_identity(T,Scope,Name,Actual,A0),A is A0+Extra,
    R=reference{kind:call,name:Name,scope:Actual,arity:A,start:S,end:E,
                span_kind:containing_clause,resolution:unresolved}.

/* Small non-evaluating Common Lisp structural reader. Unsupported reader
   syntax fails explicitly; it is never interpreted using the host reader. */
lex([],_,[]).
lex([C|Cs],N,Ts) :- code_type(C,space),!,N1 is N+1,lex(Cs,N1,Ts).
lex([59|Cs],N,Ts) :- !,line_comment(Cs,N,Rest,N1),lex(Rest,N1,Ts).
lex([35,124|Cs],N,Ts) :- !,N0 is N+2,block_comment(Cs,N0,1,Rest,N1),lex(Rest,N1,Ts).
lex([40|Cs],N,[tok(open,"",N,E)|Ts]) :- !,E is N+1,lex(Cs,E,Ts).
lex([41|Cs],N,[tok(close,"",N,E)|Ts]) :- !,E is N+1,lex(Cs,E,Ts).
lex([34|Cs],N,[tok(string,Text,N,E)|Ts]) :- !,
    N1 is N+1,quoted(Cs,N1,Chars,Rest,E),string_codes(Text,Chars),lex(Rest,E,Ts).
lex([C|Cs],N,[tok(quote,"",N,E)|Ts]) :- memberchk(C,[39,96,44]),!,
    (C=44,Cs=[64|Tail] -> Rest=Tail,E is N+2 ; Rest=Cs,E is N+1),lex(Rest,E,Ts).
lex([35,39|Cs],N,[tok(quote,"",N,E)|Ts]) :- !,E is N+2,lex(Cs,E,Ts).
lex([35,92,C|Cs],N,[tok(character,"",N,E)|Ts]) :- !,
    (code_type(C,alpha) -> atom_chars_rest(Cs,Tail,Rest),length(Tail,L),E is N+3+L
    ; Rest=Cs,E is N+3),lex(Rest,E,Ts).
lex([35,58|Cs],N,Ts) :- !,lex_atom([35,58|Cs],N,Ts).
lex([35|_],N,_) :- !,throw(structure_fault(N,"unsupported Common Lisp dispatch reader syntax" )).
lex([C|_],N,_) :- memberchk(C,[124,92]),!,throw(structure_fault(N,"escaped symbols require the full Lisp reader adapter")).
lex(Cs,N,Ts) :- lex_atom(Cs,N,Ts).

lex_atom(Cs,N,[tok(symbol,Name,N,E)|Ts]) :-
    atom_chars_rest(Cs,Chars,Rest),
    (Chars=[] -> throw(structure_fault(N,"invalid Lisp token"));true),
    (member(C,Chars),memberchk(C,[124,92]) -> throw(structure_fault(N,"escaped symbol unsupported"));true),
    length(Chars,L),E is N+L,string_codes(Text,Chars),string_upper(Text,Name),lex(Rest,E,Ts).
atom_chars_rest([C|Cs],[C|Out],Rest) :-
    \+ code_type(C,space),\+ memberchk(C,[40,41,34,39,96,44,59]),!,atom_chars_rest(Cs,Out,Rest).
atom_chars_rest(Rest,[],Rest).
line_comment([],N,[],E) :- E is N+1.
line_comment([10|Cs],N,Cs,E) :- !,E is N+2.
line_comment([_|Cs],N,Rest,E) :- N1 is N+1,line_comment(Cs,N1,Rest,E).
block_comment([],N,_,_,_) :- throw(structure_fault(N,"unclosed block comment")).
block_comment([35,124|Cs],N,D,Rest,E) :- !,D1 is D+1,N1 is N+2,block_comment(Cs,N1,D1,Rest,E).
block_comment([124,35|Cs],N,1,Cs,E) :- !,E is N+2.
block_comment([124,35|Cs],N,D,Rest,E) :- !,D1 is D-1,N1 is N+2,block_comment(Cs,N1,D1,Rest,E).
block_comment([_|Cs],N,D,Rest,E) :- N1 is N+1,block_comment(Cs,N1,D,Rest,E).
quoted([],N,_,_,_) :- throw(structure_fault(N,"unclosed string")).
quoted([34|Cs],N,[],Cs,E) :- !,E is N+1.
quoted([92,C|Cs],N,[C|Out],Rest,E) :- !,N1 is N+2,quoted(Cs,N1,Out,Rest,E).
quoted([C|Cs],N,[C|Out],Rest,E) :- N1 is N+1,quoted(Cs,N1,Out,Rest,E).

forms([],[]).
forms(Tokens,[Node|Nodes]) :- form(Tokens,Node,Rest),forms(Rest,Nodes).
form([tok(open,_,S,_)|Ts],node(list,Children,S,E),Rest) :- !,list_forms(Ts,Children,E,Rest).
form([tok(quote,_,S,_)|Ts],node(quoted,[Child],S,E),Rest) :- !,form(Ts,Child,Rest),Child=node(_,_,_,E).
form([tok(close,_,S,_)|_],_,_) :- !,throw(structure_fault(S,"unexpected closing parenthesis")).
form([tok(Type,Value,S,E)|Ts],node(Type,Value,S,E),Ts) :- !.
form([],_,_) :- throw(structure_fault(0,"missing form or closing parenthesis")).
list_forms([tok(close,_,_,E)|Ts],[],E,Ts) :- !.
list_forms(Ts,[Node|Nodes],E,Rest) :- form(Ts,Node,More),list_forms(More,Nodes,E,Rest).

lisp_top([],_,[],[],[]).
lisp_top([Node|Ns],Scope,Defs,Refs,Decls) :-
    lisp_observation(Node,Scope,Next,D,R,C),lisp_top(Ns,Next,Ds,Rs,Cs),
    append(D,Ds,Defs),append(R,Rs,Refs),append(C,Cs,Decls).
lisp_observation(node(list,[node(symbol,"IN-PACKAGE",_,_),P],S,E),_,Scope,[],[],[C]) :-
    !,package_name(P,Scope),C=declaration{kind:package,name:Scope,start:S,end:E}.
lisp_observation(node(list,[node(symbol,"DEFPACKAGE",_,_),P|Options],S,E),Scope,Scope,[],[],[C]) :-
    !,package_name(P,Name),package_option(":EXPORT",Options,Exports),
    package_option(":USE",Options,Uses),
    C=declaration{kind:package_definition,name:Name,exports:Exports,uses:Uses,start:S,end:E}.
lisp_observation(node(list,[node(symbol,Op,_,_),NameNode|Tail],S,E),Scope,Scope,[D],Refs,[]) :-
    lisp_definition_kind(Op,Kind),!,
    definition_name(NameNode,Raw),symbol_identity(Raw,Scope,Name,Actual),
    D=definition{kind:Kind,name:Name,scope:Actual,arity:unknown,start:S,end:E},
    definition_body(Op,Tail,Body),lisp_refs(Body,Actual,Refs).
lisp_observation(Node,Scope,Scope,[],Refs,[]) :- lisp_refs([Node],Scope,Refs).
lisp_definition_kind("DEFUN",function).
lisp_definition_kind("DEFMACRO",macro).
lisp_definition_kind("DEFMETHOD",method).
lisp_definition_kind("DEFGENERIC",generic).
lisp_definition_kind("DEFVAR",variable).
lisp_definition_kind("DEFPARAMETER",variable).
lisp_definition_kind("DEFCONSTANT",constant).
package_option(Key,Options,Names) :-
    findall(Name,(member(node(list,[node(symbol,Key,_,_)|Items],_,_),Options),
                  member(Item,Items),package_name(Item,Name)),Names).
definition_name(node(symbol,Name,_,_),Name) :- !.
definition_name(node(list,[node(symbol,"SETF",_,_),node(symbol,Name,_,_)],_,_),Combined) :-
    !,string_concat("(SETF ",Name,Prefix),string_concat(Prefix,")",Combined).
definition_name(node(_,_,S,_),_) :- throw(structure_fault(S,"unsupported definition name")).
definition_body(Op,[_Lambda|Body],Body) :- memberchk(Op,["DEFUN","DEFMACRO"]),!.
definition_body("DEFMETHOD",_,[]) :- !.
definition_body("DEFGENERIC",_,[]) :- !.
definition_body(_,Body,Body).
package_name(node(symbol,Raw,_,_),Name) :- !,
    (sub_string(Raw,0,2,_,"#:") -> sub_string(Raw,2,_,0,Name)
    ; sub_string(Raw,0,1,_,":") -> sub_string(Raw,1,_,0,Name);Name=Raw).
package_name(node(string,Name,_,_),Name) :- !.
package_name(node(_,_,S,_),_) :- throw(structure_fault(S,"unsupported package designator")).
symbol_identity(Raw,Default,Name,Scope) :-
    split_string(Raw,":","",Parts),
    (Parts=[Pkg,Name],Pkg\=="" -> Scope=Pkg
    ; Parts=[Pkg,"",Name],Pkg\=="" -> Scope=Pkg
    ; Name=Raw,Scope=Default).

lisp_refs([],_,[]).
lisp_refs([node(quoted,_,_,_)|Ns],Scope,Refs) :- !,lisp_refs(Ns,Scope,Refs).
lisp_refs([node(list,[node(symbol,Op,_,_)|Args],S,E)|Ns],Scope,Refs) :- !,
    (memberchk(Op,["QUOTE","QUASIQUOTE"]) -> Here=[],Inside=[]
    ; symbol_identity(Op,Scope,Name,Actual),
      Here=[reference{kind:call_candidate,name:Name,scope:Actual,arity:unknown,
                      start:S,end:E,resolution:unresolved}],
      lisp_call_body(Op,Args,Body),lisp_refs(Body,Scope,Inside)),
    lisp_refs(Ns,Scope,Other),append([Here,Inside,Other],Refs).
lisp_refs([node(list,Children,_,_)|Ns],Scope,Refs) :- !,
    lisp_refs(Children,Scope,A),lisp_refs(Ns,Scope,B),append(A,B,Refs).
lisp_refs([_|Ns],Scope,Refs) :- lisp_refs(Ns,Scope,Refs).
lisp_call_body("LAMBDA",[_|Body],Body) :- !.
lisp_call_body(Op,_,[]) :- memberchk(Op,["FLET","LABELS","MACROLET","SYMBOL-MACROLET"]),!.
lisp_call_body(Op,[_Bindings|Body],Body) :- memberchk(Op,["LET","LET*"]),!.
lisp_call_body(_,Args,Args).
