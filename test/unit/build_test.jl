@testset "build.jl creates launcher" begin
    depot_bin = joinpath(DEPOT_PATH[1], "bin")
    launcher = joinpath(depot_bin, "replyc")

    @test isfile(launcher) || begin
        # If the launcher doesn't exist yet (e.g., first test run after clean),
        # run Pkg.build to create it
        Pkg.build("REPLy")
        isfile(launcher)
    end

    @test isfile(launcher)
    @test isexecutable(launcher)

    # Verify the launcher has the UUID marker (second line, exact prefix match)
    lines = readlines(launcher)
    @test length(lines) >= 2
    @test startswith(lines[2], "# REPLy-managed; uuid: d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51")

    # Verify the launcher pins to the scratch environment, not to REPLy's own
    # install directory (see the regression testset below for why).
    content = read(launcher, String)
    @test occursin("--project", content)

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
    finally
        empty!(DEPOT_PATH)
        append!(DEPOT_PATH, old_depot_path)
    end
end
