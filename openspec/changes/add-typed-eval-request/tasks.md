## 1. Define typed EvalRequest
- [ ] 1.1 Define `EvalRequest` struct with validated fields: `code`, `session`, `id`, `stdin`, etc.
- [ ] 1.2 Implement `parse_eval_request(dict::Dict) -> Union{EvalRequest, ErrorResponse}`
- [ ] 1.3 Validate all semantic fields at parse time (not downstream)

## 2. Re-point handlers
- [ ] 2.1 Replace `dict["code"]` / `get(dict, "session", nothing)` re-fetches in handler
- [ ] 2.2 Use `EvalRequest` fields directly in all downstream code
- [ ] 2.3 Remove redundant validation in `eval.jl:293,299,302`

## 3. Write tests
- [ ] 3.1 Test EvalRequest parsing rejects invalid input
- [ ] 3.2 Test that downstream handlers receive validated fields