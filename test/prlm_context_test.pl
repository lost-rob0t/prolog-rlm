:- begin_tests(prlm_context).

:- use_module('../prolog/prlm_kernel').
:- use_module('../prolog/prlm_context').
:- use_module(library(readutil)).
:- use_module(library(lists)).

% ============================================================
% Helpers
% ============================================================

:- dynamic lang_file/1.

:- prolog_load_context(source, Src),
   file_directory_name(Src, Dir),
   atom_concat(Dir, '/../lang/prlm_ctx.prlm', Rel),
   absolute_file_name(Rel, Lang),
   assertz(lang_file(Lang)).

% One fresh engine per call with the in-language context ops consulted
% from disk, exactly as stage1 material is loaded.
with_engine(Engine) :-
    prlm_engine_new([max_steps(1000000)], Engine),
    lang_file(Lang),
    read_file_to_string(Lang, Text, []),
    prlm_consult_source(Engine, prlm_ctx, Text, ctx_test_lang).

txt_codes(Text, Codes) :-
    (   string(Text)
    ->  string_codes(Text, Codes)
    ;   atom_codes(Text, Codes)
    ).

% Engine-canonical section with content as character codes.
esec(Id, Kind, Text, Tokens, Priority, section(Id, Kind, Codes, Tokens, Priority, t)) :-
    txt_codes(Text, Codes).

% Run a prlm_ctx predicate with its output argument appended. The kernel's
% prlm_query_first returns a raw machine env, so the projected value must
% be dereferenced against it (compound values can still hold '$v'(Name)
% placeholders).
ctx_call(Engine, Partial, Out) :-
    Partial =.. List0,
    append(List0, ['$v'('CtxOut')], List),
    Goal =.. List,
    (   prlm_query_first(Engine, prlm_ctx, Goal, Env)
    ->  get_dict('CtxOut', Env, Out0),
        ctx_project(Env, Out0, Out)
    ;   throw(prlm_error(existence_error, _{test_goal: Goal}))
    ).

ctx_project(Env, T0, T) :-
    (   nonvar(T0), functor(T0, '$v', 1), arg(1, T0, Name)
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

% Canonical sample set. Compiled order must be s2, s3 (priority 9, id asc),
% s1 (priority 5), s4 (priority 1); total tokens 8.
sample_sections(S1, S2, S3, S4) :-
    esec('s1', memory, "Alpha Beta", 3, 5, S1),
    esec('s2', fact,   "gamma delta", 2, 9, S2),
    esec('s3', fact,   "epsilon", 2, 9, S3),
    esec('s4', memory, "zeta", 1, 1, S4).

codes_of(Text, Codes) :-
    txt_codes(Text, Codes).

% ============================================================
% Engine-direct: ctx_tokens
% ============================================================

test(engine_tokens_codes, []) :-
    with_engine(E),
    codes_of("a b c", C1),
    ctx_call(E, ctx_tokens(C1), T1),
    T1 == 4,                                  % ceil(3 * 1.3) = 4
    codes_of("one", C2),
    ctx_call(E, ctx_tokens(C2), T2),
    T2 == 2,                                  % ceil(1.3) = 2
    ctx_call(E, ctx_tokens([]), T3),
    T3 == 1,                                  % max(1, 0)
    codes_of("AA BB", C4),
    ctx_call(E, ctx_tokens(C4), T4),
    T4 == 3,                                  % ceil(2 * 1.3) = 3
    prlm_engine_destroy(E).

test(engine_tokens_written_forms, []) :-
    with_engine(E),
    ctx_call(E, ctx_tokens(foo(bar, baz)), T1),
    T1 == 4,                                  % functor + 2 atomic args = 3 words
    codes_of("hello world", HW),
    ctx_call(E, ctx_tokens([HW]), _),         % list-of-lists counts as one word run
    codes_of("x", X),
    append(X, [32], XSep),
    ctx_call(E, ctx_tokens(XSep), T2),
    T2 == 2,                                  % "x " = 1 word
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_compile
% ============================================================

test(engine_compile_order, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S4, S3, S2, S1], 100), C),
    C == compiled([S2, S3, S1, S4], 8, []),
    prlm_engine_destroy(E).

