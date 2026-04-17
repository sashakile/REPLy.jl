#!/usr/bin/env bash
set -euo pipefail

if [[ ! -f Project.toml ]]; then
  echo "Skipping coverage: no Project.toml present"
  exit 0
fi

if [[ ! -f test/runtests.jl ]]; then
  echo "Skipping coverage: no test/runtests.jl present"
  exit 0
fi

export COVERAGE_MIN="${COVERAGE_MIN:-0}"

julia --project=. --code-coverage=user -e 'using Pkg; Pkg.instantiate(); Pkg.test(coverage=true)'

julia -e '
using Pkg
Pkg.activate(mktempdir())
Pkg.add("Coverage")
using Coverage
records = process_folder("src")
covered, total = get_summary(records)
pct = total == 0 ? 100.0 : covered / total * 100
println("Coverage: ", round(pct; digits=2), "%")
minpct = parse(Float64, get(ENV, "COVERAGE_MIN", "0"))
if pct < minpct
    error("Coverage $(round(pct; digits=2))% is below threshold $(minpct)%")
end
'
