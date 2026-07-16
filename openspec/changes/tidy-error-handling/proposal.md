# Change: Tidy error handling — silent swallows, malformed JSON, file-read errors (Part C)

## Why

Three single-lens findings from the error-handling diagnostician:
1. **Malformed wire JSON → silent disconnect:** `message.jl:66-68` silently closes the connection instead of returning `malformed-request` and keeping the connection open.
2. **File-read errors unclassified + detail-leaking:** `load_file.jl:88-92` propagates raw error messages that may leak paths; no stable error codes.
3. **Silent internal swallows:** `safe_render`, `_update_history!` use bare `catch` → rate-limited `@debug`/counter.

## What Changes

- Return `malformed-request` status on malformed JSON instead of silent disconnect
- Classify file-read errors into stable codes (path-not-allowed, file-not-found, io-error)
- Replace bare `catch` with specific exception handling + rate-limited logging + counter

## Impact

- Affected specs: `error-handling`
- Affected code: `src/message.jl`, `src/load_file.jl`, render/history code
