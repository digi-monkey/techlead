# Contributing

## Scope
This repository is a generic orchestration kit for autonomous agent development loops.
Keep contributions reusable across domains.

## Pull Request Checklist
- Add or update docs for behavior changes.
- Keep templates framework-agnostic.
- Keep secret handling and privacy boundaries explicit.
- Include at least one runnable example when adding new orchestration features.
- If public-facing changes are included, update `website/` and skill install links together.
- Keep GitHub Pages workflow and website deployment path valid.

## Design Rules
- Goal-first prompts: provide objective and constraints, not implementation steps.
- CLI-first execution: prefer deterministic command execution over ad-hoc manual edits.
- Closed-loop quality: implementation -> review -> acceptance -> commit.
- Human board override: human instructions always have highest priority.
- Dogfood first: this repo should follow the same techlead protocol it promotes.
