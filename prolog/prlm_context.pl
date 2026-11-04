:- module(prlm_context,
          [ prlm_context_ready/0,
            prlm_ctx_tokens/2,
            prlm_ctx_sources/2,
            prlm_ctx_note/4,
            prlm_ctx_note_priority/5,
            prlm_ctx_compile/3,
            prlm_ctx_op/3,
            prlm_context_destroy/1
          ]).

/** <module> prlm_context — host-side session glue for the in-language context ops

The context operations themselves live IN THE LANGUAGE: lang/prlm_ctx.prlm is
consulted into a prlm engine (module prlm_ctx) and every operation runs on the
engine's own machine. This module is only the deterministic host boundary:

  * it keeps per-session material as dynamic session_fact/7 facts with an
    appender (prlm_ctx_note/4, prlm_ctx_note_priority/5) that assigns
    sequential ids (s1, s2, ...) and kind-defaulted priorities;
  * it converts atom|string content and query atoms into the engine's
    canonical text form (character-code lists) — the engine kernel exposes
    no atom/string introspection, so the conversion must happen here;
  * it caches one engine handle and one compiled context per session
    (recompiled only when the section count changes);
  * prlm_ctx_op/3 validates and dispatches inspect/search/select/slice/
    transform/delegate/aggregate onto prlm_ctx predicates.

Nothing here calls an LLM or any network service: every operation is a pure,
deterministic Prolog computation. Errors are throw(prlm_error(Type, Info))
with dict Info; errors originating inside the engine (whose info is a plain
compound, since the engine has no dicts) are unwrapped and rethrown as-is.
*/

:- use_module(prlm_kernel).
:- use_module(library(lists)).
:- use_module(library(readutil)).

% session_fact(Session, Seq, Id, Kind, Content, Tokens, Priority)
:- dynamic session_fact/7.
:- dynamic session_counter/2.   % session_counter(Session, LastSeq)
:- dynamic ctx_engine/2.        % ctx_engine(Session, Engine)
:- dynamic ctx_cache/3.         % ctx_cache(Session, SectionCount, Compiled)
:- dynamic ctx_lang_source/1.   % ctx_lang_source(Text)

% Load lang/prlm_ctx.prlm once (path relative to this file): its text is
% consulted into every engine this module creates.
:- (   prolog_load_context(source, Src),
       file_directory_name(Src, Dir),
       atom_concat(Dir, '/../lang/prlm_ctx.prlm', Rel),
       absolute_file_name(Rel, LangAbs),
       read_file_to_string(LangAbs, LangText, []),
       assertz(ctx_lang_source(LangText))
   ->  true
   ;   print_message(warning, prlm_context(ctx_lang_source_not_found))
   ).

prlm_context_ready :-
    prlm_kernel:prlm_kernel_ready.

% ------------------------------------------------------------
% kind -> default priority
% ------------------------------------------------------------

kind_priority(fact, 5).
kind_priority(rule, 5).
kind_priority(memory, 5).
kind_priority(tool_result, 7).
kind_priority(evidence, 7).
kind_priority(attempt, 3).
kind_priority(artifact, 3).
kind_priority(child_result, 6).
kind_priority(conversation, 4).
kind_priority(file, 2).
kind_priority(source, 2).

% ------------------------------------------------------------
% notes
% ------------------------------------------------------------

prlm_ctx_note(Session, Kind, Content, Section) :-
    (   kind_priority(Kind, Priority)
    ->  prlm_ctx_note_priority(Session, Kind, Content, Priority, Section)
    ;   throw(prlm_error(type_error, _{ctx_kind: Kind}))
    ).

prlm_ctx_note_priority(Session, Kind, Content, Priority, Section) :-
    must_session(Session),
    must_kind(Kind),
    must_priority(Priority),
    ensure_engine(Session, Engine),
    ctx_tokens_via_engine(Engine, Content, Tokens),
    next_seq(Session, Seq, Id),
    assertz(session_fact(Session, Seq, Id, Kind, Content, Tokens, Priority)),
    Section = section(Id, Kind, Content, Tokens, Priority, note).

