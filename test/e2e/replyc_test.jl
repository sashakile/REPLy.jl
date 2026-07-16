@testset "e2e: replyc CLI client" begin
    replyc = joinpath(pkgdir(REPLy), "bin", "replyc")
    project = Base.active_project()

    @testset "exported API works from a consumer without direct JSON3 dependency" begin
        mktempdir() do consumer
            setup = `$(Base.julia_cmd()) --project=$(consumer) -e $("using Pkg; Pkg.develop(path=$(repr(pkgdir(REPLy))))")`
            run(setenv(setup, "JULIA_LOAD_PATH" => "@:@stdlib"))
            project_toml = read(joinpath(consumer, "Project.toml"), String)
            @test occursin("REPLy", project_toml)
            @test !occursin("JSON3", project_toml)

            with_server(port=0) do handle
                code = "using REPLy; exit(REPLy.replyc(ARGS))"
                cmd = `$(Base.julia_cmd()) --project=$(consumer) -e $code -- eval --port $(handle.port) 1+1`
                output = IOBuffer()
                proc = run(pipeline(ignorestatus(setenv(cmd, "JULIA_LOAD_PATH" => "@:@stdlib")); stdout=output, stderr=devnull))
                @test proc.exitcode == 0
                @test occursin("2", String(take!(output)))
            end
        end
    end

    run_replyc(args...) = begin
        cmd = `$(Base.julia_cmd()) --project=$(project) $(replyc) $args`
        of = tempname()
        ef = tempname()
        try
            proc = run(pipeline(ignorestatus(cmd); stdout=of, stderr=ef))
            (; code=proc.exitcode, out=read(of, String), err=read(ef, String))
        finally
            rm(of; force=true)
            rm(ef; force=true)
        end
    end

    @test isfile(replyc)

    @testset "eval round-trips code with quotes, \$, and backslashes" begin
        with_server(port=0) do handle
            # Code containing every character that corrupts naive shell/nc usage.
            code = "s = \"a\\\"b\\\$c\\\\d\"; length(s)"
            r = run_replyc("eval", "--port", string(handle.port), code)
            @test r.code == 0
            # "a\"b\$c\\d" has 7 characters.
            @test occursin("7", r.out)
        end
    end

    @testset "eval prints stdout and value" begin
        with_server(port=0) do handle
            r = run_replyc("eval", "--port", string(handle.port),
                           "println(\"hi there\"); 6 * 7")
            @test r.code == 0
            @test occursin("hi there", r.out)
            @test occursin("42", r.out)
        end
    end

    @testset "eval suppresses spurious 'nothing' for println-style evals (regression: REPLy_jl-btd)" begin
        with_server(port=0) do handle
            # println returns nothing — replyc must NOT print a trailing "nothing" line
            r = run_replyc("eval", "--port", string(handle.port),
                           "println(\"just stdout\")")
            @test r.code == 0
            @test occursin("just stdout", r.out)
            @test !occursin("nothing", r.out)
        end
    end

    @testset "eval reports errors with non-zero exit" begin
        with_server(port=0) do handle
            r = run_replyc("eval", "--port", string(handle.port), "missing_name + 1")
            @test r.code == 1
        end
    end

    @testset "session new / ls / rm lifecycle" begin
        with_server(port=0) do handle
            port = string(handle.port)

            new = run_replyc("session", "new", "--port", port, "cliapp")
            @test new.code == 0
            uuid = strip(new.out)
            @test length(uuid) == 36

            ls = run_replyc("session", "ls", "--port", port)
            @test ls.code == 0
            @test occursin("cliapp", ls.out)

            # State persists in the named session across eval calls.
            run_replyc("eval", "--port", port, "--session", "cliapp", "kept = 99")
            got = run_replyc("eval", "--port", port, "--session", "cliapp", "kept")
            @test occursin("99", got.out)

            rm_ = run_replyc("session", "rm", "--port", port, "cliapp")
            @test rm_.code == 0

            ls2 = run_replyc("session", "ls", "--port", port)
            @test !occursin("cliapp", ls2.out)
        end
    end
end
