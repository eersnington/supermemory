# CLI Improvement Recommendations

These recommendations are for the released `supermemory-server` CLI. The self-hosted server source is not available in this repository, so these are upstream CLI/product changes, not local code changes.

## Keep The Default Install Embedded

Do not require users to run Postgres for `supermemory local`.

The default should stay:

```txt
supermemory local -> embedded PGlite + pgvector + local embeddings
```

Changing from `memory://` PGlite to persistent PGlite storage would not inherently require a separate Postgres install. PGlite is still embedded. The hard part is preserving the current encrypted local-storage/snapshot behavior while reducing memory pressure.

## Add Storage Modes

Expose storage as an explicit CLI choice:

| Mode | Install Impact | Purpose |
| :--- | :--- | :--- |
| `embedded` | none | Default zero-config local mode using embedded PGlite/pgvector |
| `embedded-persistent` | none | Embedded PGlite with persistent data files instead of full memory snapshot, if encryption can be preserved |
| `postgres` | external Postgres required | Advanced mode for users who already run Postgres/pgvector or want lower server-process RSS |

Example CLI shape:

```sh
supermemory local --storage embedded
supermemory local --storage embedded-persistent
supermemory local --storage postgres --database-url postgres://localhost:5432/supermemory
```

The CLI should validate `pgvector` for Postgres mode and give a direct recovery command when it is missing.

## Make Startup Warmup Official

The binary patch shows that moving embedding warmup after HTTP readiness improves startup UX without changing model, batch, pool, ingest concurrency, or memory limit defaults.

Expose that as a supported option:

```sh
supermemory local --embedding-prewarm background
supermemory local --embedding-prewarm blocking
supermemory local --embedding-prewarm on-demand
```

Recommended default: `background`.

This should preserve the ingest baseline behavior by recording the ingest memory baseline after background warmup completes.

## Add Diagnostics

Add a diagnostic command that explains where memory is going:

```sh
supermemory local doctor --memory
```

It should report:

- server version and embedded Bun version
- storage mode: `embedded`, `embedded-persistent`, or `postgres`
- PGlite mode and pgvector availability
- embedding model, backend, pool size, batch size, and idle timeout
- process-tree RSS, not only parent-process RSS
- phase timings for DB ready, HTTP ready, embedding warmup, first search, and snapshot flush

## Add A Repro Benchmark Command

The CLI should include a small built-in benchmark that mirrors the validation here:

```sh
supermemory local bench startup --runs 5 --ready-settle 2000 --post-search-idle 35000
```

It should fail or warn when:

- HTTP readiness regresses materially
- first search after settle regresses materially
- local embedding warmup happens more than once
- process-tree RSS grows unexpectedly

## Avoid These As Defaults

Do not make these mandatory for `supermemory local`:

- external Postgres
- Docker
- a smaller embedding model
- disabled embedding warmup

Those are useful advanced options, but they change local setup complexity or behavior. The default CLI should stay one-command and embedded.
