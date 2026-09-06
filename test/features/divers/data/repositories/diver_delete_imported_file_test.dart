import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';

import 'package:submersion/core/database/database.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_cleanup.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/divers/data/repositories/diver_repository.dart';

import '../../../../helpers/test_database.dart';

/// Deleting a diver runs `DELETE FROM dives WHERE diver_id = ?` as raw SQL,
/// so the FK cascade takes every `dive_data_sources` row those dives owned.
/// Each of those rows can be the last pointer at a stored import copy, and
/// `imported/` has no orphan sweep, so the bytes have to be refcounted the
/// way a dive deletion already refcounts them (issue #478).
void main() {
  late AppDatabase db;
  late Directory tempDocsDir;
  late ImportedFileStore store;
  late DiverRepository repository;

  setUp(() async {
    db = await setUpTestDatabase();
    tempDocsDir = await Directory.systemTemp.createTemp(
      'diver_delete_imported_file_test',
    );
    store = ImportedFileStore(documentsDirectory: () async => tempDocsDir);
    repository = DiverRepository(
      importedFileCleanup: ImportedFileCleanup(store: store),
    );
  });

  tearDown(() async {
    await tearDownTestDatabase();
    if (await tempDocsDir.exists()) {
      await tempDocsDir.delete(recursive: true);
    }
  });

  Future<void> insertDiver(String id) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await db
        .into(db.divers)
        .insert(
          DiversCompanion(
            id: Value(id),
            name: Value(id),
            createdAt: Value(now),
            updatedAt: Value(now),
          ),
        );
  }

  Future<void> insertDive(String id, String diverId) async {
    const epoch = 1700000000000;
    await db
        .into(db.dives)
        .insert(
          DivesCompanion.insert(
            id: id,
            diverId: Value(diverId),
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

  test('takes every stored copy the diver was the last to name', () async {
    await insertDiver('diver-1');
    await insertDive('dive-1', 'diver-1');
    await insertDive('dive-2', 'diver-1');
    final first = await storeFile();
    final second = await storeFile(bytes: const [9, 9, 9]);
    await insertSource(id: 'src-1', diveId: 'dive-1', importedFilePath: first);
    await insertSource(id: 'src-2', diveId: 'dive-2', importedFilePath: second);

    await repository.deleteDiverWithReassignment('diver-1');

    expect(await db.select(db.dives).get(), isEmpty);
    expect(await onDisk(first), isFalse);
    expect(await onDisk(second), isFalse);
  });

  test('keeps a copy a surviving diver still points at', () async {
    await insertDiver('diver-1');
    await insertDiver('diver-2');
    await insertDive('dive-1', 'diver-1');
    await insertDive('dive-2', 'diver-2');
    final path = await storeFile();
    await insertSource(id: 'src-1', diveId: 'dive-1', importedFilePath: path);
    await insertSource(id: 'src-2', diveId: 'dive-2', importedFilePath: path);

    await repository.deleteDiverWithReassignment('diver-1');

    expect(await onDisk(path), isTrue);

    await repository.deleteDiverWithReassignment('diver-2');

    expect(await onDisk(path), isFalse);
  });

  test('the rows go before the bytes', () async {
    await insertDiver('diver-1');
    await insertDive('dive-1', 'diver-1');
    final path = await storeFile();
    await insertSource(id: 'src-1', diveId: 'dive-1', importedFilePath: path);

    await repository.deleteDiverWithReassignment('diver-1');

    expect(await db.select(db.diveDataSources).get(), isEmpty);
    expect(await onDisk(path), isFalse);
  });
}
