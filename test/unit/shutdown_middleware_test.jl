# Shutdown middleware unit tests
@testset "ShutdownMiddleware" begin
    @testset "shutdown op sets flag on ServerState" begin
        state = REPLy.ServerState(REPLy.ResourceLimits(), 1024)
        handler = REPLy.build_handler(; middleware=REPLy.AbstractMiddleware[
            REPLy.ShutdownMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ], state=state)

        @test state.shutdown_requested[] == false
        responses = handler(Dict("op" => "shutdown", "id" => "shutdown-unit-1"))
        @test state.shutdown_requested[] == true
        @test length(responses) == 1
        @test "shutdown-started" in get(responses[1], "status", String[])
    end

    @testset "shutdown op without state is a no-op" begin
        handler = REPLy.build_handler(; middleware=REPLy.AbstractMiddleware[
            REPLy.ShutdownMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ])
        responses = handler(Dict("op" => "shutdown", "id" => "shutdown-unit-2"))
        @test length(responses) == 1
        @test "shutdown-started" in get(responses[1], "status", String[])
    end

    @testset "other ops pass through" begin
        handler = REPLy.build_handler(; middleware=REPLy.AbstractMiddleware[
            REPLy.ShutdownMiddleware(),
            REPLy.UnknownOpMiddleware(),
        ])
        responses = handler(Dict("op" => "ping", "id" => "shutdown-unit-3"))
        @test any("error" in get(m, "status", String[]) for m in responses)
    end

    @testset "shutdown middleware descriptor" begin
        mw = REPLy.ShutdownMiddleware()
        desc = REPLy.descriptor(mw)
        @test "shutdown" in desc.provides
        @test haskey(desc.op_info, "shutdown")
    end
end
