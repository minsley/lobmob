---
status: draft
tags: [infrastructure, testing, self-improvement]
maturity: implementation
created: 2026-02-24
updated: 2026-02-25
---
# Test Framework & CI Integration

## Summary

The test suite has grown organically into a solid layered structure (unit, integration, e2e) with consistent `check()` patterns, but lacks organization infrastructure: no tier-aware runner, no CI test execution, shared helpers duplicated per-file, two dead legacy tests, and no tests for safety-critical code (hooks.py, verify.py). As the system grows toward 8+ lobster variants, these gaps compound.

This plan adds a shared test lib, pytest foundation with new unit tests for safety-critical paths, a test runner, CI lint+unit jobs, and establishes conventions for variant testing — without replacing what's working.

## Open Questions

- [x] **pytest in containers**: Dev-only. Add to `requirements-dev.txt`, install in CI with `pip install -r requirements-dev.txt`. Not in base image — lobsters don't run tests.
- [x] **lobwife integration in CI**: Will work cleanly on ubuntu-latest. The daemon only needs pip packages from `containers/lobwife/requirements.txt`. Test uses only `curl`, `python3`, `jq` — all on ubuntu-latest.
- [x] **ShellCheck scope**: Lint `tests/` and `scripts/lib/*.sh` only in Phase 6. `scripts/commands/` files are intentionally sourced (no shebang, no pipefail) — track as a follow-up pass.

## Phases

### Phase 1: Cleanup

- **Status**: pending
- Delete `tests/pool-state` and `tests/event-logging` (Droplet-era, non-functional against k8s architecture)
- Confirm no references to them in CI, scripts, or docs before deleting

### Phase 2: Shared test lib

- **Status**: pending
- Create `tests/lib.sh` with:
  - `check()`, `pass()`, `fail()` — standardized on the e2e-task version (most complete: color output, pass/fail calls check)
  - Color variables (`RED`, `GREEN`, `YELLOW`, `CYAN`, `NC`)
  - `require_env VAR [VAR...]` — assert env vars are set, print usage and exit if not
  - `require_cmd CMD [CMD...]` — assert tools are available
  - `print_summary` — print PASS/FAIL totals and exit with appropriate code
- Update all bash tests to `source "$(dirname "$0")/lib.sh"` and remove duplicated implementations
- Keep each test's existing logic unchanged — this is a refactor, not a rewrite

### Phase 3: pytest foundation + new unit tests

- **Status**: pending
- Create `tests/unit/` directory and `requirements-dev.txt` (pytest, pytest-asyncio)
- **Migrate `tests/episode-loop`** → `tests/unit/test_episode_loop.py`
  - `@pytest.mark.asyncio` for async tests, `@pytest.fixture` for common setup
  - Each of the 7 scenarios becomes its own `test_` function
- **New: `tests/unit/test_hooks.py`** — test the tool checker from `src/lobster/hooks.py`
  - Verify `BLOCKED_COMMANDS_ALL` blocks `rm -rf /`, `shutdown`, `reboot`, `mkfs`, `dd of=/dev/`
  - Verify QA/image-gen types additionally block git write ops and `gh pr create/merge`
  - Verify network domain allowlist permits `github.com`, blocks arbitrary domains
  - Verify non-Bash tools always pass
  - Parametrize across lobster types (`swe`, `qa`, `research`, `image-gen`, `system`)
  - Pure function, no deps beyond the module itself — instantiate `create_tool_checker()` and call with mock inputs
- **New: `tests/unit/test_verify.py`** — test completion checker from `src/lobster/verify.py`
  - Create temp vault dirs with task files (various frontmatter states)
  - Verify: missing `status: completed` → fails, missing `## Result` → fails, complete file → passes
  - Mock `gh` calls for PR detection (or skip PR checks via env)
- **New: `tests/unit/test_sync.py`** — test vault sync logic from `scripts/server/lobwife_sync.py`
  - Test `_db_row_to_frontmatter()` — DB row → YAML frontmatter round-trip
  - Test status → vault subdirectory mapping (queued→active/, completed→completed/, etc.)
  - Uses temp git repo, no network

