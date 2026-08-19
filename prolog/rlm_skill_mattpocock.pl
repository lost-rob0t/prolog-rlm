:- module(rlm_skill_mattpocock,
          [ mattpocock_skill_rules/1,
            rlm_skill_mattpocock_ready/0
          ]).

/** <module> Trusted compiler overlay for the pinned Matt Pocock skill corpus

The vendored Markdown is kept byte-for-byte upstream. Runtime-specific skill
calls inside those documents are inert in prolog-rlm, so relationships that are
semantically part of wrapper skills are represented here as trusted compiler
rules instead of rewriting third-party content or exposing a model-side router.
*/

rlm_skill_mattpocock_ready :-
    mattpocock_skill_rules(Rules),
    is_list(Rules).

mattpocock_skill_rules([
    requires('grill-me', grilling),
    requires('grill-with-docs', grilling),
    requires('grill-with-docs', 'domain-modeling'),
    alias(tdd, "test first"),
    alias(tdd, "red green refactor"),
    alias('diagnosing-bugs', "root cause"),
    alias('diagnosing-bugs', "debug this"),
    alias('code-review', "review this pr"),
    alias('codebase-design', "deep module"),
    alias('domain-modeling', "domain model")
]).
