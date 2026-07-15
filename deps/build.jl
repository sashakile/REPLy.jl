# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
# Auto-installed replyc launcher — see docs/src/howto-cli-install.md
#
# This build script runs automatically on Pkg.add/Pkg.develop via Pkg.build.
# It creates a private scratch-space environment that freezes the REPLy
# dependency snapshot at build time, then writes a replyc launcher script
# pinned to that environment.

using Scratch

# The REPLy module is not loaded during build, so use the UUID directly
reply_uuid = Base.UUID("d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")

# Step 1: Create a private, UUID-namespaced scratch environment
scratch_env = get_scratch!(reply_uuid, "env")
mkpath(scratch_env)

# Step 2: Write a synthetic Project.toml into the scratch env containing
# only REPLy's dependencies (not REPLy itself), following Comonicon's pattern.
# Use basic line parsing since TOML/Pkg stdlibs are not available in the
# build sandbox's sandboxed environment. Wrap in a function to avoid the
# soft-scope ambiguity on `in_section`.
function write_scratch_project(scratch_env)
    pkg_dir = dirname(@__DIR__)
    src_toml = read(joinpath(pkg_dir, "Project.toml"), String)

    sections_to_copy = Set(["[deps]", "[compat]", "[extras]", "[weakdeps]", "[targets]"])
    scratch_lines = String[]
    in_section = ""
    for line in split(src_toml, '\n')
        if startswith(line, '[')
            in_section = line
            if in_section in sections_to_copy
                push!(scratch_lines, line)
            end
        elseif !isempty(in_section) && in_section in sections_to_copy
            if !isempty(strip(line)) && !startswith(line, '#')
                push!(scratch_lines, line)
            end
        end
    end
    write(joinpath(scratch_env, "Project.toml"), join(scratch_lines, '\n') * '\n')
end

write_scratch_project(scratch_env)

# Step 3: Determine the depot bin directory and target launcher path
bin_dir = joinpath(DEPOT_PATH[1], "bin")
mkpath(bin_dir)
launcher_path = joinpath(bin_dir, "replyc")

# Step 4: Overwrite guard — refuse to clobber a non-REPLy file.
# If the file is owned by REPLy, write it; if it's foreign, warn and skip.
# If it doesn't exist, write it.
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
    # Step 5: Write the launcher script with JULIA_PROJECT pinned to the scratch env.
# The scratch env is instantiated lazily on first invocation (Pkg resolves deps
# automatically when Julia loads with --project=<scratch_env>).
launcher_src = """
#!/usr/bin/env bash
# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51
exec env JULIA_PROJECT="$(scratch_env)" julia --startup-file=no \\
    -e 'using REPLy; exit(REPLy.replyc(ARGS))' -- "\$@"
"""

write(launcher_path, launcher_src)
chmod(launcher_path, 0o755)

@info "Installed replyc launcher at $(launcher_path)"
@info "Make sure $(bin_dir) is on your PATH to use 'replyc' as a bare command."
@info "Scratch environment at $(scratch_env)"
end
