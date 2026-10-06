---
id: spec
kind: intent
statement: "WHEN resource configuration is selected, THE runtime SHALL report actual memory enforcement and reject a required unavailable limit."
---

## Constraints

| id | kind | expr | traces_to |
|----|------|------|-----------|
| MEMORY_CAPABILITY | invariant | Memory configuration is distinguished from an actual per-runtime OS cap | [[spec]] |
| MEMORY_BOUNDARY | invariant | Supported OS memory caps contain the worker process tree without capping the supervisor | [[spec]] |

## Model

### States

- `unconfigured`
- `configured`

### Transitions

| id | from | to | guard |
|----|------|----|-------|
| establish_contract | unconfigured | configured | [[spec.MEMORY_CAPABILITY]] |
| exercise_contract_1 | configured | configured | [[spec.MEMORY_CAPABILITY]] |
| exercise_contract_2 | configured | configured | [[spec.MEMORY_BOUNDARY]] |

## Properties

| id | kind | derives_from | generator | predicate |
|----|------|--------------|-----------|-----------|
| memory_capability_holds | unit | [[spec.MEMORY_CAPABILITY]] | `test/e2e/managed_runtime_test.jl` | attached and optional unsupported caps report zero; required unsupported caps fail startup |
| memory_boundary_holds | unit | [[spec.MEMORY_BOUNDARY]] | `test/e2e/managed_runtime_test.jl` | over-limit workload triggers the supported backend and supervisor ping remains available |

## MODIFIED Requirements

### Requirement: ResourceLimits Configuration Struct
The server SHALL accept a `ResourceLimits` configuration with the following fields and defaults. Controls SHALL follow their governing mode-aware capability contracts. max_memory_mb retains its configuration default but is unsupported for attached execution. Managed execution SHALL apply the configured per-runtime worker/process-tree cap only through a supported OS backend, report the effective cap, and fail startup when require_memory_limit=true and enforcement is unavailable; optional unsupported enforcement SHALL report effective-memory-limit-mb=0. (REQ-RPL-047)

| Field | Type | Default | Governing Spec | Req ID |
|---|---|---|---|---|
| `max_eval_time_ms` | Int | 60,000 (60 s) | security | REQ-RPL-047a |
| `max_memory_mb` | Int | 2,048 (2 GB) | security | REQ-RPL-047b |
| `max_sessions` | Int | 100 | security | REQ-RPL-047c |
| `max_concurrent_evals` | Int | 10 | security | REQ-RPL-047d |
| `max_message_size` | Int (bytes) | 10,485,760 (10 MB) | security | REQ-RPL-047e |
| `rate_limit_per_min` | Int | 600 | security | REQ-RPL-047f |
| `session_idle_timeout_s` | Int | 3,600 (1 hour) | session-management | REQ-RPL-034 |
| `max_history_entries` | Int | 10,000 (per session) | session-management | REQ-RPL-047h |
| `max_value_repr_bytes` | Int (bytes) | 1,048,576 (1 MB) | core-operations | REQ-RPL-047i |
| `max_id_length` | Int | 256 | protocol | REQ-RPL-001b |
| `min_rate_limit_per_min` | Int | 10 (informative) | security | MATH-007 |
| `max_stdin_buffer` | Int | 16 | core-operations | REQ-RPL-017b |

#### Scenario: Default limits applied when unconfigured
- **WHEN** the server starts with no explicit `ResourceLimits`
- **THEN** all fields use the defaults from the table above

#### Scenario: Individual fields overridable
- **WHEN** the server starts with `ResourceLimits(max_sessions=128)`
- **THEN** `max_sessions` is 128 and all other fields retain their defaults

#### Scenario: Strict managed memory requirement
- **WHEN** launch requests require_memory_limit=true without a supported OS enforcement backend
- **THEN** startup fails before user code and no endpoint is published

#### Scenario: Optional unsupported control
- **WHEN** attached execution or an optional managed launch cannot enforce max_memory_mb
- **THEN** capabilities report unsupported, the effective cap is zero and no enforcement claim is made

#### Scenario: Enforced managed cap
- **WHEN** a supported OS backend enforces max_memory_mb for the owned worker process tree
- **THEN** capabilities report the applied limit, allocation-over-limit tests verify it and the supervisor stays outside the capped memory domain

## Requirements

### Requirement: ResourceLimits Configuration Struct
The server SHALL accept a `ResourceLimits` configuration with the following fields and defaults. Controls SHALL follow their governing mode-aware capability contracts. max_memory_mb retains its configuration default but is unsupported for attached execution. Managed execution SHALL apply the configured per-runtime worker/process-tree cap only through a supported OS backend, report the effective cap, and fail startup when require_memory_limit=true and enforcement is unavailable; optional unsupported enforcement SHALL report effective-memory-limit-mb=0. (REQ-RPL-047)

| Field | Type | Default | Governing Spec | Req ID |
|---|---|---|---|---|
| `max_eval_time_ms` | Int | 60,000 (60 s) | security | REQ-RPL-047a |
| `max_memory_mb` | Int | 2,048 (2 GB) | security | REQ-RPL-047b |
| `max_sessions` | Int | 100 | security | REQ-RPL-047c |
| `max_concurrent_evals` | Int | 10 | security | REQ-RPL-047d |
| `max_message_size` | Int (bytes) | 10,485,760 (10 MB) | security | REQ-RPL-047e |
| `rate_limit_per_min` | Int | 600 | security | REQ-RPL-047f |
| `session_idle_timeout_s` | Int | 3,600 (1 hour) | session-management | REQ-RPL-034 |
| `max_history_entries` | Int | 10,000 (per session) | session-management | REQ-RPL-047h |
| `max_value_repr_bytes` | Int (bytes) | 1,048,576 (1 MB) | core-operations | REQ-RPL-047i |
| `max_id_length` | Int | 256 | protocol | REQ-RPL-001b |
| `min_rate_limit_per_min` | Int | 10 (informative) | security | MATH-007 |
| `max_stdin_buffer` | Int | 16 | core-operations | REQ-RPL-017b |

#### Scenario: Default limits applied when unconfigured
- **WHEN** the server starts with no explicit `ResourceLimits`
- **THEN** all fields use the defaults from the table above

#### Scenario: Individual fields overridable
- **WHEN** the server starts with `ResourceLimits(max_sessions=128)`
- **THEN** `max_sessions` is 128 and all other fields retain their defaults

#### Scenario: Strict managed memory requirement
- **WHEN** launch requests require_memory_limit=true without a supported OS enforcement backend
- **THEN** startup fails before user code and no endpoint is published

#### Scenario: Optional unsupported control
- **WHEN** attached execution or an optional managed launch cannot enforce max_memory_mb
- **THEN** capabilities report unsupported, the effective cap is zero and no enforcement claim is made

#### Scenario: Enforced managed cap
- **WHEN** a supported OS backend enforces max_memory_mb for the owned worker process tree
- **THEN** capabilities report the applied limit, allocation-over-limit tests verify it and the supervisor stays outside the capped memory domain
