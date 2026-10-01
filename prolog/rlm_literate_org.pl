:- module(rlm_literate_org,
          [ rlm_literate_org_ready/0,
            org_source_blocks/2,
            org_tangle_render/2,
            org_tangle_file/3,
            org_tangle_check/3
          ]).

/** <module> Canonical Org source reader and tangler

This module reads the deliberately small Org source subset used for
Prolog-RLM's canonical literate source. Human-readable Org files own the code.
Generated language files are build artifacts.

Only explicit `:tangle` targets generate files. Targets must stay below the
requested output root. The tangler never evaluates Org Babel, expands arbitrary
noweb references, executes code, or interprets model-authored text.
*/

:- use_module(library(filesex)).
:- use_module(library(lists)).
:- use_module(library(readutil)).

rlm_literate_org_ready.

org_source_blocks(Source0, Outcome) :-
    catch(( text_string(Source0, Source),
            split_string(Source, "\n", "", Lines),
            parse_org_lines(Lines, 1, Blocks),
            Outcome = ok(Blocks)
          ),
          Exception,
          literate_exception(parse, Exception, Outcome)).

org_tangle_render(Source, Outcome) :-
    org_source_blocks(Source, BlocksOutcome),
    render_after_parse(BlocksOutcome, Outcome).

render_after_parse(error(Error), error(Error)) :- !.
render_after_parse(ok(Blocks), Outcome) :-
    catch(( include(block_tangles, Blocks, Tangled),
            maplist(validate_block_target, Tangled),
            block_targets(Tangled, Targets),
            maplist(render_target(Tangled), Targets, Outputs),
            Outcome = ok(Outputs)
          ),
          Exception,
          literate_exception(render, Exception, Outcome)).

org_tangle_file(OrgPath, Root, Outcome) :-
    catch(( read_file_to_string(OrgPath, Source, [encoding(utf8)]),
            org_tangle_render(Source, RenderOutcome),
            require_rendered(RenderOutcome, Outputs),
            maplist(write_output(Root), Outputs),
            Outcome = ok(org_tangle_result{source:OrgPath,
                                           root:Root,
                                           outputs:Outputs})
          ),
          Exception,
          literate_exception(tangle, Exception, Outcome)).

org_tangle_check(OrgPath, Root, Outcome) :-
    catch(( read_file_to_string(OrgPath, Source, [encoding(utf8)]),
            org_tangle_render(Source, RenderOutcome),
            require_rendered(RenderOutcome, Outputs),
            maplist(check_output(Root), Outputs, Checks),
            (   forall(member(Check, Checks), Check.status == current)
            ->  Status = current
            ;   Status = stale
            ),
            Outcome = ok(org_tangle_check{source:OrgPath,
                                          root:Root,
                                          status:Status,
                                          checks:Checks})
          ),
          Exception,
          literate_exception(check, Exception, Outcome)).

parse_org_lines([], _, []).
parse_org_lines([Line|Lines], Number, Blocks) :-
    (   begin_src(Line, Language, Target)
    ->  Next is Number + 1,
        collect_src_block(Lines,
                          Next,
                          Number,
                          Language,
                          Target,
                          BodyLines,
                          EndLine,
                          Rest),
        body_text(BodyLines, Body),
        Blocks = [org_source_block{language:Language,
                                   target:Target,
                                   begin_line:Number,
                                   end_line:EndLine,
                                   body:Body}|Tail],
        Resume is EndLine + 1,
        parse_org_lines(Rest, Resume, Tail)
    ;   end_src(Line)
    ->  throw(literate_fault(unmatched_end_src(Number)))
    ;   Next is Number + 1,
        parse_org_lines(Lines, Next, Blocks)
    ).

collect_src_block([], _, Begin, _, _, _, _, _) :-
    throw(literate_fault(unterminated_src_block(Begin))).
collect_src_block([Line|Lines],
                  Number,
                  _,
                  _,
                  _,
                  [],
                  Number,
                  Lines) :-
    end_src(Line),
    !.
collect_src_block([Line|Lines],
                  Number,
                  Begin,
                  Language,
                  Target,
                  [Line|Body],
                  EndLine,
                  Rest) :-
    Next is Number + 1,
    collect_src_block(Lines,
                      Next,
                      Begin,
                      Language,
                      Target,
                      Body,
                      EndLine,
                      Rest).

begin_src(Line, Language, Target) :-
    split_string(Line, " \t", " \t", Tokens),
    Tokens = [Marker, Language0|Headers],
    string_lower(Marker, LowerMarker),
    LowerMarker == "#+begin_src",
    Language0 \== "",
    string_lower(Language0, Language),
    tangle_header(Headers, Target).

