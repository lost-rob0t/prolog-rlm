#!/usr/bin/env sh
# Design-consistency gate for the SPEC/PLAN authority refinement (PR #290).
# Validates the schemas, examples, diagnostics vocabulary, gate invariants,
# lambda-RLM mapping, and implementation slices defined in
# docs/research/spec-plan-authority.md, plus the refinement KB state.
set -e
cd "$(dirname "$0")/.."
exec swipl -q -s scripts/spec_plan_authority_check.pl
