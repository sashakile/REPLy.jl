## 1. Document lock ownership
- [ ] 1.1 Add field→lock table to `NamedSession` struct docstring
- [ ] 1.2 Categorize each field by protecting lock (or none for immutable/atomic)

## 2. Add lock assertions
- [ ] 2.1 Add `@assert islocked(...)` on mutators for lock-guarded fields
- [ ] 2.2 Follow pattern already used in `io_capture.jl`

## 3. Encapsulate stdin pair
- [ ] 3.1 Define `StdinFeeder` value type encapsulating `stdin_pipe` + `stdin_feeder` task
- [ ] 3.2 Replace two separate fields with one `StdinFeeder` field
- [ ] 3.3 Ensure create/teardown is atomic at the value level
