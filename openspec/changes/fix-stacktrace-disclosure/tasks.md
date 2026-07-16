## 1. Split error boundaries
- [ ] 1.1 Rename `internal_error_response` → `eval_error_response` stays user-facing
- [ ] 1.2 Create new `internal_error_response` returning stable code + correlation id only
- [ ] 1.3 Re-point all server-internal failure sites to new function

## 2. Server-side logging
- [ ] 2.1 Log full trace + correlation id server-side on internal failures
- [ ] 2.2 Generate correlation id (UUID or sequence) per internal failure

## 3. Opt-in trace exposure gate
- [ ] 3.1 Add config flag `expose_internal_traces` (Bool, default false)
- [ ] 3.2 When true and connection is loopback, include full trace in response
- [ ] 3.3 Document the flag in server config

## 4. Write tests
- [ ] 4.1 Test internal failure returns stable code + no path leakage
- [ ] 4.2 Test opt-in trace exposure on loopback
