// I included as the contractor reference for the Part 3 code review in REVIEW.md.
// This is not FarmBridge's sync implementation; the supplied code below is unchanged.
// Excluded from normal analysis because its dynamic response types fail strict checks.

// sync_service.dart
// Field sync service — v1, contractor delivery.
// "Tested on office wifi, works great." — contractor

import 'dart:io';
import 'dart:convert';

class SyncService {
  final ApiClient api;
  final LocalDb db;

  SyncService(this.api, this.db);

  bool syncing = false;

  /// Called whenever connectivity changes to "online",
  /// and also every 30 seconds by a timer in main.dart.
  Future<void> sync() async {
    syncing = true;

    // Photos first: they're the biggest, get them out of the way
    // while we have signal.
    final photos = await db.pendingPhotos();
    for (final photo in photos) {
      final bytes = await File(photo.path).readAsBytes();
      final b64 = base64Encode(bytes);
      // Remove from queue so we don't send it twice if sync()
      // gets called again while this one is still running.
      await db.removePendingPhoto(photo.id);
      try {
        await api.post('/photos', {
          'visitId': photo.visitId,
          'takenAt': DateTime.now().toIso8601String(),
          'data': b64,
        });
      } catch (e) {
        // Network is flaky in the field, this is expected.
        // The retry timer will pick things up eventually.
      }
    }

    // Then structured records.
    final visits = await db.pendingVisits();
    for (final visit in visits) {
      var sent = false;
      while (!sent) {
        try {
          await api.post('/visits', visit.toJson());
          sent = true;
        } catch (e) {
          // keep trying, we need this data at head office ASAP
        }
      }
      await db.removePendingVisit(visit.id);
    }

    // Pull server-side changes and reconcile.
    final serverFarms = await api.get('/farms/updates');
    for (final serverFarm in serverFarms) {
      final localFarm = await db.getFarm(serverFarm['id']);
      if (localFarm == null) {
        await db.saveFarm(serverFarm);
        continue;
      }
      // Conflict resolution: newest edit wins.
      final serverTime = DateTime.parse(serverFarm['updatedAt']);
      if (localFarm.updatedAt.isAfter(serverTime)) {
        // Our local edit is newer — push it up.
        await api.post('/farms/${localFarm.id}', localFarm.toJson());
      } else {
        // Server is newer — take it, discard local changes.
        await db.saveFarm(serverFarm);
      }
    }

    syncing = false;
  }
}

class PendingPhoto {
  final String id;
  final String visitId;
  final String path;
  PendingPhoto(this.id, this.visitId, this.path);
}

class Farm {
  final String id;
  final DateTime updatedAt; // set to DateTime.now() on every local edit
  Farm(this.id, this.updatedAt);
  Map<String, dynamic> toJson() => {};
}

class Visit {
  final String id;
  Visit(this.id);
  Map<String, dynamic> toJson() => {};
}

// --- interfaces provided elsewhere ---
abstract class ApiClient {
  Future<dynamic> get(String path);
  Future<dynamic> post(String path, Map<String, dynamic> body);
}

abstract class LocalDb {
  Future<List<PendingPhoto>> pendingPhotos();
  Future<void> removePendingPhoto(String id);
  Future<List<Visit>> pendingVisits();
  Future<void> removePendingVisit(String id);
  Future<Farm?> getFarm(String id);
  Future<void> saveFarm(dynamic farm);
}
