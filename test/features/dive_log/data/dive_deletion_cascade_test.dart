import 'dart:io';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:submersion/core/database/database.dart' hide Dive;
import 'package:submersion/core/database/local_cache_database.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/dive_log/data/repositories/dive_repository_impl.dart';
import 'package:submersion/features/dive_log/domain/entities/dive.dart';
import 'package:submersion/features/media/data/repositories/media_repository.dart';
import 'package:submersion/features/media/domain/entities/media_item.dart';
import 'package:submersion/features/media/domain/entities/media_source_type.dart';
import 'package:submersion/features/media_store/data/media_deletion_coordinator.dart';
import 'package:submersion/features/media_store/data/media_transfer_queue_repository.dart';

import '../../../helpers/test_database.dart';

/// Records how many `dives` rows still exist at the moment the bytes are
/// deleted. The rows have to go first: a failure after the file is gone
/// would leave a surviving dive pointing at bytes that are not there, while
/// a failure the other way round only leaks an unreferenced copy.
class _OrderRecordingImportedFileStore extends ImportedFileStore {
  _OrderRecordingImportedFileStore({super.documentsDirectory});

  final divesAliveAtDelete = <String, int>{};

  @override
  Future<void> delete(String path) async {
    final db = DatabaseService.instance.database;
    divesAliveAtDelete[path] = (await db.select(db.dives).get()).length;
    await super.delete(path);
  }
}

