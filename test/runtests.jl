using Test
using REPLy
using JSON3
using Sockets

include("helpers/conformance.jl")
include("helpers/tcp_client.jl")
include("helpers/server.jl")

@testset "REPLy.jl" begin
    @testset "unit" begin
        include("unit/basic_test.jl")
    end

    @testset "integration" begin
        # Intentionally red until build_handler exists.
        include("integration/pipeline_test.jl")
    end

    @testset "e2e" begin
        # Intentionally red until serve exists.
        include("e2e/eval_test.jl")
    end
end
