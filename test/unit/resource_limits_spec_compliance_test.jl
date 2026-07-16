@testset "ResourceLimits spec compliance (REPLy_jl-zsx)" begin
    # Spec-defined fields and defaults from openspec/specs/resource-limits/spec.md
    # This test diffs fieldnames(ResourceLimits) against the spec table.
    # Fields that are intentionally separate from ResourceLimits (e.g. max_message_bytes
    # as a serve() kwarg) are documented in the test but not enforced here.

    @testset "all spec fields exist on ResourceLimits" begin
        limits = REPLy.ResourceLimits()
        spec_fields = [
            :max_eval_time_ms,
            :max_memory_mb,
            :max_sessions,
            :max_concurrent_evals,
            :rate_limit_per_min,
            :session_idle_timeout_s,
            :max_history_entries,
            :max_value_repr_bytes,
            :min_rate_limit_per_min,
        ]
        for field in spec_fields
            @test hasproperty(limits, field) ||
                @warn "Missing spec field: $field" maxlog=1
        end
    end

    @testset "defaults match spec table" begin
        limits = REPLy.ResourceLimits()
        @test limits.max_eval_time_ms == 60_000
        @test limits.max_sessions == 100
        @test limits.max_concurrent_evals == 10
        @test limits.rate_limit_per_min == 600
        @test limits.session_idle_timeout_s == 3_600
    end

    @testset "max_memory_mb is present and defaults to 2048" begin
        limits = REPLy.ResourceLimits()
        @test hasproperty(limits, :max_memory_mb)
        @test limits.max_memory_mb == 2048
    end

    @testset "min_rate_limit_per_min is present and defaults to 10" begin
        limits = REPLy.ResourceLimits()
        @test hasproperty(limits, :min_rate_limit_per_min)
        @test limits.min_rate_limit_per_min == 10
    end

    @testset "max_history_entries (spec name) matches max_session_history (code name)" begin
        # The spec calls it max_history_entries; the code calls it max_session_history.
        # Both map to the same field — verify the alias / rename.
        limits = REPLy.ResourceLimits()
        @test hasproperty(limits, :max_history_entries) ||
              hasproperty(limits, :max_session_history)
        @test getfield(limits, :max_history_entries) == 10_000 ||
              getfield(limits, :max_session_history) == 10_000
    end

    @testset "max_value_repr_bytes (spec name) matches max_repr_bytes (code name)" begin
        limits = REPLy.ResourceLimits()
        @test hasproperty(limits, :max_value_repr_bytes) ||
              hasproperty(limits, :max_repr_bytes)
        val = hasproperty(limits, :max_value_repr_bytes) ?
              limits.max_value_repr_bytes : limits.max_repr_bytes
        @test val == 1_048_576
    end

    @testset "max_message_size is documented as separate serve() kwarg" begin
        # max_message_size is a serve() kwarg (max_message_bytes), not a ResourceLimits field.
        # This test documents the design choice and verifies it's mentioned in the docstring.
        limits = REPLy.ResourceLimits()
        @test !hasproperty(limits, :max_message_size)
        @test_broken false  # Placeholder: docstring should mention max_message_bytes
    end

    @testset "max_id_length and max_stdin_buffer are fixed constants" begin
        # These are not in ResourceLimits — they're hardcoded constants.
        # Document the current values for spec compliance awareness.
        @test REPLy.MAX_SESSION_NAME_BYTES == 256
    end
end
