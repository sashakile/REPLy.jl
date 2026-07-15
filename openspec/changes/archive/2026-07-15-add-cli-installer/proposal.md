# Change: Auto-install `replyc` CLI command via `deps/build.jl`

## Why

`replyc` is REPLy's bundled minimal CLI client. Currently, users must either
manually invoke `julia -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- ...` or
manually symlink `bin/replyc` onto their `PATH`. Neither is documented as an
install path, and there is no automatic mechanism. Research (see
`REPLY_CLI_DISTRIBUTION_RESEARCH_2026-07-15.md`) confirmed that:

- Julia + REPLy are always assumed present (`replyc` is never handed to a
  non-Julia user), so standalone binary compilation via `juliac` is not worth
  the artifact-management overhead.
- `deps/build.jl` runs automatically on `Pkg.add`/`Pkg.build` with zero user
  opt-in, making it the right hook to install a launcher script.
- The existing `bin/replyc` shebang wrapper already works as a bare command
  when REPLy is in the global environment and `bin/` is on `PATH`.

## What Changes

- Add `deps/build.jl` that installs a `replyc` launcher script to
  `<depot>/bin/replyc` (where `<depot>` = `DEPOT_PATH[1]`, the Julia
  ecosystem's standard depot-bin directory).
- Add an **overwrite guard**: refuse to clobber a file at the target path
  that doesn't contain a REPLy ownership marker; emit a warning instead.
- Add a **scratch-space environment pin** (via `Scratch.jl`) to freeze the
  dependency snapshot at build time, preventing silent behavior drift if the
  global environment changes later.
- Add a new documentation page `docs/src/howto-cli-install.md` covering
  both the automatic install path and the manual fallback (`bin/replyc`
  symlink) for per-repo pinned versions.
- Cross-reference the new CLI install page from
  `docs/howto-dev-tool.md` (where users learn to set up REPLy as a dev tool).
- No changes to `replyc.jl` source code or the protocol.

## Impact

- Affected specs: **new capability** `cli-distribution`
- **Cross-reference map** in `openspec/project.md` to be updated to include
  the new capability and its relationship to `transport`, `core-operations`,
  `session-management`, and `error-handling`.
- Affected code:
  - `deps/build.jl` (new file)
  - `docs/` (add CLI install section)
- Dependencies: `Scratch.jl` (already small, ubiquitous Julia package)
- No breaking changes to any existing capability
