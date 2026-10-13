---
name: graph-engineering
description: Changing the knowledge graph itself — AGE graphs, the Qdrant projection, chunking, embeddings, search fusion, retrieval gates, Cypher safety. Use when editing the context-graph API services, re-embedding, or measuring recall. For USING the graph, use context-graph.
---

# Graph Engineering

The maintainer's skill for the `context-graph` starter (Postgres 16 + Apache AGE, Qdrant, Redis, a FastAPI service in `api/`). The starter's own `context-graph` skill covers *using* the graph; this one covers *changing* it without degrading retrieval unseen.

## First principle

**Source rows are the truth; the vector store is a projection.** In the starter the truth is `public.documents.raw_content` and the vertices of each project's AGE graph (`project_<slug>`, created by `create_project()` in `db/init/001_init.sql`). Qdrant's `project_<slug>_chunks` collections (`api/app/services/vector.py`) are derived from them.

- Never repair vectors in place. Rebuild the projection whole, gate it, then flip.
- Never hand-write a point.
- Never trust a count that wasn't taken from the source rows.

## The loop: rebuild → gate → flip

For any change that alters what lands in Qdrant (cleaner, chunker, embedding model, payload schema):

1. **Rebuild** into a *new* collection (e.g. `project_<slug>_chunks_v2`) from `documents.raw_content`. Leave the live one untouched.
2. **Gate** the candidate against the live collection on a fixed query set (`references/retrieval.md`). It must be at least as good, and every invariant must hold.
3. **Flip** by re-pointing a Qdrant collection **alias** at the candidate. Rollback = re-point it back. Keep the old collection until a watch period is over.

**The starter does not implement this loop yet.** It has no aliases (the collection name is hard-coded in `VectorService._collection_name`), no candidate build, and no gate. `POST /api/v1/projects/{slug}/documents/{id}/process` re-chunks one document *in place* (it deletes that document's points, then writes new ones). That is fine for one document under the current settings. It is not a migration path for the corpus. Before you change chunking or embeddings for real data, add aliases and a gate.

Snapshots (`/api/v1/projects/{slug}/snapshots`, `services/snapshot.py`) export and restore the **graph only**. They do not cover Qdrant. The vectors are recoverable only by rebuilding from `documents`, which is one more reason to keep that path working.

## Doctrine

1. **Production is read-only without a gate.** Build into a new name; only a passing gate record unlocks the flip.
2. **Count tokens with the embedding model's own tokenizer.** The starter chunks with tiktoken `cl100k_base` (`services/chunking.py`), which matches OpenAI `text-embedding-3-*` (`config.py`: `embedding_model`, `embedding_dimensions`). If you switch embedders (e.g. an e5-family model with a 512-token window), switch the tokenizer too. A chunker counting with the wrong tokenizer silently overruns the model's window, and the model truncates.
3. **Clean before you chunk, and version the cleaner.** Base64 runs and data URIs are dense in rare tokens. They win short keyword queries and push real passages out of the top results. Replace them with a marker before chunking, and bump a `CLEAN_VERSION` whenever the cleaner's output changes, so a build records what it was cleaned with. The starter has no cleaner yet.
4. **Every value reaches AGE as a bound parameter.** This means `cypher()`'s third argument, one agtype map, sent through psycopg's server-side binding. The starter builds Cypher with f-strings throughout (`services/graph.py`, `services/search.py`), and the graph leg of search interpolates the raw query. An apostrophe breaks it, and it is an injection path. See `references/age-cypher.md`.
5. **Bound every Cypher statement with a timeout.** `Database.execute_cypher` sets none, and neither does `POST /api/v1/projects/{slug}/query/cypher`. One degree count on a large graph can run for minutes. Use `SET LOCAL statement_timeout` inside the transaction.
6. **Fuse ranks, never raw scores.** Use Reciprocal Rank Fusion, `score = Σ 1/(60 + rank)`. The starter's `SearchService.search` concatenates both legs and sorts by raw score. Every graph hit carries a flat `1.0`, so it outranks every cosine. Rank the graph leg by match class instead (exact name, prefix, name contains, description contains). An entity found by both legs is **one** hit; key it by (project, entity id).
7. **A degraded leg is reported, never silently empty.** Both search legs `except Exception: return []`. A dead embedder or a Cypher error then looks like "no results". Report which legs degraded (e.g. `stats.degraded: ["graph"]`). Also make an unconfigured embedder fail loudly. Without `OPENAI_API_KEY`, `EmbeddingService` returns **zero vectors** with only a log warning, and they are written into Qdrant as if they were real.
8. **Allow-list, never deny-list, by project slug.** If you add entity vectors or any per-project projection, name the included projects by slug (never by AGE graph name), and refuse an unknown name. A sync that is handed a graph name instead of a slug can treat every point in that project as stale and delete it.
9. **Every enumerator resolves aliases.** Once you flip via aliases, listing collections returns physical names only. Code that matches collection names by pattern then sees nothing, and deleting by an alias name is a silent no-op in Qdrant. Resolve aliases first.
10. **A gate is proven four ways:** green when the candidate is right; red for each planted defect; red when the metric drops; and never green on nothing (no queries, no collections, no score line).
11. **Instruction prefixes go on queries only.** Instruction-tuned embedders such as e5 expect a prefix (`Instruct: …\nQuery: `) on the **query**, not on the documents. Put it in exactly one place, a dedicated `embed_query`. The starter's OpenAI model needs no prefix and has one `embed_text` for both.
12. **A write path reads the target collection's config.** If a collection has optional vectors (e.g. a sparse lexical vector), each writer decides what to write by inspecting the collection it writes to, never from its own intent. Qdrant accepts a point that lacks an optional vector without complaint.

## Traps

- **Non-string `name` / `description` on a vertex.** `toLower()` raises on a non-string agtype, so the graph leg fails on every search in that project until the data is fixed. Probe for it before deploying (`references/age-cypher.md`).
- **AGE's dialect.** A pattern predicate in `WHERE` fails. `ORDER BY` an aggregate alias fails. A graph name needs at least 3 characters. The `graphid = graphid` operator needs `search_path = ag_catalog`.
- **`documents.py` ignores `CHUNK_SIZE`.** It constructs `ChunkingService(chunk_size=500, chunk_overlap=50)` directly instead of reading `Settings.chunk_size` / `chunk_overlap`.
- **Raw Cypher through `/query/cypher`** is guarded only by a keyword deny-list (`has_dangerous_keywords`). It blocks writes, but nothing bounds reads.
- **Logs and snapshots hold your corpus in plaintext.** Restrict their permissions, and don't dump them whole into a shared session.

## References

- `references/age-cypher.md`: bound Cypher, the dialect, reading AGE's tables with SQL.
- `references/retrieval.md`: cleaning, chunking, fusion, and how to build and prove a retrieval gate.
