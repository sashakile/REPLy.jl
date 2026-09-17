## 1. Enforce validation
- [x] 1.1 Call `validate_stack(middleware)` at the beginning of `build_handler`
- [x] 1.2 Throw a descriptive error if validation fails
- [x] 1.3 Test that an invalid stack is caught at handler-build time

## 2. Enforce expects ordering (REPLy_jl-2rv5.6)
- [x] 2.1 Redefine `expects` as `Set{String}` of op names that must be provided by a *later* middleware
- [x] 2.2 `validate_stack` enforces unsatisfied `expects` as errors by default; all violations reported together
- [x] 2.3 `expects_enforcement = :warn` downgrades expects violations to warnings
- [x] 2.4 Convert built-in descriptors: backward positional strings fold into `requires`; forward refs become op-name `expects`
- [x] 2.5 Tests: satisfied/violated/earlier-only/warn-mode/aggregation
