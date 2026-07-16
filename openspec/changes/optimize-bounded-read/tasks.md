## 1. Optimize hot loop
- [ ] 1.1 Replace `read(conn.io, UInt8)` with chunked read (e.g., 4096 bytes)
- [ ] 1.2 Scan buffer for newline delimiter
- [ ] 1.3 Add reusable per-connection buffer to avoid per-request allocation

## 2. Write tests
- [ ] 2.1 Test that chunked read produces same results as byte-at-a-time
- [ ] 2.2 Benchmark improvement on reference hardware
- [ ] 2.3 Test boundary conditions (messages exactly at chunk boundary)