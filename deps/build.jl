# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
# Auto-installed replyc launcher — see docs/src/howto-cli-install.md
#
# This build script runs automatically on Pkg.add/Pkg.develop via Pkg.build.
# It creates a private scratch-space environment that freezes the REPLy
# dependency snapshot at build time, then writes a replyc launcher script
# that resolves REPLy from the project at build time.

using Scratch

# The REPLy module is not loaded during build, so use the UUID directly
reply_uuid = Base.UUID("d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")

# Step 1: Create a private, UUID-namespaced scratch environment
scratch_env = get_scratch!(reply_uuid, "env")
mkpath(scratch_env)

# Step 2: Copy the full Project.toml and Manifest.toml into the scratch env
# to freeze the dependency snapshot at build time.
pkg_dir = dirname(@__DIR__)
cp(joinpath(pkg_dir, "Manifest.toml"), joinpath(scratch_env, "Manifest.toml"); force=true)
cp(joinpath(pkg_dir, "Project.toml"), joinpath(scratch_env, "Project.toml"); force=true)

# Step 3: Determine the depot bin directory and target launcher path
bin_dir = joinpath(DEPOT_PATH[1], "bin")
mkpath(bin_dir)
launcher_path = joinpath(bin_dir, "replyc")

# Step 4: Overwrite guard — refuse to clobber a non-REPLy file
should_write = true
if isfile(launcher_path)
    first_line = readline(launcher_path)
    if !occursin("uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51", first_line)
        @warn "Refusing to overwrite $(launcher_path) — it does not appear to be a REPLy-managed file. " *
              "If you are sure it is safe to replace, remove it manually and re-run Pkg.build(\"REPLy\")."
        should_write = false
    end
end

if should_write
    # Step 5: Write the launcher script. REPLy is not registered, so we pin
    # to the project directory directly. The scratch env preserves the
    # dependency snapshot for reference.
    launcher_src = """
#!/usr/bin/env bash
# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
exec julia --startup-file=no --project="$(pkg_dir)" \\
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "\$@"
"""

    write(launcher_path, launcher_src)
    chmod(launcher_path, 0o755)

    @info "Installed replyc launcher at $(launcher_path)"
    @info "Make sure $(bin_dir) is on your PATH to use 'replyc' as a bare command."
    @info "Scratch environment at $(scratch_env)"
end