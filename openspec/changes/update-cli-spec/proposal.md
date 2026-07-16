# Change: Update cli-distribution spec to match shipped scratch-env design (R4)

## Why

The normative `cli-distribution/spec.md` mandates `--project=<pkg_dir>` — the design that was abandoned because it was broken. The shipped code uses a private, UUID-namespaced scratch environment (via `Scratch.jl`). A public release must not ship a spec that contradicts (and mis-instructs re-implementation of) the shipped code.

## What Changes

- Replace the `--project=<pkg_dir>` requirement with the scratch-env design
- Update launcher behavior scenarios to match actual implementation
- Remove the `--project` pinning scenario; add scratch-env scenario

## Impact

- Affected specs: `cli-distribution` (full rewrite of Requirement 2)
- No code changes — pure spec correction
- Release blocker: R4