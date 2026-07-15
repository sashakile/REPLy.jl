---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

## Context

The research document (`REPLY_CLI_DISTRIBUTION_RESEARCH_2026-07-15.md`) tested
three approaches for making `replyc` available as a bare command:

1. **`juliac --output-exe`** — works but produces a ~252 MB binary tied to a
   specific Julia version/arch; not worth the overhead since Julia is always
   present.
2. **`deps/build.jl`** — zero user opt-in, works automatically on
   `Pkg.add`/`Pkg.build`. Verified live.
3. **Comonicon.jl's approach** — uses per-package-UUID scratch spaces to pin
   the dependency snapshot. Same `deps/build.jl` hook, same
   `~/.julia/bin/<name>` target, plus a frozen environment.

Decision: adopt approach (2) with (3)'s scratch-space pinning and an overwrite
guard. Comonicon's key innovation — freezing dependencies at build time via
`Scratch.jl` — is implementable in ~25 lines and removes the "global env
changed underneath you" drift failure mode without adding Comonicon as a
dependency.

## Goals / Non-Goals

- Goals:
  - `replyc` is available as a bare command after `Pkg.add`/`Pkg.develop` of REPLy, with no manual steps beyond adding `~/.julia/bin` to `PATH` (a pre-existing Julia ecosystem convention).
  - The launcher is pinned to the dependency snapshot at build time, not resolved dynamically.
  - An overwrite guard prevents silent clobbering of unrelated files at the same path.

- Non-Goals:
  - Multi-tenant version support (two different REPLy versions for two repos). Both `deps/build.jl` and Comonicon's approach share this limitation — `~/.julia/bin/<name>` is a single global slot.
  - Registration in Julia's General registry (deliberately held back for stability).
  - Standalone binary compilation via `juliac`.

## Decisions

- **Decision: Use `deps/build.jl` as the install hook.** Julia's `Pkg.build`
  auto-runs this file on `Pkg.add`/`Pkg.develop`. No user opt-in needed.
- **Decision: Use `Scratch.jl` for environment pinning.** Creates a private,
  UUID-namespaced directory under `~/.julia/scratchspaces/<uuid>/env`, copies
  REPLy's `Project.toml` deps, instantiates it. The launcher script hardcodes
  `JULIA_PROJECT=<scratch_env_dir>` for reproducible resolution.
  - Alternatives considered: dynamic resolution (simpler but drifts if global
    env changes); Comonicon (adds a full dependency for a ~25-line pattern).
- **Decision: Add an overwrite guard.** If the target `~/.julia/bin/replyc`
  already exists and does not contain a REPLy marker comment, refuse to
  overwrite and emit a warning with instructions. This closes the one
  collision case that is actually preventable at the single-package level.
- **Decision: Document both install paths.** Automatic (`deps/build.jl`) for
  the common global-tool case, and manual `bin/replyc` symlink for repos
  needing a pinned, project-scoped version.

## Risks / Trade-offs

- **Scratch.jl dependency**: adds one small, stable dependency. `Scratch.jl`
  is already a transitive dep of many Julia packages (including things like
  `Preferences.jl` chains). Low risk.
- **Overwrite guard false positives**: a user who manually moved their own
  `replyc` launcher to a different path and symlinked back would hit the
  guard. Acceptable — the warning explains how to proceed.
- **Build-time cost**: `Pkg.build` instantiates the scratch environment, which
  resolves and downloads deps. This adds ~5–15 s on first build; subsequent
  builds are no-ops unless deps change.

## Open Questions

- None — all design decisions are grounded in the research document's
  verified findings.
