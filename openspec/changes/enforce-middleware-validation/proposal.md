# Change: Enforce middleware stack validation in build_handler (B6)

## Why

`validate_stack` exists but `build_handler` never calls it (`core.jl:39` docstring confirms "not called automatically"). A custom stack dropping or reordering `SessionMiddleware` fails at request time, not startup. One-line guard.

## What Changes

- Call `validate_stack` in `build_handler`, throw on errors
- Startup-time detection of invalid middleware stacks

## Impact

- Affected specs: `middleware`
- Affected code: `src/core.jl`
