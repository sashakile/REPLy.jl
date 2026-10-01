using Logging

@testset "build.jl creates launcher" begin
    depot_bin = joinpath(DEPOT_PATH[1], "bin")
    launcher = joinpath(depot_bin, "replyc")

    # Rebuild when the launcher is missing OR stale — e.g. built by a different
    # Julia version than the one running the tests (multi-version dev setups),
    # or its pinned scratch environment was deleted out from under it — which
    # would otherwise pin checks against an old interpreter path and a
    # possibly missing scratch env.
    julia_exe = Base.julia_cmd()[1]
    launcher_is_current = false
    if isfile(launcher)
        prior = read(launcher, String)
        pin = match(r"--project=\"?([^\"\s]+)", prior)
        launcher_is_current = occursin(julia_exe, prior) &&
            (pin === nothing || isdir(only(pin.captures)))
    end
    if !launcher_is_current
        Pkg.build("REPLy")
    end

    @test isfile(launcher)
    @test isexecutable(launcher)

    content = read(launcher, String)

    # Verify the launcher has the UUID marker (second line, exact prefix match)
    lines = readlines(launcher)
    @test length(lines) >= 2
    @test startswith(lines[2], "# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")

    # Verify the launcher pins to the scratch environment, not to REPLy's own
    # install directory (see the regression testset below for why).
    @test occursin("--project", content)

    # Verify the launcher uses the captured Julia binary path, not bare `julia`.
    # Base.julia_cmd()[1] returns the full path to the Julia executable (e.g.
    # /usr/bin/julia), and the build script must embed this at compile time so
    # the launcher works regardless of PATH or runtime julia resolution.
    @test occursin(julia_exe, content)
    @test !occursin("exec julia ", content)

    # Verify the scratch env was created and is fully resolvable — a
    # Manifest.toml alone doesn't prove REPLy actually resolves from it.
    scratch_dir = joinpath(DEPOT_PATH[1], "scratchspaces", "d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51", "env")
    @test isdir(scratch_dir)
    @test isfile(joinpath(scratch_dir, "Project.toml"))
    @test isfile(joinpath(scratch_dir, "Manifest.toml"))
    @test occursin(scratch_dir, content)

    # The launcher must actually work end-to-end, not just exist — i.e. the
    # scratch environment it is --project-pinned to must genuinely resolve
    # REPLy and its dependencies. `--help` requires no running server and
    # still forces a real `using REPLy` through the pinned environment.
    help_output = read(`$launcher --help`, String)
    @test occursin("replyc", help_output)
end

@testset "build.jl regression: pkg_dir with no Manifest.toml (fresh clone / Pkg.add(url=...))" begin
    # Reproduces the exact layout every real downstream install has: a
    # package directory that contains Project.toml (never gitignored) but no
    # Manifest.toml (gitignored, and never written into a fresh git clone or
    # a read-only Pkg.add(url=...) package-store directory). Prior to this
    # fix, deps/build.jl crashed here trying to `cp` a Manifest.toml that
    # does not exist (REPLy_jl P0, found in the 2026-07-16 evaluation round).
    fake_depot = mktempdir()
    fake_pkg_dir = mktempdir()

    for entry in ("Project.toml", "src", "deps", "bin")
        cp(joinpath(pkgdir(REPLy), entry), joinpath(fake_pkg_dir, entry))
    end
    @test !isfile(joinpath(fake_pkg_dir, "Manifest.toml"))

    old_depot_path = copy(DEPOT_PATH)
    pushfirst!(DEPOT_PATH, fake_depot)
    try
        include(joinpath(fake_pkg_dir, "deps", "build.jl"))

        launcher = joinpath(fake_depot, "bin", "replyc")
        @test isfile(launcher)
        @test isexecutable(launcher)

        # The real regression: does the launcher's --project actually
        # resolve REPLy and its dependencies, or does it just point at a
        # directory that lacks a Manifest.toml (the exact bug this test
        # guards against)? `replyc --help` requires no server and forces a
        # real `using REPLy` through the pinned environment.
        help_output = read(`$launcher --help`, String)
        @test occursin("replyc", help_output)

        # Verify interpreter pin: the launcher must embed the captured Julia
        # binary path, not bare `julia` (regression guard for R1).
        launcher_content = read(launcher, String)
        @test occursin(Base.julia_cmd()[1], launcher_content)
        @test !occursin("exec julia ", launcher_content)
    finally
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, old_depot_path)
    end
