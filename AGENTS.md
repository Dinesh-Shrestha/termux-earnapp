# Repository Guidelines

## Project Structure & Module Organization

`earnapp-setup.sh` is the main Bash program. It handles command-line parsing, dependency planning, Termux setup, and component operations in one file. Tests live in `tests/` and source the script directly: `test_logic.bash`, `test_dispatch.bash`, and `test_components.bash`. Design specifications and implementation plans are in `docs/superpowers/{specs,plans}/`. Keep new test coverage in the suite that matches the behavior being changed.

## Build, Test, and Development Commands

There is no separate build step. Run the script in Termux or a compatible Bash environment. Useful development commands:

- `bash -n earnapp-setup.sh` checks the script for Bash syntax errors.
- `bash tests/test_logic.bash` runs logic and validation checks.
- `bash tests/test_dispatch.bash` checks command dispatch behavior.
- `bash tests/test_components.bash` checks component setup behavior.

Run tests from the repository root; suites use temporary fixtures and report pass/fail counts.

## Coding Style & Naming Conventions

Use Bash, two spaces for indentation, `snake_case` function and variable names, and uppercase names for global configuration constants (for example, `CONTAINER_NAME`). Quote variable expansions unless intentional word splitting or globbing is required. Prefer the existing helpers for logging, dry-run actions, prompts, and dependency resolution. Keep tests as executable-style `.bash` scripts with descriptive assertion messages; no formatter or linter is configured.

## Testing Guidelines

The test suites use small shell assertion helpers rather than an external framework. Add regression coverage alongside the relevant suite, including dry-run or error-path behavior when changing setup actions. Run the affected suite and, for shared CLI or dependency changes, all three suites. There is no stated coverage threshold.

## Commit & Pull Request Guidelines

Recent history follows Conventional Commit-style prefixes: `feat:`, `fix:`, `test:`, and `docs:` followed by a concise imperative summary. Keep changes focused. Pull requests should explain the user-visible behavior, list relevant tests run, link related issues when applicable, and include terminal output or screenshots only when they clarify a UI-facing change.

## Security & Configuration Tips

This script installs packages and configures services and containers in Termux. Preserve explicit dry-run behavior and avoid logging UUIDs, credentials, or other sensitive configuration. Exercise changes with test fixtures rather than applying real system modifications during development.
