## 1. Implementation

- [ ] 1.1 Add `Scratch.jl` to `[deps]` and `[compat]` (with `Scratch = "1"`) in `Project.toml`
- [ ] 1.2 Create `deps/build.jl` with scratch-space env pinning, launcher generation, overwrite guard
    - [ ] Scratch-space environment creation and instantiation (create + `Pkg.instantiate`)
    - [ ] Launcher script generation with `exec env JULIA_PROJECT=<scratch>` pinning and UUID-based ownership marker
    - [ ] Overwrite guard (check for marker before clobbering; refuse if absent)
    - [ ] `chmod 0o755` on the launcher after writing
    - [ ] Guard: write launcher *last* — if scratch env instantiation fails, no launcher is written
- [ ] 1.3 Add documentation page `docs/src/howto-cli-install.md` covering both install paths (auto and manual), and cross-reference from `docs/howto-dev-tool.md`
- [ ] 1.4 Verify build.jl is discovered by Pkg: `julia --project=. -e 'using Pkg; Pkg.build("REPLy")'` exits 0
- [ ] 1.5 Verify end-to-end: `Pkg.develop` on a temp env (with `<depot>/bin` on `PATH`), confirm `replyc --help` works

## 2. Validation

- [ ] 2.1 Run `just test` (or equivalent tests) to confirm no regressions
- [ ] 2.2 Manual test: build launcher, modify global env, verify `replyc` still resolves correctly
- [ ] 2.3 Manual test: place non-REPLy file at `~/.julia/bin/replyc`, run build, confirm guard triggers warning
- [ ] 2.4 Manual test: re-run build with own launcher in place, confirm clean overwrite
