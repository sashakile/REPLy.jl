## 1. Enforce validation
- [ ] 1.1 Call `validate_stack(middleware)` at the beginning of `build_handler`
- [ ] 1.2 Throw a descriptive error if validation fails
- [ ] 1.3 Test that an invalid stack is caught at handler-build time