using Test
using REPLy

@testset "REPLy.jl" begin
    @test REPLy.protocol_name() == "REPLy"
    @test REPLy.version_string() == "0.1.0"
end
