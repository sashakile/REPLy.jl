## 1. Fix malformed JSON handling
- [ ] 1.1 Catch parse errors in `message.jl:66-68`, return `malformed-request` response
- [ ] 1.2 Keep connection open, increment malformed counter
- [ ] 1.3 Test that malformed JSON returns error response, not disconnect

## 2. Classify file-read errors
- [ ] 2.1 Add stable error codes: `path-not-allowed`, `file-not-found`, `io-error`
- [ ] 2.2 Classify errno codes in `load_file.jl:88-92`
- [ ] 2.3 Strip sensitive paths from error messages

## 3. Fix silent swallows
- [ ] 3.1 Replace bare `catch` in `safe_render` with specific exception types
- [ ] 3.2 Replace bare `catch` in `_update_history!` with specific exception types
- [ ] 3.3 Add rate-limited `@debug` + counter to remaining generic catches