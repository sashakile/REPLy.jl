## 1. Apply interpreter pin (R1)
- [ ] 1.1 Apply patch from `c3e320b` upstream
- [ ] 1.2 Verify `Base.julia_cmd()[1]` is captured at build time
- [ ] 1.3 PR the fix upstream

## 2. Windows launcher
- [ ] 2.1 Generate `.bat`/`.cmd` wrapper on Windows
- [ ] 2.2 Skip chmod on Windows
- [ ] 2.3 Test on Windows CI

## 3. Self-verification
- [ ] 3.1 Add `--verify` flag to `deps/build.jl`
- [ ] 3.2 Verify launcher can load REPLy without error
- [ ] 3.3 Fail build if verification fails