%! prlm_ctx_sources(+Session, -Sections) is det
%
% All noted sections for Session in insertion (id) order, in host form:
% content keeps its original atom|string|term shape.
prlm_ctx_sources(Session, Sections) :-
    must_session(Session),
    findall(fact(Seq, Id, Kind, Content, Tokens, Priority),
            session_fact(Session, Seq, Id, Kind, Content, Tokens, Priority),
            Facts),
    facts_by_seq(Facts, Ordered),
    facts_sections(Ordered, Sections).

facts_by_seq([], []).
facts_by_seq([F|Fs], Sorted) :-
    facts_by_seq(Fs, Sorted0),
    insert_fact(F, Sorted0, Sorted).

insert_fact(F, [], [F]) :- !.
insert_fact(F, [G|Gs], [F, G|Gs]) :-
    F = fact(Seq, _, _, _, _, _),
    G = fact(Seq2, _, _, _, _, _),
    Seq =< Seq2,
    !.
insert_fact(F, [G|Gs], [G|Rest]) :-
    insert_fact(F, Gs, Rest).

facts_sections([], []).
facts_sections([fact(_, Id, Kind, Content, Tokens, Priority)|Rest],
               [section(Id, Kind, Content, Tokens, Priority, note)|Sections]) :-
    facts_sections(Rest, Sections).

% ------------------------------------------------------------
% tokens + compile
% ------------------------------------------------------------

%! prlm_ctx_tokens(+Text, -Tokens) is det
%
% Host convenience delegating to the engine's ctx_tokens/2. Text may be an
% atom, string, number, character-code list, or an arbitrary ground term
% (counted in its written structure).
prlm_ctx_tokens(Text, Tokens) :-
    ensure_engine('$prlm_ctx_default', Engine),
    ctx_tokens_via_engine(Engine, Text, Tokens).

ctx_tokens_via_engine(Engine, Content, Tokens) :-
    (   atomic(Content)
    ->  content_codes(Content, Codes),
        engine_call(Engine, ctx_tokens(Codes), Tokens)
    ;   compound(Content)
    ->  engine_call(Engine, ctx_tokens(Content), Tokens)
    ;   throw(prlm_error(instantiation_error, _{ctx_text: Content}))
    ).

%! prlm_ctx_compile(+Session, +Budget, -Compiled) is det
%
% Gather all noted sections for Session and run prlm_ctx:ctx_compile/3 in
% the session's engine.
prlm_ctx_compile(Session, Budget, Compiled) :-
    must_session(Session),
    must_budget(Budget),
    prlm_ctx_sources(Session, Sections),
    sections_for_engine(Sections, EngSections),
    ensure_engine(Session, Engine),
    engine_call(Engine, ctx_compile(EngSections, Budget), Compiled).

sections_for_engine([], []).
sections_for_engine([S|Ss], [E|Es]) :-
    must_section(S),
    S = section(Id, Kind, Content, Tokens, Priority, Prov),
    (   atomic(Content)
    ->  content_codes(Content, CR)
    ;   CR = Content
    ),
    E = section(Id, Kind, CR, Tokens, Priority, Prov),
    sections_for_engine(Ss, Es).

% ------------------------------------------------------------
% generic op dispatcher
% ------------------------------------------------------------

%! prlm_ctx_op(+Session, +Op, -Out) is det
%
% Op = inspect | search(QueryAtoms) | select(Filter) | slice(Ids)
%    | transform(Transform) | delegate(Spec)
%    | aggregate(OtherCompiledList, Budget)
%
% Runs the matching prlm_ctx operation on the CURRENT compiled context of
% the session (recompiled from the noted sections with budget 100000 and
% cached while the section count is unchanged). aggregate merges the
% current context with the given other contexts.
prlm_ctx_op(Session, Op, Out) :-
    must_session(Session),
    (   op_shape(Op)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_op: Op}))
    ),
    current_compiled(Session, C),
    ensure_engine(Session, Engine),
    dispatch_op(Engine, C, Op, Out).

op_shape(inspect).
op_shape(search(_)).
op_shape(select(_)).
op_shape(slice(_)).
op_shape(transform(_)).
op_shape(delegate(_)).
op_shape(aggregate(_, _)).

dispatch_op(Engine, C, inspect, Info) :- !,
    engine_call(Engine, ctx_inspect(C), Info).
dispatch_op(Engine, C, search(Q), Matches) :- !,
    queries_codes(Q, QC),
    engine_call(Engine, ctx_search(C, QC), Matches).
