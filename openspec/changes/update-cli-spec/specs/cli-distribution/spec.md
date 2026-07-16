## MODIFIED Requirements

### Requirement: Launcher pinning via scratch environment

The `deps/build.jl` script SHALL create a private, UUID-namespaced scratch environment (via `Scratch.jl`) that preserves the REPLy dependency snapshot at build time. The generated launcher script SHALL resolve the REPLy package from this scratch environment, not from a `--project` flag. Because the scratch environment is immutable after build, the launcher is immune to environment drift from changes to the active Julia project.

#### Scenario: Launcher works after global env changes
- **WHEN** a user installs REPLy and builds the launcher
- **WHEN** the user later changes their global Julia environment (adds/removes packages)
- **THEN** `replyc eval "1+1"` still resolves the original REPLy snapshot from the scratch environment and works correctly

#### Scenario: Launcher ignores outer `JULIA_PROJECT`
- **WHEN** a user sets `JULIA_PROJECT=/some/other/project` in their shell
- **WHEN** they invoke `replyc eval "1+1"`
- **THEN** the launcher's scratch-env resolution overrides the outer env and resolves REPLy from the build-time snapshot
