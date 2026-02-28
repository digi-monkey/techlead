# techlead skill

可分发的 Agent Skill，用来把 TechLead 工程闭环安装到任意代码库。

## 给 Codex

```text
$skill-installer install https://github.com/digi-monkey/techlead/tree/main/skills/techlead
```

安装后重启 Codex，然后可用 `$techlead` 显式调用。

## 给 Claude Code

```bash
mkdir -p .claude/commands
curl -fsSL https://raw.githubusercontent.com/digi-monkey/techlead/main/skills/techlead/claude-command.md -o .claude/commands/techlead.md
```

之后可直接输入 `/techlead`。
