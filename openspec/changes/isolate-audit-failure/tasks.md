## 1. Isolate audit write failure
- [ ] 1.1 Wrap `record_audit!` body in try/catch, degrade to `@warn` on failure
- [ ] 1.2 Verify audit failure no longer propagates to response
- [ ] 1.3 Write test: simulated audit-write failure does not affect eval result
