## 1. Add restore function
- [ ] 1.1 Create `restore_io_capture!()` that writes originals back to `Base.stdout`/`Base.stderr`
- [ ] 1.2 Call from `close_server!` in `server.jl`

## 2. Write tests
- [ ] 2.1 Test that stdout/stderr are restored after server close
- [ ] 2.2 Test that restored streams are functional
