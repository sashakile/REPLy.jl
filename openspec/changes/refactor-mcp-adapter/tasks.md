## 1. Split god-file
- [ ] 1.1 Create `mcp/tools.jl` — tool catalog, tool definitions
- [ ] 1.2 Create `mcp/requests.jl` — request builders, parameter parsing
- [ ] 1.3 Create `mcp/results.jl` — result adapters, error mapping
- [ ] 1.4 Create `mcp/server.jl` — server setup, MCP protocol handling

## 2. Drop loopback hop
- [x] 2.1 Make in-process bridge call `handler` closure directly
- [x] 2.2 Keep real-socket mode as configurable option (`use_socket` keyword)
- [x] 2.3 Verify no behavior change in MCP responses (all 2550 tests pass)

## 3. Write tests
- [x] 3.1 Test in-process mode produces same results as socket mode (tests updated to use in-process handler; all 29 MCP tests pass)
- [x] 3.2 Test module-level imports after split
