@testset "ResourceLimits" begin
    @testset "defaults match expected baseline values" begin
        limits = REPLy.ResourceLimits()
        @test limits.max_repr_bytes    == REPLy.DEFAULT_MAX_REPR_BYTES       # 10 KB
        @test limits.max_eval_time_ms  == 30_000                             # 30 s
        @test limits.max_output_bytes  == 1_000_000                          # 1 MB
        @test limits.max_session_history == REPLy.MAX_SESSION_HISTORY_SIZE   # 1000
    end

    @testset "per-field override" begin
        limits = REPLy.ResourceLimits(max_repr_bytes=512)
        @test limits.max_repr_bytes   == 512
        @test limits.max_eval_time_ms == 30_000  # unchanged
    end

    @testset "all fields overridable" begin
        limits = REPLy.ResourceLimits(
            max_repr_bytes=100,
            max_eval_time_ms=5_000,
            max_output_bytes=50_000,
            max_session_history=10,
        )
        @test limits.max_repr_bytes      == 100
        @test limits.max_eval_time_ms    == 5_000
        @test limits.max_output_bytes    == 50_000
        @test limits.max_session_history == 10
    end

    @testset "EvalMiddleware accepts ResourceLimits" begin
        limits = REPLy.ResourceLimits(max_repr_bytes=42)
        mw = REPLy.EvalMiddleware(limits)
        @test mw.max_repr_bytes == 42
    end

    @testset "max_connections has default of 100" begin
        limits = REPLy.ResourceLimits()
        @test limits.max_connections == 100
    end

    @testset "max_connections can be configured" begin
        limits = REPLy.ResourceLimits(max_connections=10)
        @test limits.max_connections == 10
    end
end
