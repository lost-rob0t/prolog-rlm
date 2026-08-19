---
name: tdd
description: Test-driven development. Use when the user wants to build features or fix bugs test-first, mentions "red-green-refactor", or wants integration tests.
---

# Test-Driven Development (TDD)

## Core Philosophy

**The core loop: red → green → refactor.**

Write the test first. Watch it fail for the right reason. Write the minimum code to make it pass. Then improve the design while tests stay green.

TDD is a design technique, not a coverage ritual. Tests should describe externally observable behavior through stable interfaces. Avoid locking tests to private implementation details.

## Rules

1. **Never write production code without a failing test that justifies it.**
2. **Run the failing test before implementing the fix.** A test that starts green proves nothing.
3. **Make one behavior change at a time.** Keep the feedback loop small.
4. **Prefer integration tests through public interfaces.** Unit-test deep pure logic where that gives faster, clearer feedback.
5. **Refactor only while green.** If behavior changes during refactoring, return to red-green first.
6. **Do not weaken assertions to make a test pass.** Fix the implementation or correct a genuinely wrong requirement.
7. **A bug fix requires a regression test.** Reproduce the bug before changing the code.

## Workflow

### 1. Choose the seam

Before writing the test, identify the narrow public interface through which the behavior should be observed. If the interface is awkward to test, that is design feedback. Legacy references to a `Skill` tool are runtime-specific; in `prolog-rlm`, Prolog already owns skill activation.

### 2. RED

Write the smallest test that demonstrates the next desired behavior.

Run it and verify:

- it fails;
- the failure is caused by missing/incorrect behavior, not a broken fixture;
- the failure message is useful;
- unrelated tests are not required to understand the failure.

If the test unexpectedly passes, either the behavior already exists or the test is not exercising what you think it is.

### 3. GREEN

Implement only enough production code to satisfy the failing test.

Do not pre-build speculative abstractions or unrelated functionality. Keep the change narrow so the causal link between test and implementation remains obvious.

### 4. REFACTOR

With the tests green:

- remove duplication;
- improve names;
- deepen interfaces;
- simplify control flow;
- move responsibilities to better modules;
- keep externally observable behavior unchanged.

Run the relevant suite after each meaningful refactor.

### 5. Repeat vertically

Take the next behavior slice and repeat red-green-refactor. Prefer end-to-end vertical slices over building entire internal layers before there is observable behavior.

## Testing Guidance

See `tests.md` for test shape and `mocking.md` for when test doubles are justified.

A useful test should make it obvious what contract broke. Tests that mirror private functions, assert every intermediate call, or mock the code under test usually make refactoring harder without increasing confidence.

## Completion Gate

Before considering a TDD task complete:

- every intended behavior has a test;
- every new test was observed failing before its corresponding fix;
- bug fixes include regression coverage;
- relevant focused tests pass;
- the broader deterministic suite passes when practical;
- no assertion was weakened merely to obtain green;
- refactors preserved behavior.
