## 1. Fix data race
- [ ] 1.1 Replace `copy(log.entries)` with `lock(log.lock) do; copy(log.entries); end`
- [ ] 1.2 Verify no other lock-free access to `log.entries` exists
- [ ] 1.3 Write test: concurrent `audit_entries` read during audit writes produces consistent snapshot
