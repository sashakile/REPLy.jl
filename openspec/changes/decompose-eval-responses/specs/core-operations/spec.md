## ADDED Requirements

### Requirement: Single Response Annotation Pass
The eval response builder SHALL annotate the terminal response (status, err, ex fields) in a single pass, not multiple redundant rebuilds. (ARCH-021)

#### Scenario: Single pass produces same response
- **WHEN** an eval completes
- **THEN** the response shape is identical to the previous multi-pass approach