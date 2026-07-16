@testset "ServerState — shared above listener-local paths" begin
    @testset "default serve creates state with ResourceLimits" begin
        server = REPLy.serve(; port=0)
        try
            @test hasproperty(server, :state)
            @test server.state isa REPLy.ServerState
            @test server.state.limits isa REPLy.ResourceLimits
        finally
            close(server)
        end
    end

    @testset "custom ResourceLimits flows through to server state" begin
        limits = REPLy.ResourceLimits(max_value_repr_bytes=42)
        server = REPLy.serve(; port=0, limits=limits)
        try
            @test server.state.limits.max_value_repr_bytes == 42
        finally
            close(server)
        end
    end

    @testset "max_message_bytes lives in state, not as top-level handle field" begin
        server = REPLy.serve(; port=0, max_message_bytes=512)
        try
            @test server.state.max_message_bytes == 512
            @test !hasproperty(server, :max_message_bytes)
        finally
            close(server)
        end
    end

    @testset "unix server state is shared above listener" begin
        path = tempname()
        server = REPLy.serve(; socket_path=path)
        try
            @test server.state isa REPLy.ServerState
            @test server.state.limits isa REPLy.ResourceLimits
        finally
            close(server)
        end
    end

    @testset "state is a shared mutable reference (not copied per client)" begin
        server = REPLy.serve(; port=0)
        try
            # Both fields should be consistent references in the same struct
            @test server.state === server.state
            @test server.state.max_message_bytes == REPLy.DEFAULT_MAX_MESSAGE_BYTES
        finally
            close(server)
        end
    end

    @testset "production server automatically sweeps idle sessions" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "idle")
        lock(session.lock) do; session.last_active_at = time() - 10; end
        limits = REPLy.ResourceLimits(session_idle_timeout_s=1)
        server = REPLy.serve(; port=0, manager=manager, limits=limits, _sweep_interval_s=0.01)
        try
            @test timedwait(() -> isnothing(REPLy.lookup_named_session(manager, "idle")), 1) == :ok
        finally
            close(server)
        end
    end

    @testset "automatic sweep preserves a running session" begin
        manager = REPLy.SessionManager()
        session = REPLy.create_named_session!(manager, "running")
        REPLy.begin_eval!(session, current_task())
        lock(session.lock) do; session.last_active_at = time() - 10; end
        limits = REPLy.ResourceLimits(session_idle_timeout_s=1)
        server = REPLy.serve(; port=0, manager=manager, limits=limits, _sweep_interval_s=0.01)
        try
            sleep(0.05)
            @test REPLy.lookup_named_session(manager, "running") === session
        finally
            REPLy.end_eval!(session)
            close(server)
        end
    end

    @testset "multi-listener owns one sweeper and shutdown cleans it promptly" begin
        server = REPLy.serve_multi((; port=0), (; port=0); _sweep_interval_s=60)
        sweeper = server.state.session_sweeper
        @test sweeper !== nothing
        @test all(listener.state.session_sweeper === sweeper for listener in server.listeners)
        elapsed = @elapsed close(server)
        @test elapsed < 1
        @test istaskdone(sweeper.task)
        @test !isopen(sweeper.timer)
        @test server.state.session_sweeper === nothing
    end
end

@testset "non-loopback TCP host emits startup security warning" begin
    server = @test_logs (:warn, r"non-loopback") REPLy.serve(; host=ip"0.0.0.0", port=0)
    close(server)
end

@testset "loopback TCP host emits no security warning" begin
    server = @test_logs min_level=Logging.Warn REPLy.serve(; host=ip"127.0.0.1", port=0)
    close(server)
end
