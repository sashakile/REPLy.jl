@testset "load-file middleware" begin
    function make_ctx()
        manager = REPLy.SessionManager()
        REPLy.RequestContext(manager, Dict{String, Any}[], nothing)
    end

    @testset "loads and evaluates a file, returning value and ns" begin
        ctx = make_ctx()
        file = tempname() * ".jl"
        try
            write(file, "x = 42\nx * 2")
            stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
            msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf1", "file" => file), ctx)

            assert_conformance(msgs, "lf1")
            value_msg = only(filter(m -> haskey(m, "value"), msgs))
            @test value_msg["value"] == "84"
            @test value_msg["ns"] isa AbstractString
        finally
            rm(file; force=true)
        end
    end

    @testset "file that prints stdout emits out messages" begin
        ctx = make_ctx()
        file = tempname() * ".jl"
        try
            write(file, "println(\"hello from file\")")
            stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
            msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf2", "file" => file), ctx)

            assert_conformance(msgs, "lf2")
            out_msgs = filter(m -> haskey(m, "out"), msgs)
            @test !isempty(out_msgs)
            @test occursin("hello from file", join(m["out"] for m in out_msgs))
        finally
            rm(file; force=true)
        end
    end

    @testset "unreadable file returns error response" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf3", "file" => "/nonexistent/path/file.jl"), ctx)

        @test length(msgs) == 1
        @test "error" in msgs[1]["status"]
        @test occursin("Failed to read file", msgs[1]["err"])
    end

    @testset "path blocked by allowlist returns path-not-allowed error" begin
        ctx = make_ctx()
        file = tempname() * ".jl"
        try
            write(file, "1 + 1")
            allowlist = _ -> false  # reject everything
            mw = REPLy.LoadFileMiddleware(; load_file_allowlist=allowlist)
            stack = REPLy.AbstractMiddleware[mw, REPLy.UnknownOpMiddleware()]
            msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf4", "file" => file), ctx)

            @test length(msgs) == 1
            @test "error" in msgs[1]["status"]
            @test "path-not-allowed" in msgs[1]["status"]
            @test occursin("Path not allowed", msgs[1]["err"])
        finally
            rm(file; force=true)
        end
    end

    @testset "path allowed by allowlist proceeds normally" begin
        ctx = make_ctx()
        file = tempname() * ".jl"
        try
            write(file, "999")
            allowlist = _ -> true  # allow everything
            mw = REPLy.LoadFileMiddleware(; load_file_allowlist=allowlist)
            stack = REPLy.AbstractMiddleware[mw, REPLy.UnknownOpMiddleware()]
            msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf5", "file" => file), ctx)

            assert_conformance(msgs, "lf5")
            @test any(get(m, "value", nothing) == "999" for m in msgs)
        finally
            rm(file; force=true)
        end
    end

    @testset "missing file field returns error" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf6"), ctx)

        @test length(msgs) == 1
        @test "error" in msgs[1]["status"]
        @test occursin("string file field", msgs[1]["err"])
    end

    @testset "non-load-file ops are forwarded" begin
        ctx = make_ctx()
        stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
        msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "eval", "id" => "lf7"), ctx)

        @test "unknown-op" in only(msgs)["status"]
    end

    @testset "syntax error in file returns structured error response" begin
        ctx = make_ctx()
        file = tempname() * ".jl"
        try
            write(file, "function broken(")
            stack = REPLy.AbstractMiddleware[REPLy.LoadFileMiddleware(), REPLy.UnknownOpMiddleware()]
            msgs = REPLy.dispatch_middleware(stack, 1, Dict("op" => "load-file", "id" => "lf8", "file" => file), ctx)

            assert_conformance(msgs, "lf8")
            @test "error" in only(filter(m -> haskey(m, "status"), msgs))["status"]
        finally
            rm(file; force=true)
        end
    end
end