### Phase 4: Test runner

- **Status**: pending
- Create `tests/run` — executable bash script, dispatches by tier:
  ```
  tests/run unit          # pytest tests/unit/ + ipc-server + lobwife-db
  tests/run integration   # lobwife-task-lifecycle (requires running daemon)
  tests/run e2e           # e2e-task (requires dev/local cluster)
  tests/run all           # unit + integration
  tests/run               # same as: unit
  tests/run variant [name]  # (future) variant-specific smoke tests
  ```
- Runs each test in sequence, captures exit code, prints per-test PASS/FAIL summary at end
- Exits non-zero if any test in the set failed
- Respects `LOBMOB_ENV` passthrough for live tests
- Does not start background services — integration/e2e tests manage their own setup
- Discovery: bash tests registered explicitly in the runner script; pytest tests discovered automatically from `tests/unit/`
- CI install step: `pip install -r requirements-dev.txt -r containers/lobwife/requirements.txt`

### Phase 5: Lobster test path safety

- **Status**: pending
- The `code-task` skill instructs lobsters to run `bash tests/*`, which globs everything in `tests/`. Tests that require k8s, secrets, or running daemons will fail inside a lobster container.
- Restructure test directories so the glob is safe:
  ```
  tests/unit/               # pytest (Python) — lobsters don't run these
  tests/ipc-server          # unit, localhost only — safe
  tests/lobwife-db          # unit, starts daemon locally — safe
  tests/lobwife-task-lifecycle  # integration — needs running daemon, NOT safe
  tests/e2e-task            # e2e — needs k8s, NOT safe
  tests/dev-reset-e2e       # e2e — destructive, NOT safe
  tests/push-task           # utility
  tests/await-task-pickup   # utility
  tests/await-task-completion  # utility
  ```
- Options (pick one during implementation):
  - **(A)** Move integration/e2e tests to `tests/integration/` and `tests/e2e/`. Update `code-task` skill to `bash tests/*` (only hits unit-safe scripts). Update `tests/run` to look in subdirs.
  - **(B)** Update `code-task` skill from `bash tests/*` to `tests/run unit`. Keeps flat structure, requires test runner to exist first.
- Either way, verify that a lobster running inside a container will not accidentally execute tests that require external infrastructure.

### Phase 6: CI — lint and unit test jobs

- **Status**: pending
- New workflow `.github/workflows/test.yml`:

  **`lint-bash`**:
  - Runs `shellcheck` on all executable files in `tests/` and `scripts/lib/*.sh`
  - Uses `.shellcheckrc` with `shell=bash` to avoid SC2148 on any sourced files
  - Excludes `scripts/commands/` (separate follow-up)
  - Fast — runs on every PR and push to develop/main

  **`test-unit`**:
  - Installs: `pip install -r requirements-dev.txt -r containers/lobwife/requirements.txt`
  - Runs `tests/run unit`
  - No k8s, no secrets, no network beyond localhost
  - Runs on every PR and push to develop/main
  - Required status check for PR merge

- Both jobs run in parallel
- Prerequisite for [CI/CD](ci-cd.md) Phase 2 — dev auto-deploy should gate on test-unit passing

### Phase 7: CI — integration test job

- **Status**: pending
- Run `tests/lobwife-task-lifecycle` against a lobwife daemon started in CI:
  - Start daemon: `LOBWIFE_STATE_DIR=$(mktemp -d) python3 scripts/server/lobwife-daemon.py &`
  - Wait for `http://127.0.0.1:8081/health`
  - Run `tests/lobwife-task-lifecycle`
  - Teardown on exit
- Triggered on: push to develop/main (not every PR — slightly slower)
- Blocked on: Phase 6 working cleanly first

### Phase 8: Variant test conventions

