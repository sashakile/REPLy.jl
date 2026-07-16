## 1. Refactor struct
- [ ] 1.1 Add `ResourceLimits.unlimited()` constructor with no limits
- [ ] 1.2 Add missing fields: `max_id_length`, `max_message_size`, `max_stdin_buffer`
- [ ] 1.3 Validate config at construction (negative values, etc.)

## 2. Add accessor pattern
- [ ] 2.1 Define `effective_limit(ctx, field, default)` accessor
- [ ] 2.2 Re-point all 6 call sites to use accessor instead of raw reach-through
- [ ] 2.3 Retire `isnothing(server_state)` guards

## 3. Write tests
- [ ] 3.1 Test unlimited() permits everything
- [ ] 3.2 Test accessor returns configured value vs default
- [ ] 3.3 Test construction rejects invalid values
