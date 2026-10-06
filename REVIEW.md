# Part 3 - contractor sync review

**Recommendation: request changes before deploying to the 40 field agents.**
Primary risks are lost photos, lost farm corrections, duplicate visits, and
structured data delayed behind photos or endless retries.

Source: [`review_source/sync_service_for_review.dart`](review_source/sync_service_for_review.dart),
The supplied code is preserved below a four-line explanatory header. Line
numbers refer to that copy. This
is a static review, not execution of the service. API, database and timer
implementations were not supplied: verify their guarantees rather than assuming
what they do. P0 = data loss/corruption blocker; P1 = delivery correctness or
availability blocker; P2 = operational and maintainability concern.

The supplied file also produces three analyzer errors under this project's
strict-casts setting at L63, L64 and L70: the dynamic update response is used as
an iterable and its fields are passed as strings without validation. This is
part of finding 22 below, not evidence that it fails under every Dart setup.
The reference folder is excluded from the implementation's normal analysis;
the supplied code below the header remains unchanged.

## P0 - data loss and corruption

1. **Photo dequeued before acknowledgment (L33-43).** A rural disconnect loses its pending-upload entry, so the timer cannot retry it; retain the item until a durable receipt and atomically acknowledge completion afterward.
2. **Device-clock last-write-wins (L69-76, L93).** B's clock being three hours behind can erase a valid hectare correction, while a fast clock can overwrite newer server data; use base revisions and atomic server conflict detection, preserve both proposals, and expose resolution state.
3. **Concurrent local edit can be overwritten (L64-76).** An agent editing after `getFarm()` but before `saveFarm()` can lose the new correction even with accurate clocks; condition replacement on the local version read, preserve dirty edits, and reconcile if it changed.
4. **Empty serializers in the supplied code (L95, L101).** Visits and farm updates send `{}` without IDs or domain data, so successful-looking calls can omit the agent's work; confirm whether these are illustrative stubs and require complete validated serialization before release.

## P1 - delivery correctness and availability

5. **No demonstrated end-to-end idempotency (L35-39, L52-58, L73).** A committed visit whose receipt is lost is submitted again, risking duplicate visits; carry stable persisted operation IDs for mutations and require server uniqueness plus replayed receipts. `photo.id` is not transmitted, and the shown visit serializer omits `visit.id`; verify any hidden client/server guarantees.
6. **No single-worker guard (L18, L22-33, L47-58).** Timer and connectivity triggers can read the same pending items and upload concurrently; coalesce calls into one active future, with durable claims/leases if multiple workers own the store. Setting `syncing = true` is not a lock.
7. **Unbounded immediate retry loop (L49-57).** A failed first visit can indefinitely block later visits and downloads while consuming battery/data; end the attempt on transient failure and schedule capped exponential backoff with jitter and server retry guidance.
8. **Permanent failures treated as transient (L40, L54).** Invalid credentials, rejected data or an already-committed duplicate can be swallowed or retried forever; classify failures, accept verified duplicate receipts, and retain rejected work with actionable state while allowing independent work to progress.
9. **Photos block structured data (L25-47).** Base64 expands each 3 MB image to roughly 4 MB, making 5-20 photos about 7-27 minutes at 50 KB/s before visits start; prioritize visits/notes and observations across the queue and recheck priority between photo chunks.
10. **Children sent before parent acknowledgment (L27-47).** Photos of a new visit can arrive before its visit exists remotely and be rejected or orphaned; require the parent's durable receipt before sending photos/observations.
11. **No resumable photo protocol (L29-39, L84-88).** Even after fixing premature dequeue, a disconnect at 60% restarts the whole image; use bounded chunks, stable photo/chunk identities, persisted checkpoints, and server validation of final assembly/integrity.
12. **Observation delivery is absent from the supplied model (L46-59, L98-102, L110-117).** Agronomists have no demonstrated path to receive crop observations; add an observation outbox path or explicitly show and test how complete visit serialization carries observations and notes.
13. **Farm upload depends on appearing in the download feed (L62-73).** A corrected field absent from `/farms/updates` has no upload path here and can remain unsent indefinitely; queue local farm mutations at capture and upload independently of downloads.
14. **Farm upload result not reconciled locally (L73).** No new server revision, receipt or cleared pending mutation is saved, risking repeated submissions and misleading state; transactionally persist acknowledgment and authoritative revision without overwriting subsequent local edits.
15. **Completed future assumed to mean durable delivery (L35-39, L52-58, L73, L105-107).** If the unseen client returns errors or asynchronous acceptance as normal values, visits may be removed without commitment; expose typed validated receipts and distinguish rejection, duplicate, conflict and pending acceptance before dequeue.
16. **Whole-file buffering and synchronous base64 conversion (L29-30).** Old devices hold image bytes plus expanded encoded data and may stall the calling isolate or exhaust memory, especially with overlapping workers; stream bounded binary chunks instead.
17. **File failures abort unrelated work (L29-34).** A missing/unreadable image throws outside the catch and prevents every queued visit from reaching head office; isolate item failures, retain an actionable photo error and continue independent structured work.
18. **No demonstrated deadlines/cancellation (L35, L52, L62, L73).** A request that never completes can stall sync on a half-open rural connection; verify bounded deadlines in `ApiClient`, provide worker cancellation, and retain uncertain operations for idempotent retry.

19. **Upload time substituted for capture time (L37, L84-88).** A photo taken hours offline is dated at upload using an unreliable device clock, misrepresenting the visit timeline; persist the original capture metadata once, preserve it across retries, and store server receipt time separately.

## P2 - operations, recovery and maintainability

20. **Incorrect `syncing` state (L23, L80).** Unhandled file/database/download failures leave it true, while overlap can set it false during another active run; encapsulate worker state, reset in `finally`, and expose explicit outcomes/progress through the repository/BLoC.
21. **No actionable diagnostics (L40-43, L54-56).** Agents/support cannot distinguish missing photos, invalid visits and weak signal; persist per-item error/attempt state and expose queue counts with redacted diagnostics, without logging photo contents.
22. **Untyped/unvalidated server changes (L62-70, L105-107, L116).** A malformed ID, timestamp or response shape can abort the remaining refresh after partial writes; validate typed change records, report/quarantine bad entries and define recoverable batch semantics.
23. **Download progress contract missing (L62-78).** No cursor, pagination, tombstone or atomic apply/cursor contract is visible, risking repeated large downloads, skipped changes after failure or stale deleted farms; agree server-issued cursors and transactionally apply each page with its cursor. Verify what the unseen client already supplies.
24. **Fixed timer and weak validation evidence (L7, L20-21).** Office Wi-Fi does not exercise silent commits or 4-8 hours offline, and fixed triggers can synchronize retry bursts; use lifecycle-aware, backoff-driven scheduling and require deterministic failure tests before release.

## Evidence requested before approval

- Failure tests: disconnect before photo commit; timeout after visit/chunk commit; duplicate receipt; restart with checkpoint; concurrent triggers; missing file; permanent rejection; interrupted download page.
- Conflict tests: A=12.5 versus B=13.0 from one base revision with B's clock three hours behind, both arrival orders, and a local edit during reconciliation I/O.
- Confirm serializers, API receipt/deadline/idempotency guarantees, transactional acknowledgment, and observation/standing-record upload routes.
