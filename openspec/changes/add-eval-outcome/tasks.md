## 1. Define EvalOutcome
- [ ] 1.1 Define `EvalOutcome` union type with variants: `Completed{value}`, `Interrupted`, `TimedOut`, `Errored{exception, trace}`, `Cancelled`
- [ ] 1.2 Implement `serialize(outcome::EvalOutcome) -> Dict` for wire format

## 2. Wire into decomposed eval_responses
- [ ] 2.1 Replace ad-hoc status arrays with `EvalOutcome` throughout the eval path
- [ ] 2.2 Serialize to wire format only at the edge (before sending to client)

## 3. Add stable error codes
- [ ] 3.1 Audit all validation error paths in eval subsystem
- [ ] 3.2 Add stable low-cardinality code to each (e.g., `missing-code`, `invalid-session`, `eval-timeout`)
- [ ] 3.3 Verify codes appear in response status array

## 4. Write tests
- [ ] 4.1 Test each EvalOutcome variant serializes correctly
- [ ] 4.2 Test stable error codes appear in validation errors
- [ ] 4.3 Test wire format unchanged (frozen protocol)