dispatch_op(Engine, C, select(F), Sections) :- !,
    check_filter(F),
    engine_call(Engine, ctx_select(C, F), Sections).
dispatch_op(Engine, C, slice(Ids), SubCtx) :- !,
    check_ids(Ids),
    engine_call(Engine, ctx_slice(C, Ids), SubCtx).
dispatch_op(Engine, C, transform(T), Out) :- !,
    check_transform(T),
    engine_call(Engine, ctx_transform(C, T), Out).
dispatch_op(Engine, C, delegate(S), Partitions) :- !,
    check_delegate(S),
    engine_call(Engine, ctx_delegate(C, S), Partitions).
dispatch_op(Engine, C, aggregate(Others, Budget), Merged) :- !,
    check_compiled_list(Others),
    must_budget(Budget),
    engine_call(Engine, ctx_aggregate([C|Others], Budget), Merged).

% Single clauses with if-then-else on purpose: a multi-clause validator
% whose later clause throws would fire that throw again during plain
% backtracking (when an earlier continuation fails), masking the real
% cause. The if-then-else commits and cannot re-enter.
queries_codes(Q, QC) :-
    (   is_query_list(Q)
    ->  maplist(query_codes, Q, QC)
    ;   throw(prlm_error(type_error, _{ctx_queries: Q}))
    ).

is_query_list(Q) :-
    is_list(Q),
    all_atoms(Q).

query_codes(Q, Codes) :-
    (   atom(Q)
    ->  atom_codes(Q, Codes)
    ;   string(Q)
    ->  string_codes(Q, Codes)
    ;   throw(prlm_error(type_error, _{ctx_query: Q}))
    ).

check_filter(F) :-
    (   F == all
    ->  true
    ;   F = kinds(L)
    ->  check_atom_list(L, ctx_kinds, L)
    ;   F = min_priority(P)
    ->  must_priority(P)
    ;   F = ids(L)
    ->  check_atom_list(L, ctx_ids, L)
    ;   throw(prlm_error(type_error, _{ctx_filter: F}))
    ).

check_atom_list(L, Tag, Bad) :-
    (   is_list(L),
        all_atoms(L)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_atom_list: Bad, ctx_what: Tag}))
    ).

all_atoms([]).
all_atoms([A|As]) :-
    atom(A),
    all_atoms(As).

check_ids(L) :-
    check_atom_list(L, ctx_ids, L).

check_transform(T) :-
    (   T = truncate_tokens(B)
    ->  must_budget(B)
    ;   T = redact_kind(K)
    ->  (   atom(K)
        ->  true
        ;   throw(prlm_error(type_error, _{ctx_redact_kind: K}))
        )
    ;   T = keep_kinds(L)
    ->  check_atom_list(L, ctx_keep_kinds, L)
    ;   throw(prlm_error(type_error, _{ctx_transform: T}))
    ).

check_delegate(S) :-
    (   S == by_kinds
    ->  true
    ;   S = by_count(N)
    ->  (   integer(N), N >= 1
        ->  true
        ;   throw(prlm_error(type_error, _{ctx_delegate: S}))
        )
    ;   throw(prlm_error(type_error, _{ctx_delegate: S}))
    ).

check_compiled_list([]).
check_compiled_list([C|Cs]) :-
    check_compiled(C),
    check_compiled_list(Cs).

check_compiled(C) :-
    (   C = compiled(S, T, D),
        is_list(S),
        integer(T),
        is_list(D)
    ->  check_sections(S)
    ;   throw(prlm_error(type_error, _{ctx_compiled: C}))
    ).

check_sections([]).
check_sections([S|Ss]) :-
    must_section(S),
    check_sections(Ss).

% ------------------------------------------------------------
% engine registry + compiled-context cache
% ------------------------------------------------------------

ensure_engine(Session, Engine) :-
    (   ctx_engine(Session, Engine)
    ->  true
    ;   retractall(ctx_engine(Session, _)),
        prlm_engine_new([max_steps(1000000)], Engine),
        assertz(ctx_engine(Session, Engine)),
        prime_engine(Engine)
    ).

prime_engine(Engine) :-
    (   ctx_lang_source(Text)
    ->  prlm_consult_source(Engine, prlm_ctx, Text, prlm_ctx_lang)
    ;   throw(prlm_error(existence_error, _{ctx_lang_source: 'lang/prlm_ctx.prlm'}))
    ).

