## 1. Extract EvalGate type
- [ ] 1.1 Define `EvalGate` struct with `max::Int` and `active::Atomic{Int}` + `cv::Condition`
- [ ] 1.2 Implement `acquire!` (blocks if at max, increments on grant)
- [ ] 1.3 Implement `release!` (decrements + notifies condition)
- [ ] 1.4 Implement `active_count` for introspection

## 2. Replace manual slot management
- [ ] 2.1 Replace `active_evals` atomic + condition var with `EvalGate` in `ServerState`
- [ ] 2.2 Remove `_eval_acquire_slot` / `_eval_release_slot` functions
- [ ] 2.3 Re-point `eval.jl` to use `EvalGate.acquire!/release!`
- [ ] 2.4 Verify `eval.jl` no longer touches `active_evals` directly

## 3. Write tests
- [ ] 3.1 Test that max concurrent evals blocks new ones
- [ ] 3.2 Test that release! wakes up a waiting acquirer
- [ ] 3.3 Test invariant: `active_count` stays within `[0, max]`
