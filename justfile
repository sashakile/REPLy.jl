set shell := ["bash", "-euo", "pipefail", "-c"]

default:
    @just --list

bootstrap:
    @command -v prek >/dev/null || { echo "prek is required"; exit 1; }
    prek install

hooks:
    prek run --all-files

typos-check:
    typos .

lint: typos-check
    vale README.md llm.txt openspec/project.md docs/src

workflow-lint:
    actionlint

specs:
    openspec validate --specs

doctor:
    wai doctor

test:
    ./scripts/check-julia-package.sh test

smoke-test:
    julia --project=. scripts/smoke-test.jl

coverage:
    ./scripts/coverage.sh

_docs-bootstrap:
    julia --project=docs/ -e 'using Pkg; Pkg.develop(PackageSpec(path=pwd())); Pkg.instantiate()'

docs-build: _docs-bootstrap
    julia --project=docs/ docs/make.jl

docs: _docs-bootstrap
    julia --project=docs/ -e 'using LiveServer; servedocs()'

check: workflow-lint lint test smoke-test coverage

full-check: check specs doctor
