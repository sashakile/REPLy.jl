## 1. Extract run_with_timeout
- [ ] 1.1 Extract `run_with_timeout(f, timeout_ms)` as standalone function
- [ ] 1.2 Ensure it returns an intermediate result type (not a raw response dict)

## 2. Single annotate_terminal! pass
- [ ] 2.1 Identify the 3× redundant response rebuild paths in `eval_responses`
- [ ] 2.2 Replace with single `annotate_terminal!` pass that adds status, err, ex once
- [ ] 2.3 Verify no regression in response shape

## 3. Decompose coordinator
- [ ] 3.1 Wire up `EvalGate.acquire!/release!` from Step 5
- [ ] 3.2 Wire up `EvalRequest` from Step 8
- [ ] 3.3 Target: `eval_responses` ~30 lines, delegating to extracted functions
- [ ] 3.4 Write regression test: eval_responses produces same output as before
