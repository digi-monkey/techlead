# Distribute TechLead Skill

## 1) Validate Distribution Assets

Run:

```bash
npm run validate:distribution
```

Required paths:

- `skills/techlead/SKILL.md`
- `skills/techlead/claude-command.md`
- `src/cli.ts`
- `prompts/`
- `templates/.techlead/config.yaml`

## 2) Distribute to Codex

```text
$skill-installer install https://github.com/digi-monkey/techlead/tree/main/skills/techlead
```

After installation, restart Codex and invoke:

```text
$techlead
```

## 3) Distribute to Claude Code

```bash
mkdir -p .claude/commands
curl -fsSL https://raw.githubusercontent.com/digi-monkey/techlead/main/skills/techlead/claude-command.md -o .claude/commands/techlead.md
```

Then invoke:

```text
/techlead
```
