# How-to: Manage Persistent Sessions

By default, REPLy evaluates every `eval` request in a fresh, ephemeral session. If you want to maintain state across multiple requests (e.g., for an editor integration where variables persist between executions), you must use **Named Sessions**.

## 1. Create the Initial Named Session (Server-Side)

Currently, creating a completely new named session must be done from Julia when instantiating the server.

```julia
using REPLy
using REPLy: SessionManager, create_named_session!

# 1. Create a session manager
manager = SessionManager()

# 2. Register a persistent session named "main"
create_named_session!(manager, "main")

# 3. Start the server using this manager
server = REPLy.serve(manager=manager, port=5555)
wait(Condition())
```

## 2. Target a Session via RPC

Once the session exists, clients can evaluate code in it by adding the `"session"` key to their requests:

```json
{"op": "eval", "id": "req-1", "session": "main", "code": "x = 42"}
```

Subsequent requests using the same `"session"` string will see the previously defined variables:

```json
{"op": "eval", "id": "req-2", "session": "main", "code": "x + 10"}
```

## 3. List Active Sessions

Clients can discover available sessions using the `ls-sessions` operation. This is useful for editors that need to show a session picker.

```bash
printf '%s\n' '{"op":"ls-sessions","id":"ls-1"}' | nc 127.0.0.1 5555
```

The response will look like:

```json
{"id":"ls-1","sessions":[{"name":"main","created-at":1713500000.0}]}
{"id":"ls-1","status":["done"]}
```

## 4. Clone a Session

Instead of creating new sessions from the server side, clients can clone an existing session. This creates a new anonymous module that copies all bindings from the source session, ensuring mutations in the clone do not affect the original.

```json
{"op": "clone-session", "id": "clone-1", "source": "main", "name": "experiment"}
```

If successful, the new session `"experiment"` is ready for use:

```json
{"id": "clone-1", "name": "experiment"}
{"id": "clone-1", "status": ["done"]}
```

## 5. Close a Session

When a session is no longer needed, close it to free resources:

```json
{"op": "close-session", "id": "close-1", "name": "experiment"}
```