void main() {
  late LocalCacheDatabase cacheDb;
  late MediaTransferQueueRepository queue;
  late MediaRepository mediaRepository;
  late DiveRepository diveRepository;
  late Directory tempDocsDir;
  late ImportedFileStore importedFileStore;

  setUp(() async {
    await setUpTestDatabase();
    cacheDb = LocalCacheDatabase(NativeDatabase.memory());
    queue = MediaTransferQueueRepository(database: cacheDb);
    mediaRepository = MediaRepository();
    tempDocsDir = await Directory.systemTemp.createTemp(
      'dive_deletion_cascade_test',
    );
    importedFileStore = ImportedFileStore(
      documentsDirectory: () async => tempDocsDir,
    );
    diveRepository = DiveRepository(
      mediaRepository: mediaRepository,
      mediaDeletionCoordinator: MediaDeletionCoordinator(
        mediaRepository: mediaRepository,
        queue: () => queue,
      ),
      importedFileStore: importedFileStore,
    );
  });

  tearDown(() async {
    await cacheDb.close();
    await tearDownTestDatabase();
    if (await tempDocsDir.exists()) {
      await tempDocsDir.delete(recursive: true);
    }
  });

  Future<Dive> makeDive() =>
      diveRepository.createDive(Dive(id: '', dateTime: DateTime(2026, 6, 1)));

  Future<String> insertSite() async {
    final db = DatabaseService.instance.database;
    final epoch = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    await db
        .into(db.diveSites)
        .insert(
          DiveSitesCompanion(
            id: const Value('site-1'),
            name: const Value('Reef'),
            createdAt: Value(epoch),
            updatedAt: Value(epoch),
          ),
        );
    return 'site-1';
  }

  MediaItem item(
    String name, {
    String? diveId,
    String? siteId,
    String? hash,
    DateTime? uploadedAt,
    MediaSourceType sourceType = MediaSourceType.platformGallery,
  }) => MediaItem(
    id: '',
    mediaType: MediaType.photo,
    sourceType: sourceType,
    filePath: '/tmp/$name',
    localPath: '/tmp/$name',
    originalFilename: name,
    diveId: diveId,
    siteId: siteId,
    contentHash: hash,
    remoteUploadedAt: uploadedAt,
    takenAt: DateTime(2026, 1, 1),
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  Future<List<String>> mediaTombstones() async {
    final db = DatabaseService.instance.database;
    final rows = await (db.select(
      db.deletionLog,
    )..where((t) => t.entityType.equals('media'))).get();
    return rows.map((r) => r.recordId).toList();
  }

  test(
    'deleteDive deletes dive-only media with tombstone and blob intent',
    () async {
      final dive = await makeDive();
      final doomed = await mediaRepository.createMedia(
        item(
          'a.jpg',
          diveId: dive.id,
          hash: 'h1',
          uploadedAt: DateTime(2026, 2),
        ),
      );

      await diveRepository.deleteDive(dive.id);

      expect(await mediaRepository.getMediaById(doomed.id), isNull);
      expect(await mediaTombstones(), contains(doomed.id));
      final entry = (await queue.allForTesting()).single;
      expect(entry.direction, 'delete');
      expect(entry.contentHash, 'h1');
    },
  );

  test('site-linked media survives with diveId nulled', () async {
    final dive = await makeDive();
    final site = await insertSite();
    final kept = await mediaRepository.createMedia(
      item('b.jpg', diveId: dive.id, siteId: site),
    );

    await diveRepository.deleteDive(dive.id);

    final got = await mediaRepository.getMediaById(kept.id);
    expect(got, isNotNull);
    expect(got!.diveId, isNull);
    expect(got.siteId, site);
    expect(await queue.allForTesting(), isEmpty);
  });

  test('network media dies with its dive like any other photo', () async {
    // No source type is exempt from the cascade: a row with no dive and no
    // site has no place in the library, so a URL row that only this dive
    // owned goes with it. It was never uploaded, so no blob intent either.
    final dive = await makeDive();
    final doomed = await mediaRepository.createMedia(
      item('c.jpg', diveId: dive.id, sourceType: MediaSourceType.networkUrl),
    );

    await diveRepository.deleteDive(dive.id);

    expect(await mediaRepository.getMediaById(doomed.id), isNull);
    expect(await queue.allForTesting(), isEmpty);
  });

  test('bulkDeleteDives cascades across all deleted dives', () async {
    final d1 = await makeDive();
    final d2 = await makeDive();
    final m1 = await mediaRepository.createMedia(
      item('a.jpg', diveId: d1.id, hash: 'h1', uploadedAt: DateTime(2026, 2)),
    );
    final m2 = await mediaRepository.createMedia(
      item('b.jpg', diveId: d2.id, hash: 'h2', uploadedAt: DateTime(2026, 2)),
    );

    await diveRepository.bulkDeleteDives([d1.id, d2.id]);

    expect(await mediaRepository.getMediaById(m1.id), isNull);
    expect(await mediaRepository.getMediaById(m2.id), isNull);
    expect(await mediaTombstones(), containsAll([m1.id, m2.id]));
    final hashes = (await queue.allForTesting())
        .map((e) => e.contentHash)
        .toSet();
    expect(hashes, {'h1', 'h2'});
  });

  test('never-uploaded dive-only media dies without a blob intent', () async {
    final dive = await makeDive();
    final doomed = await mediaRepository.createMedia(
      item('plain.jpg', diveId: dive.id),
    );

    await diveRepository.deleteDive(dive.id);

    expect(await mediaRepository.getMediaById(doomed.id), isNull);
    expect(await mediaTombstones(), contains(doomed.id));
    expect(await queue.allForTesting(), isEmpty);
  });

  group('imported file cascade (issue #478)', () {
    Future<String> storeFileFor(
      List<String> diveIds, {
      List<int> bytes = const [1, 2, 3],
    }) async {
      final db = DatabaseService.instance.database;
      final path = await importedFileStore.store(
        bytes: Uint8List.fromList(bytes),
        originalFileName: 'logbook.uddf',
      );
      for (final diveId in diveIds) {
        await db
            .into(db.diveDataSources)
            .insert(
              DiveDataSourcesCompanion.insert(
                id: 'src-$diveId',
                diveId: diveId,
                isPrimary: const Value(true),
                importedAt: DateTime(2026, 1, 1),
                createdAt: DateTime(2026, 1, 1),
                sourceFileFormat: const Value('uddf'),
                importedFilePath: Value(path),
              ),
            );
      }
      return path;
    }

    test('deleting the only dive that points at a stored file removes '
        'it', () async {
      final dive = await makeDive();
      final path = await storeFileFor([dive.id]);

      await diveRepository.deleteDive(dive.id);

      expect(
        await File(await importedFileStore.absolutePathFor(path)).exists(),
        isFalse,
      );
    });

    test('a file shared by a surviving dive is kept', () async {
      final d1 = await makeDive();
      final d2 = await makeDive();
      final path = await storeFileFor([d1.id, d2.id]);

      await diveRepository.deleteDive(d1.id);

      expect(
        await File(await importedFileStore.absolutePathFor(path)).exists(),
        isTrue,
      );

      await diveRepository.deleteDive(d2.id);

      expect(
        await File(await importedFileStore.absolutePathFor(path)).exists(),
        isFalse,
      );
    });

    test('bulkDeleteDives removes a file once its last pointer goes', () async {
      final d1 = await makeDive();
      final d2 = await makeDive();
      final d3 = await makeDive();
      final shared = await storeFileFor([d1.id, d2.id]);
      final other = await storeFileFor([d3.id], bytes: const [9, 9, 9]);

      await diveRepository.bulkDeleteDives([d1.id, d2.id]);

      expect(
        await File(await importedFileStore.absolutePathFor(shared)).exists(),
        isFalse,
      );
      expect(
        await File(await importedFileStore.absolutePathFor(other)).exists(),
        isTrue,
      );
    });

    test('the rows go before the bytes', () async {
      final store = _OrderRecordingImportedFileStore(
        documentsDirectory: () async => tempDocsDir,
      );
      final repository = DiveRepository(
        mediaRepository: mediaRepository,
        mediaDeletionCoordinator: MediaDeletionCoordinator(
          mediaRepository: mediaRepository,
          queue: () => queue,
        ),
        importedFileStore: store,
      );
      final dive = await makeDive();
      final path = await storeFileFor([dive.id]);

      await repository.deleteDive(dive.id);

      expect(store.divesAliveAtDelete[await store.absolutePathFor(path)], 0);
      expect(
        await File(await importedFileStore.absolutePathFor(path)).exists(),
        isFalse,
      );
    });

    test('a file an older row names by its absolute path survives', () async {
      // Rows written before imported_file_path went documents-relative carry
      // the absolute spelling of the very same copy. The refcount has to see
      // both spellings, or deleting the newer dive takes bytes the older row
      // still points at.
      final d1 = await makeDive();
      final d2 = await makeDive();
      final path = await storeFileFor([d1.id]);
      final absolute = await importedFileStore.absolutePathFor(path);
      final db = DatabaseService.instance.database;
      await db
          .into(db.diveDataSources)
          .insert(
            DiveDataSourcesCompanion.insert(
              id: 'src-legacy',
              diveId: d2.id,
              isPrimary: const Value(true),
              importedAt: DateTime(2026, 1, 1),
              createdAt: DateTime(2026, 1, 1),
              sourceFileFormat: const Value('uddf'),
              importedFilePath: Value(absolute),
            ),
          );

      await diveRepository.deleteDive(d1.id);

      expect(await File(absolute).exists(), isTrue);

      await diveRepository.deleteDive(d2.id);

      expect(await File(absolute).exists(), isFalse);
    });

    test(
      'a restore-safe delete (cascadeMedia: false) keeps the file',
      () async {
        final dive = await makeDive();
        final path = await storeFileFor([dive.id]);

        await diveRepository.deleteDive(dive.id, cascadeMedia: false);

        expect(
          await File(await importedFileStore.absolutePathFor(path)).exists(),
          isTrue,
        );
      },
    );
  });
}