test(engine_compile_empty, []) :-
    with_engine(E),
    ctx_call(E, ctx_compile([], 10), C),
    C == compiled([], 0, []),
    prlm_engine_destroy(E).

% Greedy fit CONTINUES after a drop: with budget 6 the ordered stream is
% s2(2) s3(2) s1(3) s4(1); s1 does not fit (7 > 6) but s4 still does.
test(engine_compile_budget_greedy_continues, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 6), C),
    C == compiled([S2, S3, S4], 5, [S1]),
    prlm_engine_destroy(E).

% Dropped sections appear in consideration order (priority desc, id asc).
test(engine_compile_budget_drop_order, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 3), C),
    C == compiled([S2, S4], 3, [S3, S1]),
    prlm_engine_destroy(E).

% Determinism: running the op twice gives structurally identical results.
test(engine_compile_pure_double_run, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S4, S1, S3, S2], 7), C1),
    ctx_call(E, ctx_compile([S4, S1, S3, S2], 7), C2),
    C1 == C2,
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_search
% ============================================================

test(engine_search_scoring_and_order, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    codes_of("beta", B),
    codes_of("gamma", G),
    % s1 ("Alpha Beta") scores 1 on beta, s2 ("gamma delta") scores 1 on
    % gamma; tie on score is broken by id ascending.
    ctx_call(E, ctx_search(C, [B, G]), M1),
    M1 == [match('s1', 1), match('s2', 1)],
    codes_of("delta", D),
    % [gamma, delta]: s2 matches both -> score 2, beats s1's absence.
    ctx_call(E, ctx_search(C, [G, D]), M2),
    M2 == [match('s2', 2)],
    codes_of("zzz", Z),
    ctx_call(E, ctx_search(C, [Z]), M3),
    M3 == [],
    prlm_engine_destroy(E).

test(engine_search_case_insensitive, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    % UPPERCASE query atom still matches "Alpha Beta" content.
    codes_of("BETA", Bup),
    ctx_call(E, ctx_search(C, [Bup]), M1),
    M1 == [match('s1', 1)],
    codes_of("ALPHA", Aup),
    codes_of("DELTA", Dup),
    ctx_call(E, ctx_search(C, [Aup, Dup]), M2),
    M2 == [match('s1', 1), match('s2', 1)],
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_select / ctx_slice
% ============================================================

test(engine_select_filters, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_select(C, all), A),
    A == [S2, S3, S1, S4],
    ctx_call(E, ctx_select(C, kinds([fact])), K),
    K == [S2, S3],
    ctx_call(E, ctx_select(C, min_priority(5)), P),
    P == [S2, S3, S1],
    ctx_call(E, ctx_select(C, ids(['s1', 's4'])), I),
    I == [S1, S4],
    prlm_engine_destroy(E).

test(engine_slice, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_slice(C, ['s4', 's1']), Sub),
    % compiled order is kept even though ids were given reversed
    Sub == compiled([S1, S4], 4, []),
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_transform
% ============================================================

test(engine_transform_truncate_tokens, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_transform(C, truncate_tokens(4)), T),
    T == compiled([S2, S3], 4, [S1, S4]),
    prlm_engine_destroy(E).

test(engine_transform_redact_kind, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_transform(C, redact_kind(fact)), R),
    Redacted = [114, 101, 100, 97, 99, 116, 101, 100],
    R == compiled([section('s2', fact, Redacted, 2, 9, t),
                   section('s3', fact, Redacted, 2, 9, t),
                   S1,
                   S4],
                  8, []),
    prlm_engine_destroy(E).

test(engine_transform_keep_kinds, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_transform(C, keep_kinds([memory])), K),
    K == compiled([S1, S4], 4, [S2, S3]),
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_delegate
% ============================================================

test(engine_delegate_by_kinds, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_delegate(C, by_kinds), P),
    P == [partition(1, compiled([S2, S3], 4, [])),      % fact < memory
          partition(2, compiled([S1, S4], 4, []))],
    prlm_engine_destroy(E).

test(engine_delegate_by_count, []) :-
    with_engine(E),
    sample_sections(S1, S2, S3, S4),
    ctx_call(E, ctx_compile([S1, S2, S3, S4], 100), C),
    ctx_call(E, ctx_delegate(C, by_count(2)), P2),
    P2 == [partition(1, compiled([S2, S3], 4, [])),
           partition(2, compiled([S1, S4], 4, []))],
    ctx_call(E, ctx_delegate(C, by_count(3)), P3),
    P3 == [partition(1, compiled([S2, S3], 4, [])),
           partition(2, compiled([S1], 3, [])),
           partition(3, compiled([S4], 1, []))],
    prlm_engine_destroy(E).

% ============================================================
% Engine-direct: ctx_aggregate
% ============================================================

test(engine_aggregate_dedupe_highest_priority, []) :-
    with_engine(E),
    esec('s1', fact, "alpha", 2, 5, SA1),
    esec('s2', memory, "omega", 2, 5, SA2),
    esec('s1', fact, "alpha", 2, 9, SB1),
    CA = compiled([SA1, SA2], 4, []),
    CB = compiled([SB1], 2, []),
    ctx_call(E, ctx_aggregate([CA, CB], 100), M),
    % s1 keeps its priority-9 occurrence; ids then order s1 before s2
    M == compiled([SB1, SA2], 4, []),
    ctx_call(E, ctx_aggregate([CA, CB], 2), M2),
    M2 == compiled([SB1], 2, [SA2]),
    prlm_engine_destroy(E).

% ============================================================
% Host glue: notes, sources, compile
% ============================================================

test(glue_note_sources_compile, []) :-
    prlm_context_ready,
    prlm_ctx_note(glue_a, fact, "alpha beta", S1),
    S1 == section('s1', fact, "alpha beta", 3, 5, note),
    prlm_ctx_note(glue_a, conversation, "gamma delta", S2),
    S2 == section('s2', conversation, "gamma delta", 3, 4, note),
    prlm_ctx_sources(glue_a, Sections),
    Sections == [S1, S2],
    prlm_ctx_compile(glue_a, 100000, C2),
    codes_of("alpha beta", CB1),
    codes_of("gamma delta", CB2),
    C2 == compiled([section('s1', fact, CB1, 3, 5, note),
                    section('s2', conversation, CB2, 3, 4, note)],
                   6, []),
    prlm_context_destroy(glue_a),
    prlm_ctx_sources(glue_a, []),
    prlm_ctx_compile(glue_a, 100000, Empty),
    Empty == compiled([], 0, []).

test(glue_note_priority, []) :-
    prlm_ctx_note_priority(glue_b, memory, "zeta", 9, S1),
    S1 == section('s1', memory, "zeta", 2, 9, note),
    catch(prlm_ctx_note(glue_b, nonsense_kind, "x", _),
          prlm_error(type_error, Info),
          get_dict(ctx_kind, Info, nonsense_kind)),
    prlm_context_destroy(glue_b).

test(glue_tokens_host_strings, []) :-
    prlm_ctx_tokens("a b c", T1),
    T1 == 4,
    prlm_ctx_tokens("Hello World  again", T2),
    T2 == 4,                                  % double space: still 3 words
    prlm_ctx_tokens("", T3),
    T3 == 1,
    prlm_ctx_tokens(foo(bar, baz), T4),
    T4 == 4.

% ============================================================
% Host glue: prlm_ctx_op roundtrip
% ============================================================

test(glue_op_roundtrip, []) :-
    prlm_ctx_note(glue_c, fact, "alpha beta", _S1),
    prlm_ctx_note(glue_c, conversation, "gamma delta", _S2),
    prlm_ctx_note_priority(glue_c, memory, "zeta", 9, S3),
    S3 == section('s3', memory, "zeta", 2, 9, note),
    codes_of("zeta", CZ),
    codes_of("alpha beta", CA),
    codes_of("gamma delta", CG),

    prlm_ctx_op(glue_c, inspect, Info),
    Info == info(3, 8, [conversation-1, fact-1, memory-1]),

    prlm_ctx_op(glue_c, search([alpha]), M1),
    M1 == [match('s1', 1)],
    prlm_ctx_op(glue_c, search(['ALPHA']), M2),
    M2 == [match('s1', 1)],
    prlm_ctx_op(glue_c, search([nomatch]), M3),
    M3 == [],

    prlm_ctx_op(glue_c, select(min_priority(5)), Sel),
    % ops return sections in the engine's canonical form (content as
    % character codes)
    Sel == [section('s3', memory, CZ, 2, 9, note),
            section('s1', fact, CA, 3, 5, note)],

    prlm_ctx_op(glue_c, slice(['s3']), Sub),
    Sub == compiled([section('s3', memory, CZ, 2, 9, note)], 2, []),

    prlm_ctx_op(glue_c, transform(truncate_tokens(5)), T),
    T == compiled([section('s3', memory, CZ, 2, 9, note),
                   section('s1', fact, CA, 3, 5, note)],
                  5, [section('s2', conversation, CG, 3, 4, note)]),

    prlm_ctx_op(glue_c, delegate(by_kinds), P),
    P == [partition(1, compiled([section('s2', conversation, CG, 3, 4, note)], 3, [])),
          partition(2, compiled([section('s1', fact, CA, 3, 5, note)], 3, [])),
          partition(3, compiled([section('s3', memory, CZ, 2, 9, note)], 2, []))],

    prlm_context_destroy(glue_c).

test(glue_op_aggregate, []) :-
    prlm_ctx_note(glue_d, fact, "alpha beta", _S1),
    prlm_ctx_note(glue_d, conversation, "gamma delta", _S2),
    prlm_ctx_note_priority(glue_d, memory, "zeta", 9, _S3),
    codes_of("alpha beta", CA),
    Other = compiled([section('s1', fact, CA, 3, 9, other)], 3, []),
    prlm_ctx_op(glue_d, aggregate([Other], 100), Merged),
    codes_of("gamma delta", CG),
    codes_of("zeta", CZ),
    % s1 dedupes to the higher-priority (9) occurrence; order s1, s3, s2
    Merged == compiled([section('s1', fact, CA, 3, 9, other),
                        section('s3', memory, CZ, 2, 9, note),
                        section('s2', conversation, CG, 3, 4, note)],
                       8, []),
    prlm_context_destroy(glue_d).

test(glue_op_unknown_throws, []) :-
    catch(prlm_ctx_op(glue_e, frobnicate, _),
          prlm_error(type_error, Info),
          get_dict(ctx_op, Info, frobnicate)),
    prlm_context_destroy(glue_e).

test(glue_determinism_pure_ops, []) :-
    prlm_ctx_note(glue_f, fact, "alpha beta", _),
    prlm_ctx_note(glue_f, conversation, "gamma delta", _),
    prlm_ctx_note_priority(glue_f, memory, "zeta", 9, _),
    prlm_ctx_compile(glue_f, 100000, C1),
    prlm_ctx_compile(glue_f, 100000, C2),
    C1 == C2,
    prlm_ctx_op(glue_f, inspect, I1),
    prlm_ctx_op(glue_f, inspect, I2),
    I1 == I2,
    prlm_ctx_op(glue_f, search([alpha]), M1),
    prlm_ctx_op(glue_f, search([alpha]), M2),
    M1 == M2,
    prlm_context_destroy(glue_f).

test(glue_cache_recompiles_after_note, []) :-
    prlm_ctx_note(glue_g, fact, "alpha", _S1),
    prlm_ctx_op(glue_g, inspect, I1),
    I1 == info(1, 2, [fact-1]),
    prlm_ctx_note(glue_g, memory, "omega", _S2),
    % section count changed: the cached compiled context must be refreshed
    prlm_ctx_op(glue_g, inspect, I2),
    I2 == info(2, 4, [fact-1, memory-1]),
    prlm_context_destroy(glue_g).

:- end_tests(prlm_context).
