# Outbox sync flow

These diagrams describe the implemented pure-Dart queue. Storage and uplink are
interfaces, exercised by in-memory fakes in tests; production adapters are outside
this implementation.

## Components

```mermaid
flowchart TD
    Caller[Caller] -->|enqueue item| Queue[OutboxQueue]
    Caller -->|sync request| Queue
    Visit[VisitRecord: priority 0] --> Item[OutboxItem]
    Observation[Observation: priority 1] --> Item
    Photo[PhotoUpload: priority 2] --> Item
    Item -->|accepted by enqueue| Queue
    Queue -->|save, select, checkpoint, acknowledge| Store[OutboxStore interface]
    Queue -->|submit record or upload chunk| Uplink[Uplink interface]
    Store -. implemented by tests .-> Memory[MemoryStore]
    Uplink -. implemented by tests .-> Fake[FakeUplink]
```

IDs are supplied by the caller. PendingItem stores the item and the next
unacknowledged photo chunk. Parent visit acknowledgments remain available after
visit records leave the queue.

## Worker and priority selection

```mermaid
flowchart TD
    Start["sync()"] --> Active{Worker already active?}
    Active -->|Yes| Shared[Return existing future]
    Active -->|No| Create[Start and remember worker future]
    Create --> Read[Read pending snapshot in FIFO order]
    Read --> Empty{Queue empty?}
    Empty -->|Yes| Drained[Return drained]
    Empty -->|No| Select[Select lowest priority number among eligible items]
    Select --> Eligible{Eligible item found?}
    Eligible -->|No| Blocked[Return blocked]
    Eligible -->|Yes| Type{Photo?}
    Type -->|No| Submit[Submit visit or observation]
    Submit -->|Durable accepted or duplicate receipt| Ack[Dequeue and retain parent acknowledgment]
    Ack --> Read
    Type -->|Yes| Validate[Validate stored checkpoint]
    Validate -->|Invalid| Error[Propagate error and retain pending work]
    Validate -->|Valid| Remaining{Unacknowledged chunk remains?}
    Remaining -->|Yes| Chunk[Upload next chunk]
    Chunk -->|Durable accepted or duplicate receipt| Save[Save next chunk checkpoint]
    Save --> Complete{Final chunk acknowledged?}
    Complete -->|No| Read
    Complete -->|Yes| PhotoAck[Dequeue photo]
    Remaining -->|No| PhotoAck
    PhotoAck --> Read
    Submit -->|Disconnect or timeout| Retry[Return retryLater]
    Chunk -->|Disconnect or timeout| Retry
    Submit -->|Unexpected error| Error
    Chunk -->|Unexpected error| Error
    Save -->|Storage error| Error
    Ack -->|Storage error| Error
    PhotoAck -->|Storage error| Error
    Drained --> Clear[Clear active future on completion]
    Blocked --> Clear
    Retry --> Clear
    Error --> Clear
```

Eligibility requires an acknowledged parent for observations and photos. Equal
priorities preserve FIFO. Selection is repeated after each photo chunk, allowing
new structured data to preempt photos. Errors from storage reads also propagate;
all worker completion paths clear the active future. A scheduler, not this queue,
chooses when to retry. Coalescing applies to one queue instance.

## Lost visit confirmation

```mermaid
sequenceDiagram
    participant Caller
    participant Queue as OutboxQueue
    participant Store as OutboxStore
    participant Server as Uplink / fake server
    Caller->>Queue: sync()
    Queue->>Store: pending()
    Store-->>Queue: Visit with stable operation ID
    Queue->>Server: submit same operation ID and content
    Server->>Server: Commit operation once
    Server--xQueue: Confirmation lost; TimeoutException
    Queue-->>Caller: retryLater
    Note over Store: Visit remains pending
    Caller->>Queue: sync() later
    Queue->>Store: pending()
    Store-->>Queue: Same visit and operation ID
    Queue->>Server: Retry same operation
    Server-->>Queue: duplicate receipt
    Queue->>Store: acknowledge visit
    Store->>Store: Dequeue; retain visit acknowledgment
    Queue-->>Caller: drained if no other work remains
```

Duplicate means identical content was already durably committed. Server-side
idempotency is a required uplink contract; the test fake models it.

## Interrupted photo and priority between chunks

```mermaid
sequenceDiagram
    participant Caller
    participant Queue as OutboxQueue
    participant Store as OutboxStore
    participant Server as Uplink / fake server
    Note over Queue,Store: Parent visit already acknowledged; nextChunk = 0
    Caller->>Queue: sync()
    Queue->>Server: uploadChunk(photo, 0)
    Server-->>Queue: accepted
    Queue->>Store: checkpoint(photo, 1)
    Queue->>Store: Re-read pending and select eligible work
    Queue->>Server: uploadChunk(photo, 1)
    Server--xQueue: Mid-transfer disconnect
    Queue-->>Caller: retryLater
    Note over Store: nextChunk stays 1
    Caller->>Queue: sync() later
    Queue->>Store: Read checkpoint and select work
    Queue->>Server: uploadChunk(photo, 1)
    Server-->>Queue: accepted or matching duplicate
    Queue->>Store: checkpoint(photo, 2)
    Queue->>Store: Re-read pending; new structured data goes first
    Note over Queue,Server: Deliver eligible visits/observations before continuing photo
    Queue->>Server: uploadChunk(photo, 2)
    Server-->>Queue: accepted
    Queue->>Store: checkpoint(photo, 3)
    Queue->>Store: acknowledge photo
    Queue-->>Caller: drained if no other work remains
```

This example has three chunks. If a receipt is lost after server commitment,
replaying that chunk is safe under the uplink contract. If saving a checkpoint
fails, progress stays behind and the next attempt safely replays the chunk.
Actual byte transfers, durable disk recovery, and server photo assembly are not
implemented by the exercise's fakes.
