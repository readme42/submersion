import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/core/services/sync/sync_data_serializer.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_cleanup.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';

import '../../../helpers/test_database.dart';

/// A dives tombstone from a peer deletes the local row, and the FK cascade
/// takes its `dive_data_sources` rows with it. On the device that actually
/// holds the imported copy those rows are the only pointers at it, and
/// `imported/` has no orphan sweep, so the bytes have to be refcounted here
/// the way a local delete already refcounts them (issue #478).
void main() {
  late AppDatabase db;
  late Directory tempDocsDir;
  late ImportedFileStore store;
  late SyncDataSerializer serializer;

  setUp(() async {
    db = await setUpTestDatabase();
    tempDocsDir = await Directory.systemTemp.createTemp(
      'dive_tombstone_imported_file_test',
    );
    store = ImportedFileStore(documentsDirectory: () async => tempDocsDir);
    serializer = SyncDataSerializer(
      importedFileCleanup: ImportedFileCleanup(store: store),
    );
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (await tempDocsDir.exists()) {
      await tempDocsDir.delete(recursive: true);
    }
  });

  Future<void> insertDive(String id) async {
    const epoch = 1700000000000;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: id,
            diveDateTime: epoch,
            createdAt: epoch,
            updatedAt: epoch,
          ),
        );
  }

  Future<void> insertSource({
    required String id,
    required String diveId,
    required String importedFilePath,
  }) async {
    await db
        .into(db.diveDataSources)
        .insert(
          DiveDataSourcesCompanion.insert(
            id: id,
            diveId: diveId,
            isPrimary: const Value(true),
            importedAt: DateTime(2026, 1, 1),
            createdAt: DateTime(2026, 1, 1),
            sourceFileFormat: const Value('uddf'),
            importedFilePath: Value(importedFilePath),
          ),
        );
  }

  Future<String> storeFile({List<int> bytes = const [1, 2, 3]}) => store.store(
    bytes: Uint8List.fromList(bytes),
    originalFileName: 'logbook.uddf',
  );

  Future<bool> onDisk(String path) async =>
      File(await store.absolutePathFor(path)).exists();

  test('takes the stored copy whose last pointer it removes', () async {
    await insertDive('dive-1');
    final path = await storeFile();
    await insertSource(id: 'src-1', diveId: 'dive-1', importedFilePath: path);

    await serializer.deleteRecord('dives', 'dive-1');

    expect(await db.select(db.dives).get(), isEmpty);
    expect(await onDisk(path), isFalse);
  });

  test('keeps a stored copy another dive still points at', () async {
    await insertDive('dive-1');
    await insertDive('dive-2');
    final path = await storeFile();
    await insertSource(id: 'src-1', diveId: 'dive-1', importedFilePath: path);
    await insertSource(id: 'src-2', diveId: 'dive-2', importedFilePath: path);

    await serializer.deleteRecord('dives', 'dive-1');

    expect(await onDisk(path), isTrue);

    await serializer.deleteRecord('dives', 'dive-2');

    expect(await onDisk(path), isFalse);
  });

  test('a tombstone for a dive with no stored copy is unaffected', () async {
    await insertDive('dive-1');

    await serializer.deleteRecord('dives', 'dive-1');

    expect(await db.select(db.dives).get(), isEmpty);
  });
}
