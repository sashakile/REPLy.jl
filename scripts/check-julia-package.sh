#!/usr/bin/env bash
set -euo pipefail

mode="${1:-test}"

if [[ ! -f Project.toml ]]; then
  echo "Skipping Julia ${mode}: no Project.toml present"
  exit 0
fi

if [[ ! -f test/runtests.jl ]]; then
  echo "Skipping Julia ${mode}: no test/runtests.jl present"
  exit 0
fi

julia --project=. -e 'using Pkg; Pkg.instantiate(); Pkg.test()'
