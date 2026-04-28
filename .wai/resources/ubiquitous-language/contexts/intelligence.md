# Intelligence Context

Scope: code-intelligence operations — completions, documentation lookup,
and symbol resolution. These are stateless read-only queries against the
Julia runtime.

---

## Entities & Value Objects

| Term | Definition |
|------|-----------|
| **Completion** | A single tab-completion candidate: a string (the completed symbol) plus type metadata. |
| **Completions Array** | The list of `Completion` candidates returned for a given code + cursor position. May be empty. |
| **Cursor Position** (`pos`) | Byte index into the code string (0-indexed). The position at which completions are requested. |
| **Code String** | The Julia source fragment for which completions or documentation are requested. |
| **Symbol** | A Julia identifier string to look up (e.g., `"Base.map"`, `"sin"`). |
| **Documentation** (`doc`) | The docstring associated with a symbol. May be an empty string if undocumented. |
| **Methods** | Array of method signature strings for a callable symbol. Empty for non-functions. |
| **Found Flag** (`found`) | Boolean in the `lookup` response: `true` if the symbol exists in the specified module; `false` otherwise. |
| **Module Context** | The `Module` in which completions and lookups are performed. Defaults to the session's module or `Main` if no session is specified. |
| **REPL Completions Engine** | Julia's built-in completion system (`REPL.completions`). Used internally by `CompleteMiddleware`. |

## Operations (verbs)

| Term | Definition |
|------|-----------|
| **Complete** | Return all completions at `pos` in `code` within the given module context. |
| **Lookup** | Resolve `symbol` in the module context; return docstring and method signatures. |
| **Resolve Module** | Convert a dotted module name string to a `Module` object. Same as in the Evaluation context. |
| **Bound Check** | Validate `pos` is within `[0, length(code)]`. Out-of-bounds returns empty completions — not an error. |
| **Extract Docstring** | Retrieve the documentation string bound to a symbol. |
| **Introspect Methods** | Get method signatures and arity for a callable symbol. |

## Request Fields

### `complete`

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `code` | string | yes | Source code fragment |
| `pos` | integer | yes | Cursor byte offset (0-indexed) |
| `session` | string | no | Session for namespace context |
| `module` | string | no | Dotted module path override |

### `lookup`

| Field | Type | Required | Meaning |
|-------|------|----------|---------|
| `symbol` | string | yes | Identifier to look up |
| `session` | string | no | Session for namespace context |
| `module` | string | no | Dotted module path override |

## Response Shapes

### `complete` response

```json
{
  "id": "…",
  "completions": ["sin", "sinc", "sind"],
  "status": ["done"]
}
```

### `lookup` response (found)

```json
{
  "id": "…",
  "found": true,
  "doc": "sin(x)\n\nCompute sin of x in radians.",
  "methods": ["sin(x::Float64)", "sin(x::Real)"],
  "status": ["done"]
}
```

### `lookup` response (not found)

```json
{
  "id": "…",
  "found": false,
  "status": ["done"]
}
```

## Rules

- **Out-of-bounds position** — `pos < 0` or `pos > length(code)` returns empty completions gracefully, never an error.
- **Not found is not an error** — `found: false` uses `status: ["done"]`, not `status: ["done","error"]`.
- **Read-only** — neither `complete` nor `lookup` modifies session state.
