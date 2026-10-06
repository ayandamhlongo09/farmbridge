# Offline sync decisions

## 1. Ordering and priority

- Save captured work locally before reporting capture success. Sync visit
  records (including notes), then observations, then photos. Observations and
  photos require acknowledgment of their parent visit first.
- Priority applies across all pending visits, with FIFO within each item type.
  With two pending visits, send both visit records, then their observations,
  then their photos. Visit 2 does not wait for Visit 1's images.
- Structured data is needed within minutes of connectivity returning. At
  approximately 50 KB/s, a 3 MB photo takes about a minute; 5-20 photos take
  about 5-20 minutes before retries. Sending images first would delay the
  information agronomists need.
- Upload photos in 128 KB chunks (roughly 2.6 seconds per chunk at that speed).
  Recheck structured-data priority between chunks. If another visit is captured
  during an upload, finish the current chunk, then send its eligible structured
  data before continuing photos. This chunk size is a starting trade-off between
  request overhead and retransmission cost.
- Persist the next unacknowledged chunk only after a durable server receipt.
  If signal drops at 60%, retain acknowledged progress and resend the interrupted
  chunk, rather than restarting the photo. The server must deduplicate repeated
  chunks by photo ID and index, verify matching content, and confirm complete
  assembly before the photo leaves the outbox.
- Stop the current attempt on a disconnect or timeout. A scheduler retries using
  capped exponential backoff and jitter; connectivity changes can trigger an
  attempt but do not guarantee a working connection. Keep pending work visible
  to the agent. Continuous structured-data capture could starve photos; measure
  that before introducing a fairness policy.

## 2. Conflict resolution

- Keep visit observations as independent facts. For mutable standing records,
  such as a field's hectare count, send each correction with its operation ID
  and the server revision the agent originally edited. Device timestamps are
  display metadata, not a reliable way to choose the winning correction.
- Suppose A and B both edit revision 7: A proposes 12.5 hectares and B proposes
  13.0, with B's clock three hours behind. If A syncs first, the server atomically
  accepts 12.5 as revision 8. B's correction still refers to revision 7, so the
  server preserves 13.0 as an unresolved conflict instead of overwriting 12.5.
  If B arrives first, the outcome is symmetric; arrival order does not establish
  which measurement is correct.
- B sees the conflict on submission. A sees it on the next download of server
  changes. Once both have refreshed, they see the provisional current value and
  both proposed corrections. Before refreshing, A may still see its earlier
  confirmed value. Offline local edits remain visible as pending work.
- An authorized reviewer chooses or corrects the value against the current
  server revision, retaining the proposals and resolution in audit history.
  A concurrent correction can cause another conflict. Do not average the values:
  there is no evidence that averaging would produce the correct hectare count.
- A durable conflict receipt confirms the proposal was delivered, not that the
  disagreement was resolved. Keep resolution state separate from upload state.
- Clock-based last-write-wins could wrongly discard B's correction because its
  clock is behind. Server-arrival last-write-wins avoids clock skew but still
  silently loses a competing correction. Revision checks detect the conflict;
  human review determines the appropriate value.

## 3. Duplicate prevention and offline operation IDs

- Generate a UUID v4 operation ID once at capture using cryptographically secure
  randomness. Devices generate IDs independently while offline; clocks and local
  counters are not used for uniqueness. The 122 random bits make collisions
  negligibly likely, not impossible. Persist the ID with the domain record and
  outbox entry in one transaction, and reuse it on every retry.
- Keep the operation's payload immutable. A later correction is a new operation
  with a new ID; retrying an uncertain upload is the same operation with the same
  ID. Two agents visiting the same farm still create distinct visit operations.
- The server enforces uniqueness on `(account, operation ID)` and atomically
  saves the domain mutation and its receipt. An existing ID with matching content
  returns the original result; an existing ID with different content is rejected
  and kept locally for investigation, never silently treated as delivered.
- If the server saves a visit but the confirmation is lost, the app retains the
  pending entry. Its next attempt reuses the original ID; the server returns the
  saved receipt without creating another visit. Remove pending work only after a
  durable accepted or matching duplicate receipt. A crash before local dequeue
  uses the same recovery path; retain parent acknowledgment when dequeuing.
- Photo chunks use stable photo IDs and chunk indexes, with matching content
  verified by the server. A lost chunk receipt causes that chunk to be replayed,
  not its ID to change or the local checkpoint to advance speculatively.
- Retain server deduplication records for the full supported offline/retry
  lifetime. This provides idempotent effects despite repeated delivery attempts;
  it does not claim exactly-once network delivery.

## 4. Local persistence and BLoC integration

- Use SQLite through `drift` / `drift_flutter`. Transactions save captured
  records and outbox entries together; relational queries handle dependencies,
  while typed queries, migrations and reactive reads support the offline app.
- Store immutable photo files using `path_provider`, with paths, hashes and
  checkpoints in SQLite. Reconcile interrupted file writes on startup; retain
  files until confirmed upload and the retention policy permits cleanup.
- `sqflite` is viable, but needs more manual mapping and reactive plumbing.
  Reject `shared_preferences` for critical records because durable writes are
  not guaranteed; prefer SQL over `hive` for related records and queue queries.
- `VisitBloc` sends capture events to a repository that saves locally.
  `SyncBloc` requests sync and observes repository progress/conflict streams.
  BLoCs own presentation state; the repository and queue own persistent work.
  Use `BlocBuilder` for rendering and `BlocListener` for notifications. Keep
  local capture, remote delivery and conflict resolution distinct in the UI.
- These describe Flutter integration; Part 2 remains pure Dart with fake storage
  and network interfaces, without a database or UI implementation.

## 5. Least certain trade-off

- Human resolution preserves competing hectare corrections, but delays an
  authoritative value and creates review work. A reasonable alternative is
  server-arrival last-write-wins with complete audit history and undo: it
  converges automatically, is simpler, and may suit low-risk corrections.
- I prefer explicit resolution because hectare counts affect downstream
  decisions. Validate conflict frequency, business impact and reviewer turnaround
  with agronomists before committing to that operational cost.

## Scope and AI assistance

- AI helped clarify BLoC integration and its separation from the repository
  and sync queue, and assisted with drafting the design and implementation.
  During review, the design was refined to prioritize structured data across
  visits, preserve stable retry IDs
