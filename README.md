# Techlead CLI

AI-powered task execution engine with automated implement → review → merge pipeline.

## Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                    Techlead CLI Architecture                 │
├─────────────────────────────────────────────────────────────┤
│                                                              │
│  ┌──────────────┐    ┌──────────────┐    ┌──────────────┐  │
│  │   Provider   │    │   Provider   │    │   Provider   │  │
│  │   (codex)    │    │  (opencode)  │    │   (custom)   │  │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘  │
│         │                   │                   │          │
│         └───────────────────┼───────────────────┘          │
│                             │                              │
│                    ┌────────┴────────┐                     │
│                    │  Pool Service   │                     │
│                    │  (Orchestrator) │                     │
│                    └────────┬────────┘                     │
│                             │                              │
│         ┌───────────────────┼───────────────────┐          │
│         │                   │                   │          │
│  ┌──────▼───────┐    ┌──────▼───────┐    ┌──────▼───────┐  │
│  │  Worktree    │    │   Review     │    │    Merge     │  │
│  │   Service    │    │   Service    │    │   Service    │  │
│  └──────┬───────┘    └──────┬───────┘    └──────┬───────┘  │
│         │                   │                   │          │
│         └───────────────────┼───────────────────┘          │
│                             │                              │
│                    ┌────────┴────────┐                     │
│                    │ SQLite Storage  │                     │
│                    │  (ControlPlane) │                     │
│                    └─────────────────┘                     │
│                                                              │
└─────────────────────────────────────────────────────────────┘
```

### Workflow

1. **Claim**: Pool service claims next available task from queue
2. **Implement**: AI provider generates code changes
3. **Gate**: Run test/lint commands to validate changes
4. **Review**: Correctness and maintainability reviews
5. **Merge**: Merge approved changes to main branch

### Components

- **CLI (Zig)**: Core execution engine
- **Frontend (React)**: Web UI for monitoring
- **Storage (SQLite)**: Task and project state
- **Providers**: AI model integrations

## What This Repo Contains

- `src/main.zig` — CLI entrypoint (`init`, `init-agent`, `run`, `observe`)
- `src/app/` — Service layer (pool, scheduler, session, project)
- `src/providers/acpx_provider.zig` — Unified agent execution via [acpx](https://www.npmjs.com/package/acpx)
- `src/pool/` — Result parsing and prompt templates
- `src/storage/` — SQLite-backed stores (controlplane, tasks, sessions)
- `web/` — Real-time observe dashboard (Vite + React)
- `demo-topk/` — Minimal JS demo for manual `init-agent` testing

## Prerequisites

1. Zig 0.15+
2. [acpx](https://www.npmjs.com/package/acpx) (`npm install -g acpx`)
3. An agent CLI supported by acpx (e.g. `opencode`, `claude`, `codex`)
4. A Git repository for the target project

## CLI Commands

### `init` — Initialize a project

    zig build run -- init "your goal description"
    zig build run -- init "your goal description" --force   # overwrite existing

Creates `.techlead/techlead.json` and `.techlead/program.md` in the target directory.

### `init-agent` — Generate AI agent prompt

    zig build run -- init-agent "your goal description" --dir /path/to/project

Detects tech stack, generates a comprehensive prompt, and copies it to clipboard.

### `run` — Execute task pipeline

Two modes:

    zig build run -- run --mode session    # single session iteration
    zig build run -- run --mode project    # project pool: claim → implement → review → merge

**Project mode** is the primary workflow:
1. Claims a queued task from the controlplane DB
2. Runs the agent (via acpx) with the implement prompt
3. Runs gate commands (test, lint) if configured
4. Runs two review passes (correctness + maintainability)
5. Merges to main if approved, or re-queues for retry

### `observe` — Real-time dashboard

    zig build run -- observe start --host 127.0.0.1 --port 7810

## Configuration

`.techlead/techlead.json`:

```json
{
  "provider": "opencode",
  "main_branch": "main",
  "pool_max_retries": 3,
  "iterations": 1
}
```

Provider can be any agent supported by acpx: `opencode`, `claude`, `codex`.

## Testing

### Unit tests

    zig build test --summary all

### Integration test (requires acpx + agent CLI + API key)

    bash scripts/integ-test-opencode.sh

Creates a temp repo, injects a task, runs the full pipeline, and verifies 12 checks.

### Smoke test (convenience wrapper)

    bash scripts/smoke-cli.sh

## Linux Service Deployment (Observe)

Use the deployment script to install `observe` as a `systemd` service and inject your production external URL via environment variable.

Example (production):

    sudo TECHLEAD_EXTERNAL_URL="https://techlead.pingkey.xyz" \
      ./scripts/deploy-observe-service.sh \
      --target-dir /home/retric/techlead \
      --host 0.0.0.0 \
      --port 7810

What it does:
- Builds latest binary (`zig build`)
- Installs binary to `/usr/local/bin/techlead`
- Writes env file `/etc/default/techlead-observe` (includes `TECHLEAD_EXTERNAL_URL`)
- Writes unit file `/etc/systemd/system/techlead-observe.service`
- Runs `systemctl daemon-reload && systemctl enable --now techlead-observe`

After deployment, `observe` startup QR/share links will use `TECHLEAD_EXTERNAL_URL`.
