# Connection and Authentication

Auto-generated from docstrings. For narrative usage, see the [Guide](../index.md#Guide).

## Connection

```@docs
SurrealDB.connect
SurrealDB.close!
SurrealDB.status
SurrealDB.events
SurrealDB.SurrealClient
SurrealDB.AbstractConnection
SurrealDB.AbstractRemoteConnection
SurrealDB.RemoteConnection
SurrealDB.RemoteWSConnection
SurrealDB.RemoteHTTPConnection
SurrealDB.EmbeddedConnection
```

## Connection lifecycle and observability

```@docs
SurrealDB.ConnectionStatus
SurrealDB.STATUS_DISCONNECTED
SurrealDB.STATUS_CONNECTING
SurrealDB.STATUS_CONNECTED
SurrealDB.STATUS_RECONNECTING
SurrealDB.LifecycleEvent
SurrealDB.AbstractSurrealLogger
SurrealDB.NullLogger
SurrealDB.FnLogger
```

## Server version bounds

```@docs
SurrealDB.MINIMUM_SERVER_VERSION
SurrealDB.MAXIMUM_SERVER_VERSION
```

## Authentication

```@docs
SurrealDB.signin!
SurrealDB.signup!
SurrealDB.authenticate!
SurrealDB.invalidate!
SurrealDB.refresh!
SurrealDB.tokens
SurrealDB.Tokens
SurrealDB.RootAuth
SurrealDB.NamespaceAuth
SurrealDB.ScopedAuth
SurrealDB.JwtAuth
```

## Database scope

```@docs
SurrealDB.use!
SurrealDB.info
SurrealDB.version
SurrealDB.health
```

## Embedded mode

```@docs
SurrealDB.libsurreal_load!
```
