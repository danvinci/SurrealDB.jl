# Debugging

RPC traces emit on Julia's `@debug` channel.
Enable with `JULIA_DEBUG=SurrealDB`:

```
┌ Debug: SurrealDB ws RPC → rid=2 method=use params=Any["test", "test"]
┌ Debug: SurrealDB ws RPC ← rid=2 has_error=false
```

Traces cover both WebSocket and HTTP transports.

## Lifecycle events

For connection-lifecycle observability without the `@debug` flood, subscribe to lifecycle events instead — see [Reconnect and lifecycle](reconnect.md).

## Embedded mode

The embedded backend wraps `libsurreal` via FFI.
Errors surface as [`EmbeddedFFIError`](@ref) with `.op` (the failing FFI call) and `.message` (the underlying error).