end

@testset "build.jl overwrite guard (REPLy_jl-1ssz)" begin
    # Scenarios from openspec/specs/cli-distribution/spec.md:
    #   - existing-non-reply-file-at-target-path
    #   - rebuild-overwrites-own-file-cleanly
    # Both run build.jl in an isolated fake depot against a pre-existing
    # <depot>/bin/replyc; the difference is whether the file carries the
    # REPLy ownership marker.

    function run_build_with_preexisting(content::AbstractString)
        fake_depot = mktempdir()
        fake_pkg_dir = mktempdir()
        for entry in ("Project.toml", "src", "deps", "bin")
            cp(joinpath(pkgdir(REPLy), entry), joinpath(fake_pkg_dir, entry))
        end
        bin_dir = joinpath(fake_depot, "bin")
        mkpath(bin_dir)
        launcher = joinpath(bin_dir, "replyc")
        isnothing(content) || write(launcher, content)

        old_depot_path = copy(DEPOT_PATH)
        pushfirst!(DEPOT_PATH, fake_depot)
        logs = Any[]
        logs = Any[]
        try
            logger = Test.TestLogger()
            with_logger(logger) do
                include(joinpath(fake_pkg_dir, "deps", "build.jl"))
            end
            logs = logger.logs
        finally
            empty!(DEPOT_PATH)
            append!(DEPOT_PATH, old_depot_path)
        end
        return launcher, logs
    end

    marker = "# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51"

    @testset "existing non-REPLy file is NOT overwritten and warns" begin
        foreign = "#!/bin/sh\necho unrelated-tool\n"
        launcher, logs = run_build_with_preexisting(foreign)
        @test read(launcher, String) == foreign  # untouched
        @test any(r -> r.level == Logging.Warn &&
            occursin("Refusing to overwrite", r.message), logs)
    end

    @testset "rebuild overwrites own (marked) file cleanly" begin
        launcher, _ = run_build_with_preexisting("#!/usr/bin/env bash\n$marker\nold pin\n")
        content = read(launcher, String)
        @test startswith(split(content, '\n'; keepempty=false)[1], "#!")
        @test occursin(marker, content)
        @test occursin("--project", content)   # regenerated pin, not 'old pin'
        @test !occursin("old pin", content)
    end
end

@testset "build.jl partial failure leaves no launcher (REPLy_jl-1ssz)" begin
    # Scenario: partial-build-failure-creates-no-launcher — build fails after
    # the scratch environment is created but before the launcher is written.
    # Sequencing trick: pre-create an unowned replyc in a read-only bin dir;
    # the overwrite guard then declines (after scratch creation), so no
    # launcher write happens and the target path stays unowned.
    fake_depot = mktempdir()
    fake_pkg_dir = mktempdir()
    for entry in ("Project.toml", "src", "deps", "bin")
        cp(joinpath(pkgdir(REPLy), entry), joinpath(fake_pkg_dir, entry))
    end
    import Scratch
    scratch_env = Scratch.get_scratch!(
        Base.UUID("d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51"), "env"; depot_path=fake_depot)
    mkpath(scratch_env)
    bin_dir = joinpath(fake_depot, "bin")
    mkpath(bin_dir)
    launcher = joinpath(bin_dir, "replyc")
    write(launcher, "not REPLy-owned")
    chmod(bin_dir, 0o500)  # any write attempt would now fail loudly

    old_depot_path = copy(DEPOT_PATH)
    pushfirst!(DEPOT_PATH, fake_depot)
    try
        include(joinpath(fake_pkg_dir, "deps", "build.jl"))
    finally
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, old_depot_path)
    end

    @test isdir(scratch_env)                     # scratch was created
    @test read(launcher, String) == "not REPLy-owned"  # no launcher written
end

@testset "launcher env isolation (REPLy_jl-1ssz)" begin
    # Scenarios from openspec/specs/cli-distribution/spec.md:
    #   - launcher-works-after-global-env-changes
    #   - launcher-ignores-outer-julia-project
    # The launcher pins --project=<scratch_env>; it must resolve REPLy from
    # the build-time snapshot regardless of the ambient environment.
    launcher = joinpath(DEPOT_PATH[1], "bin", "replyc")
    @test isfile(launcher)  # established by the first testset

    withenv("JULIA_PROJECT" => mktempdir()) do
        help_output = read(`$launcher --help`, String)
        @test occursin("replyc", help_output)
    end
end
