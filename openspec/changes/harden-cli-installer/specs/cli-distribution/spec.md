## MODIFIED Requirements

### Requirement: Auto-install `replyc` command via `deps/build.jl`

REPLy SHALL provide a `deps/build.jl` that installs a `replyc` launcher script
into `<depot>/bin/replyc` (where `<depot>` = `DEPOT_PATH[1]`, the Julia
ecosystem depot-bin directory). This SHALL run automatically on
`Pkg.add`/`Pkg.develop` of REPLy via Julia's `Pkg.build` mechanism, requiring
no explicit user opt-in.

The launcher SHALL capture `Base.julia_cmd()[1]` at build time (not hardcode
bare `julia`) to pin the interpreter version. On Windows, the launcher SHALL
be a `.bat`/`.cmd` wrapper.

The build script SHALL include a self-verification step that confirms the
launcher can load the REPLy package without error.

#### Scenario: Launcher installed after `Pkg.add` (URL form)
- **WHEN** a user runs `julia -e 'using Pkg; Pkg.add(url="https://github.com/sashakile/REPLy.jl")'`
- **THEN** `deps/build.jl` runs automatically
- **AND** `<depot>/bin/replyc` exists and is executable
- **AND** `replyc --help` prints usage help and exits with code 0

#### Scenario: Launcher uses build-time interpreter
- **WHEN** the launcher is invoked
- **THEN** it calls the same Julia version that was used during `Pkg.build`

#### Scenario: Windows launcher is .bat/.cmd
- **WHEN** the build runs on Windows
- **THEN** `<depot>/bin/replyc.cmd` exists and is runnable from cmd.exe

#### Scenario: Build fails if verification fails
- **WHEN** the launcher cannot load REPLy during build self-verification
- **THEN** `deps/build.jl` exits with a non-zero status and a descriptive error
