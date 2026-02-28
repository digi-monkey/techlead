# Distribute TechLead Skill

## 1) Set Repository Metadata

In `website/index.html`, set:

- `github-owner`: `digi-monkey`
- `github-repo`: `techlead`
- `github-branch`: `main`

## 2) Validate Distribution Assets

Run:

```bash
npm run validate:distribution
```

Required paths:

- `skills/techlead/SKILL.md`
- `skills/techlead/claude-command.md`
- `.techlead/sprint-state.json`
- `scripts/sprint-board.mjs`
- `scripts/techlead-parallel-runner.mjs` (experimental runtime helper, opt-in)

## 3) Distribute to Codex

```text
$skill-installer install https://github.com/digi-monkey/techlead/tree/main/skills/techlead
```

After installation, restart Codex and invoke:

```text
$techlead
```

## 4) Distribute to Claude Code

```bash
mkdir -p .claude/commands
curl -fsSL https://raw.githubusercontent.com/digi-monkey/techlead/main/skills/techlead/claude-command.md -o .claude/commands/techlead.md
```

Then invoke:

```text
/techlead
```
