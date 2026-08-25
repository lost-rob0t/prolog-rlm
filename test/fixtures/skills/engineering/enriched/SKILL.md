---
name: enriched
description: Review a pull request with structured routing metadata.
metadata:
  prolog-rlm: |-
    {
      "schema": 1,
      "category": "review",
      "aliases": ["pr review"],
      "triggers": [
        {"kind": "phrase", "value": "review pull request", "weight": 80}
      ],
      "requires": [{"kind": "tool", "name": "git_diff"}],
      "suggests": [{"kind": "skill", "name": "tdd"}],
      "conflicts": [],
      "supersedes": [],
      "requires_capability": null,
      "priority": 200,
      "activation": {"automatic": false}
    }
---
# Enriched

ENRICHED_SKILL_MARKER
