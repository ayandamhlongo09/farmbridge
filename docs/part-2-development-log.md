# Outbox implementation: decisions and development record

This record summarizes the actual implementation stages and their reasoning.
Git commits remain the source of working history. The queue is pure Dart;
Flutter/BLoC integration and production persistence are design proposals, not
implemented adapters. See [sync diagrams](sync-flow.md) for the execution flows.

## Decisions

| Decision | Reason and limit |
| --- | --- |
| Inject `OutboxStore` and `Uplink` interfaces | Exercise failures without a real database or network; production adapters must provide the documented durability and idempotency guarantees. |
| Immutable item IDs and record payloads | Retry the same operation without changing its meaning; caller generates IDs, and photo file immutability is an adapter responsibility. |
| Visits before observations before photos | Deliver structured data promptly across all pending visits; FIFO applies within each priority. Continuous capture can delay photos. |
| Require parent visit acknowledgment | Avoid sending observations/photos before their visit exists remotely; acknowledged parent IDs survive dequeue. |
| Acknowledge only after a successful receipt | Retain uncertain work; both accepted and matching duplicate receipts mean delivery. Server must reject ID/content mismatches. |
| Return `retryLater` on timeout/disconnect | Avoid an immediate infinite retry loop; a separate scheduler decides when to try again. Unexpected errors propagate. |
| Persist next unacknowledged chunk | Resume at chunk N, replaying it safely if its acknowledgment was lost. Storage failure can cause replay, not speculative progress. |
| Re-select work after each chunk | Newly captured structured data can take priority at the next boundary. No cancellation of the current chunk is implemented. |
| Share the active sync future | One queue instance runs one worker; multiple instances/processes still require coordination such as a durable lease. Clear active state on success or failure. |

## Implementation stages

| Commit | Work completed | Verification at that stage |
| --- | --- | --- |
| `35594c5` | Dart package, test dependency, analyzer settings and generated-file exclusions. | Dependency resolution succeeded. |
| `c93b94c` | Visit, observation and photo models; pending progress; storage/uplink contracts; receipts and outcomes. | Static analysis passed. |
| `796bad0` | Enqueue/drain worker, structured-data priority, FIFO, parent dependencies and blocked outcome. Photo transfer was explicitly unsupported at this intermediate stage. | 4 behavioral tests passed; analysis clean. |
| `f22a9a6` | Timeout/disconnect outcomes, retained pending work and fake server commitments/duplicate receipts. | 7 tests passed; analysis clean. |
| `97a344a` | Photo chunk delivery, checkpoints, completion acknowledgment and priority rechecks. | 12 tests passed; analysis clean. |
| `bdea7bb` | Coalesced concurrent calls with completion/failure cleanup. | New concurrency regression failed against the previous worker, then all 13 tests passed with the fix; analysis clean. |
| `6ff87f0` | Component, worker and recovery diagrams. | Compared flows with implementation; later GitHub rendering exposed sequence-label syntax errors. |
| `6612d2d` | Replaced semicolons in sequence labels with commas. | All four diagrams passed local Mermaid parsing. |

## Behavioral evidence

The tests in [`../test/outbox_queue_test.dart`](../test/outbox_queue_test.dart)
cover priority/FIFO, parent waiting, independent work despite an orphan,
empty/repeated sync, silent-commit timeout without duplicate visits, parent
failure/retry, unexpected errors, structured data before photos, resume after
worker reconstruction, lost final chunk receipt, priority between chunks,
checkpoint failure/replay, and concurrent triggers submitting once.

The fake server separates upload attempts from committed operations, so tests can
assert multiple attempts with one effect. Reconstructing the worker over the same
in-memory store demonstrates stored progress independent of the worker; it does
not demonstrate app-process recovery from disk.

Last code verification: 13 tests passed and `dart analyze` reported no issues.
Implementation plus tests: 389 lines at completion of the worker stage.

```sh
dart pub get
dart analyze
dart test
```

## Remaining production work

- Transactional durable store and restart recovery, including parent receipts.
- Real uplink with stable IDs, content verification, durable duplicate receipts,
  request deadlines and confirmed final photo assembly.
- Actual bounded file reads, chunk-size calculation and file lifecycle handling.
- UUID generation at capture, server revisions/conflict handling and downloads.
- Retry scheduling/backoff, authentication, permanent-error recovery and leases
  for multiple workers; presentation through repository streams and BLoC.

These items are not claimed as verified by the fakes. No Flutter UI, live network
or real database has been added. AI assisted the implementation, tests and this
record; the final disclosure in `DECISIONS.md` should reflect that scope.
