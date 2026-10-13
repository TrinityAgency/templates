# AGE and Cypher

## Bind every value

The starter's `Database.execute_cypher(graph_name, cypher)` (`api/app/services/database.py`) wraps raw text in `$cypher$ … $cypher$`, parses `RETURN` to guess the columns, and sets no timeout. Add a bound variant beside it and move callers over:

```python
import re
_IDENT = re.compile(r"[a-z_][a-z0-9_]*")

async def execute_cypher_params(self, graph_name: str, cypher: str, params: dict | None,
                                columns: list[str], timeout_ms: int = 30000) -> list[dict]:
    if not _IDENT.fullmatch(graph_name):
        raise ValueError(f"invalid graph name {graph_name!r}")
    if not columns or not all(_IDENT.fullmatch(c) for c in columns):
        raise ValueError(f"invalid column list {columns!r}")
    col_def = ", ".join(f"{c} agtype" for c in columns)
    arg = ", %s" if params is not None else ""
    sql = (f"SELECT * FROM ag_catalog.cypher('{graph_name}', $cypher$ {cypher} $cypher${arg}) "
           f"AS result({col_def})")
    async with self.connection() as conn:
        async with conn.cursor(row_factory=dict_row) as cur:
            await cur.execute("LOAD 'age'")
            await cur.execute("SET LOCAL search_path = ag_catalog, public")
            await cur.execute(f"SET LOCAL statement_timeout = {int(timeout_ms)}")
            await cur.execute(sql, (json.dumps(params),) if params is not None else None)
            rows = await cur.fetchall()
    return [{c: self._parse_agtype(row.get(c)) for c in columns} for row in rows]
```

Call it like this:

```python
await db.execute_cypher_params(
    graph_name,
    "MATCH (n) WHERE toLower(n.name) CONTAINS toLower($q) RETURN id(n), n.name LIMIT $lim",
    {"q": text, "lim": 10},
    ["id", "name"],
)
```

- `params` reaches AGE as **one agtype map**, `cypher()`'s third argument, through psycopg 3's server-side binding (the starter pins `psycopg==3.2.4`). Quotes, backslashes, `$$` and `$cypher$` inside a value stay literals.
- The Cypher text itself must contain no `%`, because psycopg parses `%s`.
- The graph name cannot be a parameter. Validate it against `[a-z_][a-z0-9_]*` and inline it.
- The caller names the columns, so nothing parses `RETURN`.
- `graph.py`'s `_serialize_value` escapes only `'` and builds literals. Retire it as callers move over. Never build Cypher with an f-string around a value.

## Dialect

- A pattern predicate in `WHERE` fails (`WHERE NOT (n)--()`). Use `MATCH` / `OPTIONAL MATCH`, or SQL.
- `ORDER BY <aggregate alias>` fails ("could not find rte"). `type(r)` inside a grouped query can fail too.
- `ORDER BY CASE … END, n.name LIMIT $lim` works. Rank in Cypher, before the limit.
- `label(n)` returns one label; `labels(n)` returns a list. `coalesce(n.description, '')` guards a missing property.
- `toLower()` on a non-string property raises (`unsupported argument agtype`).
- A graph name needs at least 3 characters.

## Read with SQL when Cypher is slow

AGE stores each graph as tables `<graph>._ag_label_vertex` / `<graph>._ag_label_edge`, with one child table per label. A census in SQL takes milliseconds where the equivalent Cypher degree count can take minutes:

```sql
SET statement_timeout = '20s';
SET search_path = ag_catalog, public;   -- the graphid = graphid operator lives here
SELECT count(*) FROM project_x._ag_label_vertex v
 WHERE NOT EXISTS (SELECT 1 FROM project_x._ag_label_edge e
                    WHERE e.start_id = v.id OR e.end_id = v.id);
```

Probe for vertices that will break `toLower()` before a deploy. Read `id, properties::text` from `project_x._ag_label_vertex` in batches (`ORDER BY id LIMIT 1000` with a keyset on `id`), parse each `properties` as JSON client-side, and flag any vertex whose `name` or `description` is present but not a string.

When you probe with Cypher, query one graph at a time with a `LIMIT`, watch `pg_stat_activity`, and `pg_cancel_backend()` a runaway query.
