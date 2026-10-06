import 'dart:async';
import 'package:farm_bridge/outbox_queue.dart';
import 'package:test/test.dart';

class MemoryStore implements OutboxStore {
  final items = <String, PendingItem>{};
  final visits = <String>{};
  final usedIds = <String>{};
  bool failCheckpoint = false;

  @override
  Future<void> add(OutboxItem item) async {
    if (!usedIds.add(item.id)) throw StateError('Operation ID reused');
    items[item.id] = PendingItem(item);
  }

  @override
  Future<List<PendingItem>> pending() async => items.values.toList();

  @override
  Future<bool> visitAcknowledged(String id) async => visits.contains(id);

  @override
  Future<void> checkpoint(String photoId, int nextChunk) async {
    if (failCheckpoint) throw StateError('Disk full');
    items[photoId] = PendingItem(items[photoId]!.item, nextChunk: nextChunk);
  }

  @override
  Future<void> acknowledge(OutboxItem item) async {
    if (item is VisitRecord) visits.add(item.id);
    items.remove(item.id);
  }
}

class FakeUplink implements Uplink {
  final attempts = <String>[];
  final committed = <String>{};
  final replies = <Receipt>[];
  String? disconnectOnce;
  String? silentCommitOnce;
  bool unexpectedFailure = false;

  Future<void> Function(String key)? beforeSend;

  @override
  Future<Receipt> submit(OutboxItem item) => _send(item.id);

  @override
  Future<Receipt> uploadChunk(PhotoUpload photo, int index) =>
      _send('${photo.id}:$index');

  Future<Receipt> _send(String key) async {
    attempts.add(key);
    await beforeSend?.call(key);
    if (unexpectedFailure) throw StateError('Server rejected the request');
    if (disconnectOnce == key) {
      disconnectOnce = null;
      throw const RetryableUplinkFailure('Signal lost mid-transfer');
    }
    final receipt = committed.add(key) ? Receipt.accepted : Receipt.duplicate;
    if (silentCommitOnce == key) {
      silentCommitOnce = null;
      throw TimeoutException('Committed, but acknowledgment lost');
    }
    replies.add(receipt);
    return receipt;
  }
}

