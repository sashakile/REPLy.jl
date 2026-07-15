---
tags: [pipeline-run:ticket-workflow-2026-04-20-reply-jl-43w-4]
---

## 1. Implementation

- [ ] 1.1 Add `Scratch.jl` to `[deps]` in `Project.toml`
- [ ] 1.2 Create `deps/build.jl` with:
  - [ ] 1.2.1 Scratch-space environment creation and instantiation
  - [ ] 1.2.2 Launcher script generation with `JULIA_PROJECT` pinning and REPLy ownership marker
  - [ ] 1.2.3 Overwrite guard (check for marker before clobbering)
  - [ ] 1.2.4 `chmod 0o755` on the launcher
- [ ] 1.3 Update documentation to describe both install paths (auto and manual)
- [ ] 1.4 Verify end-to-end: `Pkg.develop` on a temp env, confirm `replyc --help` works from `PATH`

## 2. Validation

- [ ] 2.1 Run `just test` (or equivalent tests) to confirm no regressions
- [ ] 2.2 Manual test: build launcher, modify global env, verify `replyc` still resolves correctly
- [ ] 2.3 Manual test: place non-REPLy file at `~/.julia/bin/replyc`, run build, confirm guard triggers warning
- [ ] 2.4 Manual test: re-run build with own launcher in place, confirm clean overwrite
