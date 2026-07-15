# cli-distribution Specification

## Purpose
REPLy SHALL provide a mechanism for users to install the `replyc` CLI client
as a bare command, with automatic launcher installation via `deps/build.jl`,
a manual symlink fallback, and an overwrite guard to prevent silent clobbering
of unrelated files at the target path.

## Requirements

### Requirement: Auto-install `replyc` command via `deps/build.jl`

REPLy SHALL provide a `deps/build.jl` that installs a `replyc` launcher script
into `<depot>/bin/replyc` (where `<depot>` = `DEPOT_PATH[1]`, the Julia
ecosystem depot-bin directory). This SHALL run automatically on
`Pkg.add`/`Pkg.develop` of REPLy via Julia's `Pkg.build` mechanism, requiring
no explicit user opt-in.

#### Scenario: Launcher installed after `Pkg.add` (URL form)
- **WHEN** a user runs `julia -e 'using Pkg; Pkg.add(url="https://github.com/sashakile/REPLy.jl")'`
- **THEN** `deps/build.jl` runs automatically
- **AND** `<depot>/bin/replyc` exists and is executable
- **AND** `replyc --help` prints usage help and exits with code 0

#### Scenario: Launcher installed after `Pkg.develop`
- **WHEN** a user runs `julia -e 'using Pkg; Pkg.develop(path="/local/path/REPLy.jl")'`
- **THEN** `deps/build.jl` runs automatically
- **AND** `<depot>/bin/replyc` exists and is executable

### Requirement: Launcher pinning via `--project` to the package directory

The `deps/build.jl` script SHALL create a private, UUID-namespaced scratch
environment (via `Scratch.jl`) that preserves the REPLy dependency snapshot at
build time for reference. The generated launcher script SHALL use
`--project=<pkg_dir>` (where `<pkg_dir>` is REPLy's project directory at build
time) so that the launcher always resolves the same REPLy version. Because
`--project` takes precedence over any `JULIA_PROJECT` set in the invoking
shell, the launcher is immune to environment drift from changes to the active
Julia project.

#### Scenario: Launcher works after global env changes
- **WHEN** a user installs REPLy and builds the launcher
- **WHEN** the user later changes their global Julia environment (adds/removes packages)
- **THEN** `replyc eval "1+1"` still resolves the original REPLy snapshot and works correctly

#### Scenario: Launcher ignores outer `JULIA_PROJECT`
- **WHEN** a user sets `JULIA_PROJECT=/some/other/project` in their shell
- **WHEN** they invoke `replyc eval "1+1"`
- **THEN** the launcher's `--project=<pkg_dir>` overrides the outer env and
  resolves REPLy from the build-time project directory

### Requirement: Overwrite guard for existing `replyc` file

The `deps/build.jl` script SHALL check whether `<depot>/bin/replyc` already
exists. If it does and does not contain a REPLy ownership marker comment, the
script SHALL refuse to overwrite the file and SHALL emit a warning instructing
the user to resolve the conflict manually. The ownership marker SHALL embed
the REPLy package UUID (`d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51`) — e.g., the
launcher's first line: `# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51`.
This prevents silent clobbering of unrelated tools or hand-installed files at
the same path while making accidental false matches effectively impossible.

#### Scenario: Existing non-REPLy file at target path
- **WHEN** `<depot>/bin/replyc` already exists and is not a REPLy-managed file
- **WHEN** a user runs `julia --project=. -e 'using Pkg; Pkg.build("REPLy")'`
- **THEN** the script does NOT overwrite the existing file
- **AND** the script prints a warning with the conflicting path and instructions

#### Scenario: Rebuild overwrites own file cleanly
- **WHEN** `<depot>/bin/replyc` already exists and contains the REPLy marker
- **WHEN** a user runs `julia --project=. -e 'using Pkg; Pkg.build("REPLy")'`
- **THEN** the script overwrites the file cleanly with the new launcher

#### Scenario: Partial build failure creates no launcher
- **WHEN** `deps/build.jl` fails after creating the scratch environment but
  before writing the launcher script
- **THEN** no launcher exists at `<depot>/bin/replyc`
- **AND** the user sees the build error directly rather than encountering a
  silent runtime failure

### Requirement: Documented manual install path

The REPLy documentation SHALL describe both the automatic install path
(via `deps/build.jl`) and a manual fallback for users who need a
project-scoped, pinned version of `replyc` that bypasses the global launcher.
The manual fallback SHALL use the existing `bin/replyc` shebang wrapper.

#### Scenario: Manual symlink documented
- **WHEN** a user reads the CLI installation documentation
- **THEN** they see both the automatic install path (via `Pkg.build`) and a
  one-liner to symlink `bin/replyc` into their `PATH`
- **AND** the documentation explains that the manual fallback bypasses the
  global launcher and resolves REPLy from whatever Julia environment is
  active at invocation time
