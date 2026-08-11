# Starintel Multi-Agent System Pack

Repository-root instructions, workflow scripts, Agent Zero support, and **136 focused skills** for major coding-agent systems.

## Core Files

- `AGENTS.md` — canonical instructions
- `CLAUDE.md`
- `CODEX.md`
- adapters for Cursor, Windsurf, Cline, Roo, Continue, Copilot, Aider, Gemini, and generic agents
- Agent Zero profile and installer
- `skills/` — 136 reusable `SKILL.md` packages
- `scripts/implement.py`
- `scripts/mark-design.py`
- `scripts/sync.py`
- `scripts/search.py`
- `scripts/save-research`

## Org Workflow

```bash
python scripts/sync.py
python scripts/implement.py roam/design/star-server/STAR-SERVER-001-example.org

python scripts/mark-design.py implemented   --summary "Added a CL-GServer round-robin router pool"   --file source/actors.lisp   --test "nix flake check: passed"

python scripts/sync.py
```

Rejected design:

```bash
python scripts/mark-design.py rejected   --reason "The design duplicates Star Router responsibilities"   --evidence "Repository architecture review"   --replacement "Use CL-GServer only for in-process routee pools"

python scripts/sync.py
```

`sync.py` preserves the canonical design, writes an implementation or rejection record into it, updates status headers, mirrors directory structure, and clears only the active working copy.

## Agent Zero

```bash
scripts/install-agent-zero.sh /a0/usr
```

See `docs/status-ledgers.md`, `docs/skill-index.md`, and `docs/agent-compatibility.md`.
# prolog-rlm