- **Status**: pending (activates when first variant Dockerfile ships)
- Establish the pattern for variant-specific testing:

  **Build-time (Dockerfile `RUN` steps)**:
  - Each variant Dockerfile includes tool version smoke tests: `RUN adb version`, `RUN pio --version`, etc.
  - Validates toolchain is installed and runnable before the image ships

  **Runtime (`tests/variants/<name>`)**:
  - Bash scripts following the same `check()` + `source tests/lib.sh` pattern
  - Require the variant image to be running (local k3d or built image)
  - Test that the lobster can invoke variant-specific tools inside the container
  - Example: `tests/variants/android` starts a container from `lobmob-lobster-android`, runs `adb version`, `gradle --version`, verifies env vars

  **Test runner integration**:
  - `tests/run variant` runs all variant tests
  - `tests/run variant android` runs just one
  - CI: variant tests run in the image build workflow (after build, before push), not in test.yml

- This phase is a convention doc + skeleton. Actual variant tests are written as part of each variant plan (lobster-android Phase 3, etc.)

## Decisions Log

| Date | Decision | Rationale |
|------|----------|-----------|
| 2026-02-24 | Keep bash `check()` pattern, don't migrate to BATS | Pattern is consistent and working; BATS adds dependency for minimal gain |
| 2026-02-24 | pytest for Python tests only | Bash tests don't benefit from pytest; Python tests get better failure output and parametrize |
| 2026-02-24 | E2E tests stay manual (no CI trigger) | Require live dev cluster, too expensive and slow for every PR |
| 2026-02-24 | `tests/run` as a bash script, not a Makefile | Consistent with existing bash conventions; Makefile adds no value here |
| 2026-02-25 | hooks.py, verify.py, sync tests are Phase 3, not afterthoughts | Safety-critical code (tool blocklist, completion verification) must have direct tests before variant expansion |
| 2026-02-25 | Test framework is priority #3 after local-overlay and multi-turn live validation | Lock in coverage at the most feature-complete pre-variants state, before surface area explodes |
| 2026-02-25 | Variant test convention established early (Phase 8), populated per-variant | Avoids ad-hoc patterns. Each variant plan references this convention |

## Scratch

- `lobwife-db` is the most complex unit test — it starts a real daemon process. Worth verifying it runs clean on ubuntu-latest before committing to Phase 6.
- The `check()` implementations differ slightly between files — `ipc-server` version is the simplest, `e2e-task` version is the most complete (color output, pass/fail calls check). Use e2e-task's as the reference for `tests/lib.sh`.
- `tests/push-task`, `tests/await-task-pickup`, `tests/await-task-completion` are standalone utilities, not tests. They don't use `check()`. Leave them out of the test runner — they're building blocks for `e2e-task`.
- CI secrets needed for Phases 6-7: none. `test-unit` is fully local. `lobwife-task-lifecycle` starts its own daemon.
- The `code-task` skill says `bash tests/*` — this is the lobster test execution path. Phase 5 specifically addresses keeping that glob safe as tests grow.
- `test_hooks.py` is the single highest-value new test. If hooks.py regresses and drops `rm -rf /` from the blocklist, every lobster becomes a risk. Parametrize across all 5 lobster types.
- `test_verify.py` needs to mock or skip the `gh pr list` calls — the verify function checks for PRs but that requires gh auth. Use monkeypatch to stub `subprocess.run` for gh calls, or set an env flag to skip PR checks.
- `test_sync.py` targets the pure functions in `lobwife_sync.py` — `_db_row_to_frontmatter()` and the status→subdir mapping. The actual sync cycle involves git operations; test with a temp git repo initialized via `git init`.
- `lobwife_sync.py` has `_parse_frontmatter()` too — test round-trip: `_db_row_to_frontmatter()` output should parse back cleanly.

## Related

- [CI/CD Pipeline](ci-cd.md) — Phase 6 here is a prerequisite for CI/CD Phase 2 (dev auto-deploy gates on tests)
- [Lobster Variants](lobster-variants.md) — Phase 8 here establishes the test convention that variant plans reference
- [Roadmap](../roadmap.md)
