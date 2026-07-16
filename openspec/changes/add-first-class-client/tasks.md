## 1. Define Client type
- [ ] 1.1 Define `REPLy.Client` struct with transport, encoding, state
- [ ] 1.2 Implement `connect`, `send`, `receive`, `disconnect` methods
- [ ] 1.3 Support TCP and Unix socket transports
- [ ] 1.4 Support message framing (length-prefixed JSON)

## 2. Re-point consumers
- [ ] 2.1 Update replyc to use `REPLy.Client`
- [ ] 2.2 Update MCP adapter to use `REPLy.Client`
- [ ] 2.3 Update qa harness to use `REPLy.Client`
- [ ] 2.4 Update tutorial to use `REPLy.Client`

## 3. Write tests
- [ ] 3.1 Test connect/send/receive round-trip
- [ ] 3.2 Test disconnect handling
- [ ] 3.3 Test error handling (connection refused, closed, etc.)
