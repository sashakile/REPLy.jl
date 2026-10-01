# Purpose: Map the resource-limits capability spec
#   (openspec/specs/resource-limits/spec.md, REQ-RPL-047) to executable
#   assertions — espectacular contracts for the "Default limits applied when
#   unconfigured" and "Individual fields overridable" scenarios include this
#   file directly (ah check --run-tests), so it must stay standalone.
# Responsibilities:
#   - Assert every field in the spec's ResourceLimits table exists.
#   - Assert each field's spec-table default value.
#   - Assert individual-field overrides retain the other spec-table defaults.
#   - Document struct fields beyond the spec table (max_output_bytes,
#     max_connections, revise_hook_enabled) so the table stays reconciled.
# Rationale: The spec is the single source of truth for field names, types,
#   and defaults; this test is the enforcement point that keeps the code and
#   the spec table reconciled (REPLy_jl-zsx, REPLy_jl-c80s).
@testset "ResourceLimits spec compliance (REPLy_jl-zsx)" begin

    @testset "all spec-table fields exist on ResourceLimits" begin
        limits = REPLy.ResourceLimits()
        spec_fields = [
            :max_eval_time_ms,
            :max_memory_mb,
            :max_sessions,
            :max_concurrent_evals,
            :max_message_size,
            :rate_limit_per_min,
            :session_idle_timeout_s,
            :max_history_entries,
            :max_value_repr_bytes,
            :max_id_length,
            :min_rate_limit_per_min,
            :max_stdin_buffer,
        ]
        for field in spec_fields
            @test hasproperty(limits, field)
        end
    end

    @testset "defaults match spec table" begin
        limits = REPLy.ResourceLimits()
        @test limits.max_eval_time_ms      == 60_000      # REQ-RPL-047a
        @test limits.max_memory_mb         == 2_048       # REQ-RPL-047b
        @test limits.max_sessions          == 100         # REQ-RPL-047c
        @test limits.max_concurrent_evals  == 10          # REQ-RPL-047d
        @test limits.max_message_size      == 10_485_760  # REQ-RPL-047e
        @test limits.rate_limit_per_min    == 600         # REQ-RPL-047f
        @test limits.session_idle_timeout_s == 3_600      # REQ-RPL-034
        @test limits.max_history_entries   == 10_000      # REQ-RPL-047h
        @test limits.max_value_repr_bytes  == 1_048_576   # REQ-RPL-047i
        @test limits.max_id_length         == 256         # REQ-RPL-001b
        @test limits.min_rate_limit_per_min == 10         # MATH-007
        @test limits.max_stdin_buffer      == 16          # REQ-RPL-017b
    end

    @testset "struct has documented extra fields beyond the spec table" begin
        # Fields in code but not in the spec table — listed here so the
        # spec table and the struct stay visibly reconciled.
        limits = REPLy.ResourceLimits()
        @test limits.max_output_bytes == 1_000_000
        @test limits.max_connections == 100
        @test limits.revise_hook_enabled == true
    end

    @testset "individual fields overridable" begin
        # Spec scenario: ResourceLimits(max_sessions=128) overrides one field,
        # all other fields retain their spec-table defaults.
        limits = REPLy.ResourceLimits(max_sessions=128)
        @test limits.max_sessions == 128
        @test limits.max_eval_time_ms == 60_000
        @test limits.rate_limit_per_min == 600
        @test limits.session_idle_timeout_s == 3_600
    end
end
