# Contributing to Techlead CLI

Thank you for your interest in contributing to Techlead CLI. This document provides the information you need to get started with development.

## Development Setup

### Prerequisites

- **Zig 0.15+**: The CLI is written in Zig. Install from [ziglang.org](https://ziglang.org/download/) or use a version manager.
- **Node.js 18+**: Required for the frontend dashboard.
- **SQLite 3**: Runtime dependency for data storage.
- **acpx**: The unified agent execution bridge (`npm install -g acpx`).
- **Git**: Required for repository operations.

### Platform Support

We actively support:
- macOS (latest)
- Ubuntu Linux (latest LTS)

Windows support is community-maintained.

### Building

```bash
# Clone the repository
git clone https://github.com/your-org/techlead.git
cd techlead

# Build the CLI
zig build

# Build and install to zig-out/bin/
zig build install

# Build frontend (optional, for observe dashboard)
cd web
pnpm install
pnpm build
cd ../..
```

### Development Workflow

```bash
# Run in development mode with arguments
zig build run -- init "Create a CLI tool"

# Or run the built binary directly
./zig-out/bin/techlead init "Create a CLI tool"
```

## Testing

### Zig Tests

```bash
# Run all tests (unit + characterization)
zig build test --summary all

# Run only unit tests
zig build test --summary all 2>&1 | grep -E "(PASS|FAIL|test)"

# Run characterization tests (behavior baseline)
zig build characterization

# Run specific test file
zig build test -- --test-filter "config"
```

### Frontend Tests

```bash
cd web

# Run tests in watch mode
pnpm test

# Run tests once
pnpm test --run

# Run with coverage
pnpm test --coverage
```

### Integration Tests

Integration tests require a configured agent CLI (opencode, claude, or codex) and API keys:

```bash
# Full integration test (requires acpx + agent CLI + API key)
bash scripts/integ-test-opencode.sh

# Quick smoke test
bash scripts/smoke-cli.sh
```

### Manual Testing

The `demo-topk/` directory contains a minimal JavaScript project for manual `init-agent` testing:

```bash
cd demo-topk
../zig-out/bin/techlead init-agent "Add a feature"
```

## Code Style

### Zig Conventions

We follow the conventions documented in [docs/zig-style-guide.md](docs/zig-style-guide.md). Key points:

- **Naming**: PascalCase for types, camelCase for functions, SCREAMING_SNAKE_CASE for constants
- **Error handling**: Use `try` for propagation, define domain-specific errors, use `errdefer` for cleanup
- **Memory management**: Every dynamically allocated struct needs a `deinit` method, use `defer` immediately after allocation
- **Concurrency**: Use `std.Thread.Mutex` for shared state, minimize critical sections

### Frontend Conventions

The observe-ui follows standard React/TypeScript patterns:

- Functional components with hooks
- Custom hooks in `src/hooks/`
- API clients in `src/lib/`
- Components in `src/components/`
- Views (pages) in `src/views/`

### Formatting

```bash
# Format Zig code (if using zig fmt)
zig fmt src/

# Format and lint frontend
cd web
pnpm lint
pnpm format
```

## Project Structure

```
techlead/
├── src/                      # CLI source code
│   ├── main.zig             # Entry point
│   ├── app/                 # Service layer
│   │   ├── pool_service.zig
│   │   ├── scheduler_service.zig
│   │   ├── session_service.zig
│   │   └── ...
│   ├── storage/             # SQLite stores
│   ├── providers/           # Agent providers
│   ├── pool/                # Result parsing, prompts
│   └── core/                # Domain models
├── tests/                   # Test suites
│   ├── unit/               # Unit tests
│   └── characterization/   # Behavior baselines
├── web/         # Frontend dashboard
│   ├── src/
│   └── package.json
├── docs/                   # Documentation
├── scripts/                # Helper scripts
└── build.zig              # Build configuration
```

## Pull Request Process

1. **Fork and branch**: Create a feature branch from `master` (`git checkout -b feature/my-feature`)

2. **Make changes**: Follow the code style guide and add tests for new functionality

3. **Test locally**: Ensure all tests pass:
   ```bash
   zig build test --summary all
   ```

4. **Commit**: Use conventional commits format (see below)

5. **Push and open PR**: Include a clear description of:
   - What changed
   - Why it changed
   - How to test it
   - Any breaking changes

6. **Review**: Address feedback promptly. PRs need approval before merging.

## Architecture Overview

### CLI (Zig)

The core is an AI-powered task execution engine:

- **Commands**: `init`, `init-agent`, `run`, `observe`
- **Pipeline**: Claim → Implement → Review → Merge
- **Storage**: SQLite-backed stores for tasks, sessions, and control plane state
- **Providers**: Unified agent execution via acpx

Key components:
- `TaskStore`: Manages task queue and state transitions
- `SchedulerService`: Orchestrates the implement/review/merge cycle
- `SessionService`: Manages interactive sessions

### Frontend (React/TypeScript)

Real-time dashboard for monitoring:

- **Tech stack**: Vite + React + TypeScript
- **Features**: Live task pool, session viewer, project management
- **API**: REST + Server-Sent Events for real-time updates

## Commit Messages

Use conventional commits for clear history and automated changelog generation:

```
<type>(<scope>): <description>

[optional body]

[optional footer]
```

Types:
- `feat`: New feature
- `fix`: Bug fix
- `docs`: Documentation only changes
- `test`: Adding or correcting tests
- `refactor`: Code change that neither fixes a bug nor adds a feature
- `perf`: Performance improvement
- `chore`: Build process or auxiliary tool changes

Scopes (common):
- `cli`: Core CLI functionality
- `observe`: Dashboard/frontend
- `storage`: Database layer
- `pool`: Task pool management
- `scheduler`: Pipeline orchestration

Examples:
```
feat(pool): add priority-based task scheduling

fix(storage): handle null lease_owner in claimNext

docs: update README with new observe commands

test(scheduler): add unit tests for retry logic
```

## Release Process

1. Version bumps follow semantic versioning
2. The `zig build` produces the binary at `zig-out/bin/techlead`
3. CI runs on Ubuntu and macOS for every PR
4. Docker images are built automatically on release tags

## Getting Help

- Open an issue for bugs or feature requests
- Check existing issues before creating new ones
- For security issues, see [docs/security/](docs/security/)

## License

By contributing, you agree that your contributions will be licensed under the same license as the project.