current_compiled(Session, C) :-
    session_count(Session, N),
    (   ctx_cache(Session, N, C)
    ->  true
    ;   prlm_ctx_compile(Session, 100000, C),
        retractall(ctx_cache(Session, _, _)),
        assertz(ctx_cache(Session, N, C))
    ).

session_count(Session, N) :-
    findall(x, session_fact(Session, _, _, _, _, _, _), Xs),
    length(Xs, N).

next_seq(Session, Seq, Id) :-
    (   retract(session_counter(Session, N0)) -> true ; N0 = 0 ),
    Seq is N0 + 1,
    assertz(session_counter(Session, Seq)),
    atom_concat('s', Seq, Id).

% ------------------------------------------------------------
% teardown
% ------------------------------------------------------------

prlm_context_destroy(Session) :-
    (   ctx_engine(Session, Engine)
    ->  catch(prlm_engine_destroy(Engine), _, true)
    ;   true
    ),
    retractall(ctx_engine(Session, _)),
    retractall(ctx_cache(Session, _, _)),
    retractall(session_fact(Session, _, _, _, _, _, _)),
    retractall(session_counter(Session, _)).

% ------------------------------------------------------------
% engine call + error unwrapping
% ------------------------------------------------------------

% Append an engine-variable output slot, run deterministically in module
% prlm_ctx, and project the result. prlm_query_all hands back RAW machine
% environments: compound values still contain unresolved '$v'(Name)
% placeholders, so the caller must dereference them against the env
% (kernel project/3 is not exported). Engine-origin throws arrive wrapped
% as prlm_error(uncaught_throw, _{ball: prlm_error(T, I)}); they are
% unwrapped so callers see the error the language intended to raise.
engine_call(Engine, Callable, Out) :-
    Callable =.. List0,
    append(List0, ['$v'('CtxOut')], List),
    Goal =.. List,
    catch((   prlm_query_first(Engine, prlm_ctx, Goal, Env)
          ->  get_dict('CtxOut', Env, Out0),
              ctx_project(Env, Out0, Out)
          ;   throw(prlm_error(existence_error, _{ctx_goal: Goal}))
          ),
          prlm_error(uncaught_throw, Info),
          (   get_dict(ball, Info, Ball),
              Ball = prlm_error(Type, BallInfo)
          ->  throw(prlm_error(Type, BallInfo))
          ;   throw(prlm_error(uncaught_throw, Info))
          )).

ctx_project(Env, T0, T) :-
    (   ctx_is_evar(T0, Name)
    ->  (   get_dict(Name, Env, V)
        ->  ctx_project(Env, V, T)
        ;   T = T0
        )
    ;   compound(T0)
    ->  T0 =.. [F|As],
        ctx_projects(Env, As, As2),
        T =.. [F|As2]
    ;   T = T0
    ).

ctx_projects(_, [], []).
ctx_projects(Env, [A|As], [A2|As2]) :-
    ctx_project(Env, A, A2),
    ctx_projects(Env, As, As2).

ctx_is_evar(T, Name) :-
    nonvar(T),
    functor(T, '$v', 1),
    arg(1, T, Name).

% ------------------------------------------------------------
% validation helpers
% ------------------------------------------------------------

must_session(Session) :-
    (   atom(Session)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_session: Session}))
    ).

must_kind(Kind) :-
    (   kind_priority(Kind, _)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_kind: Kind}))
    ).

must_priority(P) :-
    (   integer(P)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_priority: P}))
    ).

must_budget(B) :-
    (   integer(B), B >= 0
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_budget: B}))
    ).

must_section(S) :-
    (   S = section(Id, Kind, Content, Tokens, Priority, Prov),
        atom(Id),
        kind_priority(Kind, _),
        nonvar(Content),
        integer(Tokens),
        integer(Priority),
        atom(Prov)
    ->  true
    ;   throw(prlm_error(type_error, _{ctx_section: S}))
    ).

content_codes(Text, Codes) :-
    (   string(Text)
    ->  string_codes(Text, Codes)
    ;   atom(Text)
    ->  atom_codes(Text, Codes)
    ;   number(Text)
    ->  number_codes(Text, Codes)
    ;   throw(prlm_error(type_error, _{ctx_text: Text}))
    ).
