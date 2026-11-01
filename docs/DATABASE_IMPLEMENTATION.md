# Database backend implementation

`src/database/root.zig` is an independent, synchronous backend entry point. It
accepts an explicit `std.Io` and allocator; the caller owns the returned `Table`
and must call `deinit`. Execute it on a worker, never the UI thread. Cancellation
is the Zig Io operation's cancellation: `std.process.run` kills its child when
it unwinds. There is no separate cancel handle or deadline yet; the integrating
worker must provide a cancellable Io task. This has not been tested interactively.

## Implemented: SQLite

Requires the official `sqlite3` executable on PATH, supporting `-safe`,
`-readonly` and `-json` (tested with 3.51.2). `query` starts a fresh process per
query without a shell, and `sqlite.schema` queries `sqlite_schema` for object
names, kinds, owning table and CREATE SQL. Files are opened read-only; CLI safe
mode additionally disables unsafe CLI operations. Errors are classified and
stderr discarded to avoid leaking database contents or credentials. The CLI
output limit is enforced while collecting output; row and column counts are
checked after parsing. Exceeding any limit fails the entire result rather than
silently truncating it. SQLite JSON values are represented by `std.json.Value`,
including null, integer, float and string. Each row is an object keyed by its
column names. Use unique column aliases: duplicate names cannot be represented
reliably. Empty result sets carry no column metadata. BLOBs and invalid UTF-8
are not reliably represented by the CLI JSON mode and are not supported. More
than one result set is not supported. Large queries can still consume database
CPU before producing output; a timeout and paging are required before general
use. SQL is passed as a process argument and may be visible to local process
observers, so do not put credentials or sensitive literals into queries.
SQLite paths likewise may be visible. Process launch and database errors are
intentionally coarse; a privacy-aware diagnostic channel remains to be designed.

## Not implemented: remote providers

The tagged `Connection` type reserves MySQL, PostgreSQL and Convex variants;
`query` returns `UnsupportedBackend` for them. PostgreSQL and MySQL connection
configuration now distinguishes host, port, database, user, and an optional
credential reference. `remote.SecretProvider` defines a caller-supplied
resolver, validates the reference and rejects NUL bytes in its result; the
caller owns the returned allocation and must clear and free it. The resolver is
not yet invoked by an adapter. No secrets should be stored in connection
documents or logged. The application must provide a secure credential store.
No authenticated requests, remote schema discovery, connection pooling, TLS
configuration, or tests against remote servers are implemented.

For MySQL and PostgreSQL, a possible initial dependency is the corresponding
official `mysql` or `psql` executable, neither installed in the development
host. A production adapter needs streaming bounded parsers, unambiguous null,
binary and type handling, secure authentication (not passwords in argv), TLS
verification, cancellation, and schema discovery. MySQL's batch format escapes
special characters, while psql supports CSV; neither alone supplies a complete
typed protocol. Prefer a maintained native protocol library if it can meet
these requirements. See [MySQL client options](https://dev.mysql.com/doc/refman/8.4/en/mysql-command-options.html)
and [psql](https://www.postgresql.org/docs/current/app-psql.html).

Convex is not SQL. Its [deployment API](https://docs.convex.dev/deployment-api/overview)
exposes application-defined functions; [queries](https://docs.convex.dev/functions/query-functions)
use names such as `messages:list` with named arguments, and mutations/actions
are separate operations. The [CLI](https://docs.convex.dev/cli/overview) also
documents an administrative readonly inline query. A future adapter should use
an official supported authenticated client or deployment HTTP API, represent
function calls and their JSON values explicitly, and restrict the viewer to
queries unless the user explicitly chooses a mutation. It must not imply that
SQL or arbitrary table browsing is supported by a public deployment. Schema
inspection requires separately authorized, documented management capabilities.

Convex's [local development deployment](https://docs.convex.dev/cli/local-deployments)
runs a backend subprocess with persistent local state, and its [self-hosted
backend](https://docs.convex.dev/self-hosting) is a separate service. These do
not establish an in-process embedded library API. Local deployment is documented
as beta and intended for development; it should not be presented as embedded
SQLite or bundled silently into Zid.

## Application integration and remaining work

The shell includes a basic SQLite overlay with path and SQL inputs, schema query,
bounded results and a cancellable worker. It is a read-only viewer, not a full
database client: both fields are single-line inputs capped at 256 bytes, and
closing or cancelling waits for the worker to finish cancellation. The other
providers remain unavailable. Connection selection, secret resolution, richer
result and error presentation, and metadata refresh still need implementation.
Avoid writing query history, secret values, or raw diagnostics to logs. Provide
clear unsupported status for remote variants and the limitations above. A
production viewer needs actual column metadata for zero rows, binary-safe typed
values, paging and operation deadlines. Tests use a temporary local database and
never require secrets. No live remote integration tests have been run.

References: [SQLite CLI documentation](https://sqlite.org/cli.html),
[SQLite schema table](https://sqlite.org/schematab.html).
