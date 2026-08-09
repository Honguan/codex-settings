# Issue #62 project slim / performance baseline

Date: 2026-08-09

Machine: Windows, PowerShell 7, same working tree and user profile

Baseline: `origin/main` at `d9f0f55`

Candidate: `issue/62-project-slim-performance-cleanup`

## Before / after

All values are medians. Cold load and interactive exit use seven fresh `pwsh -NoProfile` processes. Global no-op uses three runs against the current global installation with Context7, ccusage package installation, Ponytail, Codex-Orchestration, Serena, and notifications explicitly skipped.

| Scenario | Before | After | Change |
|---|---:|---:|---:|
| Installer cold load | 692 ms | 632 ms | -8.7% |
| Interactive menu, immediate exit | 701 ms | 697 ms | -0.6% |
| Global Git no-op, optional integrations skipped | 5,046 ms | 4,824 ms | -4.4% |
| Functions present after cold load | 221 | 188 | -14.9% |
| PowerShell modules after cold load | 1 | 1 | unchanged |
| Current-process working set after cold load | 105.4 MB | 105.6 MB | no material change |

The no-op path still spends about three seconds updating already-managed mattpocock skills. That is preserved existing behavior and is not work performed by the three skipped integrations.

File-read, JSON-parse, child-process, and peak-memory counters are not reported because the repository has no ETW/profiler harness and adding one would exceed this cleanup's complexity budget. The lazy-load contract instead verifies that skipped integration implementation commands are absent from the session; existing integration tests verify selected paths through their mocked CLI boundaries.

## Dependency inventory

- Production eager load: core models/policy/file/state/managed-content/hooks/transactions; ccusage state and transaction recovery; installer prompts, plan, discovery, progress, hooks, target execution, verification, state, commit, context, runner; lightweight optional contracts.
- Production dynamic load: management commands by selected mode; Context7 and usage-tools scripts at their execution steps; Ponytail, Codex-Orchestration, and Serena only after explicit selection.
- Test-only load: fixture app servers and benchmark runners remain isolated under `tests/fixtures` and `benchmarks`.
- External packages/CLI: no dependency was added. Existing `codex`, `node`/`npx`, `ccusage`, `uv`, `serena`, `python`, and `winget` boundaries are unchanged.

## Cleanup decisions

### REMOVE

- `New-InstallProgress` — zero production/test/documentation callers; it only forwarded to the canonical `Start-InstallProgress`. The module contract now rejects its return.

### MERGE

- None. Discovery already captures manifest and ccusage state once and passes those snapshots to execution; merging other state helpers had no demonstrated I/O reduction.

### KEEP

- `Get-InstallationDiscovery` and `Invoke-InstallationPlan` — canonical discovery snapshot and execution boundary.
- State repository and model constructors with low static reference counts — public architecture contracts or reusable public APIs.
- Management, Git/CVS, hook, notification, usage, backup/restore/uninstall paths — behavior contracts remain covered by the full regression suite.

### LAZY LOAD

- Ponytail
- Codex-Orchestration
- Serena

Their prompts, skipped-result shapes, manifest constants, and summary adapters remain in the lightweight optional contract. Implementation, discovery, and dedicated CLI code load only after the feature is selected.