end_src(Line) :-
    normalize_space(string(Normalized), Line),
    string_lower(Normalized, Lower),
    Lower == "#+end_src".

tangle_header(Headers, Target) :-
    tangle_header_(Headers, none, Target).

tangle_header_([], Target, Target).
tangle_header_([Key, Value|Rest], _, Target) :-
    string_lower(Key, Lower),
    Lower == ":tangle",
    !,
    (   Value == "no"
    ->  Target0 = no
    ;   Target0 = Value
    ),
    tangle_header_(Rest, Target0, Target).
tangle_header_([_|Rest], Current, Target) :-
    tangle_header_(Rest, Current, Target).

body_text([], "").
body_text(Lines, Body) :-
    atomic_list_concat(Lines, '\n', Atom),
    atom_string(Atom, Text),
    string_concat(Text, "\n", Body).

block_tangles(Block) :-
    Block.target \== none,
    Block.target \== no.

validate_block_target(Block) :-
    safe_relative_target(Block.target).

safe_relative_target(Target) :-
    string(Target),
    Target \== "",
    \+ sub_string(Target, _, _, _, "\\"),
    atom_string(Path, Target),
    \+ is_absolute_file_name(Path),
    atomic_list_concat(Segments, '/', Path),
    \+ memberchk('..', Segments),
    \+ memberchk('', Segments),
    !.
safe_relative_target(Target) :-
    throw(literate_fault(unsafe_tangle_target(Target))).

block_targets(Blocks, Targets) :-
    findall(Target,
            ( member(Block, Blocks),
              Target = Block.target ),
            Targets0),
    list_to_set(Targets0, Targets).

render_target(Blocks, Target, Output) :-
    findall(Body,
            ( member(Block, Blocks),
              Block.target == Target,
              Body = Block.body ),
            Bodies),
    atomics_to_string(Bodies, "", Content),
    findall(Language,
            ( member(Block, Blocks),
              Block.target == Target,
              Language = Block.language ),
            Languages0),
    sort(Languages0, Languages),
    length(Bodies, Count),
    Output = org_tangle_output{target:Target,
                               languages:Languages,
                               blocks:Count,
                               content:Content}.

write_output(Root0, Output) :-
    root_atom(Root0, Root),
    target_path(Root, Output.target, Path),
    file_directory_name(Path, Directory),
    make_directory_path(Directory),
    setup_call_cleanup(open(Path, write, Stream, [encoding(utf8)]),
                       format(Stream, '~s', [Output.content]),
                       close(Stream)).

check_output(Root0, Output, Check) :-
    root_atom(Root0, Root),
    target_path(Root, Output.target, Path),
    (   exists_file(Path)
    ->  read_file_to_string(Path, Actual, [encoding(utf8)]),
        (   Actual == Output.content
        ->  Status = current
        ;   Status = differs
        )
    ;   Status = missing
    ),
    Check = org_tangle_target_check{target:Output.target,
                                    path:Path,
                                    status:Status}.

target_path(Root, Target, Path) :-
    safe_relative_target(Target),
    atom_string(TargetAtom, Target),
    directory_file_path(Root, TargetAtom, Path).

root_atom(Root, Root) :- atom(Root), !.
root_atom(Root, Atom) :- string(Root), !, atom_string(Atom, Root).
root_atom(Root, _) :- throw(literate_fault(invalid_root(Root))).

require_rendered(ok(Outputs), Outputs) :- !.
require_rendered(error(Error), _) :- throw(literate_fault(render_failed(Error))).

text_string(Value, Value) :- string(Value), !.
text_string(Value, Text) :- atom(Value), !, atom_string(Value, Text).
text_string(Value, _) :- throw(literate_fault(invalid_source(Value))).

literate_exception(Phase, literate_fault(Detail), error(Error)) :-
    !,
    Error = literate_org_error{phase:Phase,
                               kind:invalid_literate_source,
                               detail:Detail,
                               message:"canonical Org source was rejected"}.
literate_exception(Phase, error(Type, Context), error(Error)) :-
    !,
    Error = literate_org_error{phase:Phase,
                               kind:runtime_error,
                               detail:Type,
                               context:Context,
                               message:"Org source processing failed"}.
literate_exception(Phase, Exception, error(Error)) :-
    term_string(Exception, Safe, [quoted(true), numbervars(true)]),
    Error = literate_org_error{phase:Phase,
                               kind:unexpected_error,
                               exception:Safe,
                               message:"Org source processing failed"}.
