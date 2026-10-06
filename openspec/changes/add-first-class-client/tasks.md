## 1. Define Client type
- [ ] 1.1 Define `REPLy.Client` struct with transport, encoding, state
- [ ] 1.2 Implement `connect`, `send`, `receive`, `disconnect` methods
- [ ] 1.3 Support TCP and Unix socket transports
- [ ] 1.4 Reuse existing newline-delimited JSON framing (REQ-RPL-002; no length-prefix protocol change)

## 2. Re-point consumers
- [ ] 2.1 Update replyc to use `REPLy.Client`
- [ ] 2.2 Update MCP adapter to use `REPLy.Client`
- [ ] 2.3 Update qa harness to use `REPLy.Client`
- [ ] 2.4 Update tutorial to use `REPLy.Client`

## 3. Write tests
- [ ] 3.1 Test connect/send/receive round-trip
- [ ] 3.2 Test disconnect handling
- [ ] 3.3 Test error handling (connection refused, closed, etc.)

## Application order

The approved add-managed-execution-modes connect slice extends the existing Client with Unix transport and checked discovery. Complete consumer migration under this change after that slice; reuse those constructors and JSONTransport rather than introducing a second client or changing framing. Managed MCP ownership belongs to tasks 6.2 of add-managed-execution-modes; preserve the existing in-process default. update-cli-spec remains scoped to the installer scratch environment and precedes documentation of the additive foreground launch command.
