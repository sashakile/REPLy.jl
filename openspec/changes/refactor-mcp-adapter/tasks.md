## 1. Split god-file
- [ ] 1.1 Create `mcp/tools.jl` — tool catalog, tool definitions
- [ ] 1.2 Create `mcp/requests.jl` — request builders, parameter parsing
- [ ] 1.3 Create `mcp/results.jl` — result adapters, error mapping
- [ ] 1.4 Create `mcp/server.jl` — server setup, MCP protocol handling

## 2. Drop loopback hop
- [ ] 2.1 Make in-process bridge call `handler` closure directly
- [ ] 2.2 Keep real-socket mode as configurable option
- [ ] 2.3 Verify no behavior change in MCP responses

## 3. Write tests
- [ ] 3.1 Test in-process mode produces same results as socket mode
- [ ] 3.2 Test module-level imports after split