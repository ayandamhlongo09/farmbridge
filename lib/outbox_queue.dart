import 'dart:async';

sealed class OutboxItem {
  OutboxItem(this.id) {
    if (id.isEmpty) throw ArgumentError.value(id, 'id');
  }

  final String id;
  int get priority;
  String? get visitId => null;
}

final class VisitRecord extends OutboxItem {
  VisitRecord(super.id, Map<String, String> data)
      : data = Map.unmodifiable(data);

  final Map<String, String> data;
  @override
  int get priority => 0;
}

final class Observation extends OutboxItem {
  Observation(super.id, this.visitId, Map<String, String> data)
      : data = Map.unmodifiable(data);

  @override
  final String visitId;
  final Map<String, String> data;
  @override
  int get priority => 1;
}

final class PhotoUpload extends OutboxItem {
  PhotoUpload(super.id, this.visitId, this.filePath, this.chunkCount) {
    if (chunkCount <= 0) throw ArgumentError.value(chunkCount, 'chunkCount');
  }

  @override
  final String visitId;
  final String filePath;
  final int chunkCount;
  @override
  int get priority => 2;
}

final class PendingItem {
  const PendingItem(this.item, {this.nextChunk = 0});

  final OutboxItem item;
  final int nextChunk;
}

abstract interface class OutboxStore {
  Future<void> add(OutboxItem item);

  Future<List<PendingItem>> pending();
  Future<bool> visitAcknowledged(String id);
  Future<void> checkpoint(String photoId, int nextChunk);

  Future<void> acknowledge(OutboxItem item);
}

enum Receipt { accepted, duplicate }

abstract interface class Uplink {
  Future<Receipt> submit(OutboxItem item);

  Future<Receipt> uploadChunk(PhotoUpload photo, int index);
}

final class RetryableUplinkFailure implements Exception {
  const RetryableUplinkFailure(this.message);

  final String message;
  @override
  String toString() => message;
}

enum SyncOutcome { drained, retryLater, blocked }

final class OutboxQueue {
  OutboxQueue(this.store, this.uplink);

  final OutboxStore store;
  final Uplink uplink;

  Future<void> enqueue(OutboxItem item) => store.add(item);

  Future<SyncOutcome> sync() async {
    while (true) {
      final pending = await store.pending();
      if (pending.isEmpty) return SyncOutcome.drained;

      PendingItem? selected;
      for (final candidate in pending) {
        final parent = candidate.item.visitId;
        if (parent != null && !await store.visitAcknowledged(parent)) continue;
        if (selected == null ||
            candidate.item.priority < selected.item.priority) {
          selected = candidate;
        }
      }
      if (selected == null) return SyncOutcome.blocked;

      final item = selected.item;
      if (item is PhotoUpload) {
        throw UnsupportedError('Photo transfer is not implemented yet');
      }
      try {
        await uplink.submit(item);
        await store.acknowledge(item);
      } on RetryableUplinkFailure {
        return SyncOutcome.retryLater;
      } on TimeoutException {
        return SyncOutcome.retryLater;
      }
    }
  }
}
