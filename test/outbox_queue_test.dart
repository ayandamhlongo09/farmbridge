import 'package:farm_bridge/outbox_queue.dart';
import 'package:test/test.dart';

class MemoryStore implements OutboxStore {
  final items = <String, PendingItem>{};
  final visits = <String>{};
  final usedIds = <String>{};

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

  @override
  Future<Receipt> submit(OutboxItem item) async {
    attempts.add(item.id);
    return Receipt.accepted;
  }

  @override
  Future<Receipt> uploadChunk(PhotoUpload photo, int index) async {
    throw UnsupportedError('Photo transfer is not implemented yet');
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
}
