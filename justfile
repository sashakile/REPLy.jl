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

lint:
    vale README.md llm.txt openspec/project.md

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

docs:
    julia --project=docs/ -e 'using LiveServer; servedocs()'

check: lint workflow-lint test smoke-test coverage

full-check: check specs doctor
