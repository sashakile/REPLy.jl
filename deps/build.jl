# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
# Auto-installed replyc launcher — see docs/src/howto-cli-install.md
#
# This build script runs automatically on Pkg.add/Pkg.develop via Pkg.build.
# It resolves REPLy and its full dependency closure into a private,
# UUID-namespaced scratch environment, then writes a replyc launcher script
# pinned to that scratch environment.
#
# Why not pin --project directly at REPLy's own install directory (pkg_dir),
# as an earlier version of this script did? Because pkg_dir is not reliably
# a resolvable Julia environment:
#   - `Pkg.add(url=...)` populates a read-only, content-addressed directory
#     under `~/.julia/packages/` that never contains a Manifest.toml (it's
#     gitignored in the source tree, so it was never there to copy).
#   - A fresh `Pkg.develop(path=...)` writes the *resolved* Manifest.toml
#     into the consuming project, not into the dev-tracked path itself — a
#     brand-new `git clone` handed to `Pkg.develop` has no Manifest.toml
#     either.
#   - The only case where pkg_dir happens to have a Manifest.toml is when
#     someone has already run `Pkg.instantiate()`/`Pkg.resolve()` there
#     directly (e.g. a maintainer's own working checkout) — not a state any
#     downstream user reaches via the documented install commands.
#
# Instead, we `Pkg.develop` REPLy *into* our own scratch environment and
# `Pkg.instantiate` that. `Pkg.develop` only needs pkg_dir/Project.toml
# (never gitignored) to record pkg_dir as a path-tracked source; it does not
# require pkg_dir to already contain a Manifest.toml. This produces a
# genuinely resolvable, launcher-owned environment regardless of how REPLy
# itself was installed.

using Pkg
using Scratch

reply_uuid = Base.UUID("d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")
pkg_dir = dirname(@__DIR__)

# Step 1: Create (or reuse) a private, UUID-namespaced scratch environment.
scratch_env = get_scratch!(reply_uuid, "env")
mkpath(scratch_env)

# Step 2: Resolve REPLy + its full dependency closure into the scratch env.
# The do-block form of `Pkg.activate` restores the caller's active project
# on exit (including on error), so this is safe to run from inside
# `Pkg.build`'s own sandboxed process without leaking environment state.
Pkg.activate(scratch_env) do
    Pkg.develop(Pkg.PackageSpec(path=pkg_dir))
    Pkg.instantiate()
end

# Step 3: Determine the depot bin directory and target launcher path.
bin_dir = joinpath(DEPOT_PATH[1], "bin")
mkpath(bin_dir)
launcher_path = joinpath(bin_dir, "replyc")

# Step 4: Overwrite guard — refuse to clobber a non-REPLy file.
should_write = true
if isfile(launcher_path)
    # The marker lives on the second line (first is shebang); check that
    # at least the first two lines match expectations to confirm ownership.
    lines = readlines(launcher_path)
    is_reply_launcher = length(lines) >= 2 &&
        startswith(lines[2], "# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")
    if !is_reply_launcher
        @warn "Refusing to overwrite $(launcher_path) — it does not appear to be a REPLy-managed file. " *
              "If you are sure it is safe to replace, remove it manually and re-run Pkg.build(\"REPLy\")."
        should_write = false
    end
end

if should_write
    # Step 5: Write the launcher script pinned to the scratch environment.
    # The scratch environment resolves REPLy via a dev-tracked path entry
    # (pointing at pkg_dir) plus a fully instantiated Manifest.toml for its
    # transitive dependencies, so it works whether REPLy was installed via
    # `Pkg.add(url=...)`, `Pkg.develop`, or (in the future) the registry.
    launcher_src = """
#!/usr/bin/env bash
# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
exec $(Base.julia_cmd()[1]) --startup-file=no --project="$(scratch_env)" \\
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "\$@"
"""

    write(launcher_path, launcher_src)
    chmod(launcher_path, 0o755)

    @info "Installed replyc launcher at $(launcher_path)"
    @info "Make sure $(bin_dir) is on your PATH to use 'replyc' as a bare command."
    @info "Scratch environment at $(scratch_env)"
end