void main() {
  late MemoryStore store;
  late FakeUplink uplink;
  late OutboxQueue queue;

  setUp(() {
    store = MemoryStore();
    uplink = FakeUplink();
    queue = OutboxQueue(store, uplink);
  });

  VisitRecord visit(String id) => VisitRecord(id, {'farm': 'farm-1'});

  test('visits precede observations across visits, with FIFO within each type',
      () async {
    store.visits.addAll(['parent-a', 'parent-b']);
    await queue
        .enqueue(Observation('observation-a', 'parent-a', {'crop': 'maize'}));
    await queue.enqueue(visit('visit-a'));
    await queue
        .enqueue(Observation('observation-b', 'parent-b', {'crop': 'wheat'}));
    await queue.enqueue(visit('visit-b'));

    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts,
        ['visit-a', 'visit-b', 'observation-a', 'observation-b']);
    expect(store.items, isEmpty);
  });

  test('observation waits for its parent visit acknowledgment', () async {
    await queue.enqueue(Observation('observation', 'parent', {}));
    expect(await queue.sync(), SyncOutcome.blocked);
    expect(uplink.attempts, isEmpty);
    expect(store.items.keys, ['observation']);

    await queue.enqueue(visit('parent'));
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['parent', 'observation']);
    expect(store.visits, contains('parent'));
  });

  test('missing parent does not prevent unrelated work from syncing', () async {
    await queue.enqueue(Observation('orphan', 'missing', {}));
    await queue.enqueue(visit('unrelated'));

    expect(await queue.sync(), SyncOutcome.blocked);
    expect(uplink.attempts, ['unrelated']);
    expect(store.items.keys, ['orphan']);
  });

  test('empty and repeated sync attempts send no additional records', () async {
    expect(await queue.sync(), SyncOutcome.drained);
    await queue.enqueue(visit('visit'));
    expect(await queue.sync(), SyncOutcome.drained);
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit']);
  });

  test('sync after silent-commit timeout does not duplicate the visit',
      () async {
    await queue.enqueue(visit('visit'));
    uplink.silentCommitOnce = 'visit';
    expect(await queue.sync(), SyncOutcome.retryLater);
    expect(store.items.keys, ['visit']);
    expect(uplink.committed, {'visit'});

    queue = OutboxQueue(store, uplink);
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit', 'visit']);
    expect(uplink.committed, {'visit'});
    expect(uplink.replies, [Receipt.duplicate]);
    expect(store.items, isEmpty);
  });

  test('disconnect retains parent and children until a later attempt succeeds',
      () async {
    await queue.enqueue(visit('visit'));
    await queue.enqueue(Observation('observation', 'visit', {}));
    uplink.disconnectOnce = 'visit';
    expect(await queue.sync(), SyncOutcome.retryLater);
    expect(uplink.attempts, ['visit']);
    expect(uplink.committed, isEmpty);
    expect(store.items.keys, ['visit', 'observation']);

    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit', 'visit', 'observation']);
    expect(store.items, isEmpty);
  });

  test('unexpected errors propagate without discarding pending work', () async {
    await queue.enqueue(visit('visit'));
    uplink.unexpectedFailure = true;
    await expectLater(queue.sync(), throwsStateError);
    expect(store.items.keys, ['visit']);
    expect(uplink.committed, isEmpty);

    uplink.unexpectedFailure = false;
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.committed, {'visit'});
  });

  PhotoUpload photo([int chunks = 3]) =>
      PhotoUpload('photo', 'visit', '/photo', chunks);

  test('structured data from both visits precedes photos', () async {
    await queue.enqueue(photo(1));
    await queue.enqueue(Observation('observation', 'visit', {}));
    await queue.enqueue(visit('visit'));
    await queue.enqueue(visit('visit-2'));
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit', 'visit-2', 'observation', 'photo:0']);
  });

  test('interrupted photo resumes at chunk N after worker reconstruction',
      () async {
    await queue.enqueue(visit('visit'));
    await queue.enqueue(photo());
    uplink.disconnectOnce = 'photo:1';
    expect(await queue.sync(), SyncOutcome.retryLater);
    expect(store.items['photo']!.nextChunk, 1);
    queue = OutboxQueue(store, uplink);
    expect(await queue.sync(), SyncOutcome.drained);
    expect(
        uplink.attempts, ['visit', 'photo:0', 'photo:1', 'photo:1', 'photo:2']);
  });

  test('lost final chunk acknowledgment retains the photo and replays safely',
      () async {
    await queue.enqueue(visit('visit'));
    await queue.enqueue(photo(1));
    uplink.silentCommitOnce = 'photo:0';
    expect(await queue.sync(), SyncOutcome.retryLater);
    expect(store.items['photo']!.nextChunk, 0);
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit', 'photo:0', 'photo:0']);
    expect(uplink.committed, {'visit', 'photo:0'});
    expect(uplink.replies.last, Receipt.duplicate);
  });

  test('new structured data preempts photos at the next chunk boundary',
      () async {
    await queue.enqueue(visit('visit'));
    await queue.enqueue(photo());
    uplink.beforeSend = (key) async {
      if (key == 'photo:0') {
        await queue.enqueue(visit('new-visit'));
        await queue.enqueue(Observation('new-observation', 'new-visit', {}));
      }
    };
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, [
      'visit',
      'photo:0',
      'new-visit',
      'new-observation',
      'photo:1',
      'photo:2'
    ]);
  });

  test('checkpoint failure retains progress and safely replays committed chunk',
      () async {
    await queue.enqueue(visit('visit'));
    await queue.enqueue(photo(1));
    store.failCheckpoint = true;
    await expectLater(queue.sync(), throwsStateError);
    expect(store.items['photo']!.nextChunk, 0);
    store.failCheckpoint = false;
    expect(await queue.sync(), SyncOutcome.drained);
    expect(uplink.attempts, ['visit', 'photo:0', 'photo:0']);
    expect(uplink.committed, {'visit', 'photo:0'});
  });
}
