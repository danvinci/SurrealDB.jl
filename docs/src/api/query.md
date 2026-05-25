# Query, Live, Transactions

Auto-generated from docstrings. For narrative usage, see the [Guide](../index.md#Guide).

## Query and CRUD

```@docs
SurrealDB.query
SurrealDB.query_verbose
SurrealDB.QueryStatement
SurrealDB.isok
SurrealDB.iserr
SurrealDB.query_table
SurrealDB.query_one
SurrealDB.create
SurrealDB.select
SurrealDB.update
SurrealDB.delete
SurrealDB.insert
SurrealDB.upsert
SurrealDB.merge
SurrealDB.relate
SurrealDB.insert_relation
SurrealDB.patch
SurrealDB.patch_add
SurrealDB.patch_remove
SurrealDB.patch_replace
SurrealDB.run
SurrealDB.ping
SurrealDB.let!
SurrealDB.unset!
```

## Live queries

```@docs
SurrealDB.live
SurrealDB.kill!
SurrealDB.LiveSubscription
SurrealDB.LiveNotification
```

## Transactions and sessions

```@docs
SurrealDB.begin!
SurrealDB.commit!
SurrealDB.cancel!
SurrealDB.attach!
SurrealDB.detach!
SurrealDB.sessions
SurrealDB.SurrealSession
```

## Import / Export

```@docs
SurrealDB.export_db
SurrealDB.import_db
```
