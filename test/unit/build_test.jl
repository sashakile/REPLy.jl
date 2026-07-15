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

    # Verify the launcher invokes the project path
    content = read(launcher, String)
    @test occursin("--project", content)
    @test occursin(pkgdir(REPLy), content)

    # Verify the scratch env was created
    scratch_dir = joinpath(DEPOT_PATH[1], "scratchspaces", "d8d4d84f-5d15-4c72-a2d2-f44ddaa6ca51", "env")
    @test isdir(scratch_dir)
    @test isfile(joinpath(scratch_dir, "Project.toml"))
    @test isfile(joinpath(scratch_dir, "Manifest.toml"))
end