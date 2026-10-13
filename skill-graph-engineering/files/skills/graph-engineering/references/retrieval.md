# Retrieval

## What the starter does today

| Stage | Where | Behaviour |
|---|---|---|
| Chunk | `api/app/services/chunking.py` | Paragraph → sentence → forced token split, tiktoken `cl100k_base`, 500 tokens, 50-token overlap prepended from the previous chunk. No cleaning. |
| Embed | `api/app/services/embedding.py` | OpenAI `text-embedding-3-small`, 1536 dims. Zero vectors when no key is set. |
| Store | `api/app/routers/documents.py` → `vector.upsert_chunks` | `public.chunks` row + Qdrant point with the same UUID, in `project_<slug>_chunks`. |
| Search | `api/app/services/search.py` | Vector leg (cosine) + graph leg (`CONTAINS` on name/description, flat score 1.0), merged by sorting on raw score. |

## Cleaning

- Replace data URIs and any long run (≥ ~120 chars) of `[A-Za-z0-9+/=_-]` that mixes letters and digits with a marker such as `[binary data removed]`.
- Compute chunk offsets against the **cleaned** text, and anchor any gate span against it too.
- Clean entity descriptions with the same function if you embed entities.
- Version the cleaner (`CLEAN_VERSION`) and record it on each build.

## Chunking

- Count with the embedder's tokenizer, and re-count every final passage. If any passage exceeds the model's window (minus a margin), re-pack that document with a smaller target, and fail loudly after a few attempts.
- Prefer structural splits first (Markdown headings, blank lines), then sentences, then words. Never split inside a fenced code block.
- Overlap with whole trailing sentences, not with a decoded token slice. A token slice can start mid-word.
- A `header` variant that prefixes `<filename> › <h1> › <h2>` often helps short queries. Build both and let the gate choose.

## Fusion

- RRF: `score(hit) = Σ_legs 1/(60 + rank_in_leg)`. Raw cosine, BM25 and flat graph scores are not comparable. Rank inside each leg, then fuse.
- Key a hit by (project, id). When both legs find an entity, it is one hit with both sources recorded.
- When searching several projects (the starter's `/api/v1/search` fan-out), build one global vector ranking and one global graph ranking, then fuse once. If you add a lexical (BM25 / sparse) leg, rank it **per project**. IDF is per collection, so raw BM25 scores from different collections cannot be pooled.
- Keep each leg's raw score on the hit for debugging, but never sort by it.
- If entities crowd out chunks, an entity *quota* (at most `ceil(share · n)` entities in any top-n, deferring the rest rather than dropping them) can help. Gate its price: measure entity recall with the quota on and off.

## The gate

A gate compares a **candidate** collection against the **baseline** (live) collection on fixed queries, and writes a pass record only when every condition holds.

**Anchors.** Each query's target is a span of a source document: `{document_id, start, end, sha256}`, where `sha256 = sha256(clean(raw_content)[start:end])`. Before measuring, a read-only check confirms every anchor still hashes the same.

**Relevance.** A hit is relevant when it is a chunk of the anchor's document whose span overlaps the anchor by at least min(200 chars, 50% of the anchor).

**Query sets.**
- **Q**: the main set, around 100 queries. If they were written by reading passages, they share vocabulary with their targets. Name that bias.
- **H**: held out. Write them blind, from filenames and domain vocabulary, then locate each answer afterwards. They guard against Q's bias.
- **E**: entity queries anchored by vertex (label + name). Use them when entities are in the projection.

**Metrics.** Hybrid recall@5 (the decider), doc@5 (any chunk of the right document), recall@10, MRR@10, plus paired new hits and new misses by query id. With 100 queries, a tolerance of 0.02 is two queries. A one-query difference is noise.

**Invariants**, judged against the candidate's own build manifest:
- No passage over the model's window, no binary passage, and no empty passage.
- Each project's point count equals the manifest's chunk (+ entity) count.
- No points for a project outside the allow-list.
- No degraded leg anywhere in the run.

**Junk probe.** Around 20 short keyword queries. No empty or binary hit may appear in any top 5 that the projection controls.

**Never vacuously green.**
- Delete a stale pass record before running.
- Validate every query before measuring anything.
- Refuse the run when Q or H is too small, or when the baseline's own score is at or below the tolerance (that floor would pass anything).
- Make a degraded leg red-line the run rather than score as a miss.

**Prove the gate four ways** before trusting it:
1. It passes a known-good candidate.
2. It fails once for each planted defect (an over-long passage, a binary passage, a missing point, a foreign project).
3. It fails when recall drops.
4. It refuses when there are no anchors, no collections, or no score line.
