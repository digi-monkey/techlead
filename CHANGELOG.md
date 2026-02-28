# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.0.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Changed
- Migrated from npm to pnpm for package management
- Added `packageManager` field to package.json
- Updated all scripts from `npm run` to `pnpm run`
- Added `.npmrc` with strict dependency settings

### Added
- Added `AI-CONTEXT.md` for AI quick reference
- Added concise protocol version (`docs/operations/va-auto-pilot-protocol-concise.md`)
- Enhanced `.gitignore` with editor and package manager exclusions

### Documentation
- Added link to concise protocol in main protocol document
- Updated quality gate examples to use pnpm

## [0.1.0] - 2024-XX-XX

### Added
- Initial release of VA Auto-Pilot
- CLI scaffold for any repository
- Machine-readable sprint state (`.va-auto-pilot/sprint-state.json`)
- Generated sprint board (`docs/todo/sprint.md`)
- Human override board (`docs/todo/human-board.md`)
- Append-only run memory (`docs/todo/run-journal.md`)
- Protocol documents and start prompt
- Acceptance flow runner (`scripts/test-runner.ts`)
- Website with bilingual support
- Skill distribution for Codex and Claude Code
