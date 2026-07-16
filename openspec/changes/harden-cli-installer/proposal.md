# Change: Harden CLI installer — interpreter pin, Windows, self-verify (R1, A6)

## Why

Three verified CLI installer issues:
1. **R1 (P0):** `replyc` launcher hardcodes bare `julia` — must capture `Base.julia_cmd()[1]` at build time. Already fixed in `c3e320b` (patch in sandbox dir); needs upstream apply + PR.
2. **No Windows launcher:** writes bash + `chmod`, a no-op on Windows.
3. **No install self-verification:** build can report success on a launcher that can't load.

## What Changes

- Apply the `c3e320b` patch upstream (interpreter pin)
- Generate Windows `.bat`/`.cmd` launcher on Windows
- Add `--verify` flag to build script that tests the launcher can load

## Impact

- Affected specs: `cli-distribution`
- Affected code: `deps/build.jl`, `bin/replyc` template
- Release blocker: R1 (P0 — no working `replyc` after `Pkg.add`)