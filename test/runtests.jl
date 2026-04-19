using Test
using REPLy
using JSON3
using Sockets

include("helpers/conformance.jl")
include("helpers/tcp_client.jl")
include("helpers/server.jl")

@testset "REPLy.jl" begin
    @testset "quality" begin
        include("quality_test.jl")
    end

    @testset "unit" begin
        include("unit/basic_test.jl")
        include("unit/message_test.jl")
        include("unit/session_test.jl")
        include("unit/eval_middleware_test.jl")
        include("unit/middleware_test.jl")
        include("unit/error_test.jl")
    end

    @testset "integration" begin
        # Keep outer-layer tests visible while inner tickets land incrementally.
        if isdefined(REPLy, :build_handler)
            include("integration/pipeline_test.jl")
        else
            @test_broken isdefined(REPLy, :build_handler)
        end
    end

    @testset "e2e" begin
        # Keep outer-layer tests visible while inner tickets land incrementally.
        if isdefined(REPLy, :serve)
            include("e2e/eval_test.jl")
            include("e2e/unix_socket_test.jl")
        else
            @test_broken isdefined(REPLy, :serve)
        end
    end
end
