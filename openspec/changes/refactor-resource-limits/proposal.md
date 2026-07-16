# Change: Refactor ResourceLimits into value object with accessors (B7)

## Why

6 files reach `ctx.server_state.limits.<field>` 3 levels deep, each repeating a `isnothing(server_state)` guard. `ResourceLimits` has no `unlimited()` preset. Missing spec-table fields (`max_id_length`, `max_message_size`, `max_stdin_buffer`) are defined in the spec but not enforced as typed limits.

## What Changes

- `ResourceLimits` becomes a proper value object with `unlimited()` constructor
- Add `effective_limit(ctx, :field, default)` accessor pattern
- Add missing fields (`max_id_length`, `max_message_size`, `max_stdin_buffer`) to the typed struct
- Validate config at construction time
- Retire `isnothing(server_state)` guards via `ResourceLimits.unlimited()` fallback

## Impact

- Affected specs: `resource-limits` (add missing fields + unlimited constructor)
- Affected code: `src/resource_limits.jl`, 6 call sites across the codebase