import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';

void main() {
  late Directory tempDocsDir;
  late ImportedFileStore store;

  setUp(() async {
    tempDocsDir = await Directory.systemTemp.createTemp(
      'imported_file_store_test',
    );
    store = ImportedFileStore(documentsDirectory: () async => tempDocsDir);
  });

  tearDown(() async {
    if (await tempDocsDir.exists()) {
      await tempDocsDir.delete(recursive: true);
    }
  });

  test('copies bytes into <docs>/imported/<contentHash><ext>', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final path = await store.store(
      bytes: bytes,
      originalFileName: 'my dive.uddf',
    );

    expect(path, 'imported/${sha256.convert(bytes)}.uddf');
    expect(
      await store.absolutePathFor(path),
      p.join(tempDocsDir.path, 'imported', '${sha256.convert(bytes)}.uddf'),
    );
    expect(await File(await store.absolutePathFor(path)).readAsBytes(), bytes);
  });

  test(
    'preserves an extensionless original file name with no extension',
    () async {
      final bytes = Uint8List.fromList([9]);
      final path = await store.store(bytes: bytes, originalFileName: 'noext');

      expect(path, 'imported/${sha256.convert(bytes)}');
    },
  );

  test('re-storing identical bytes reuses the one copy', () async {
    final bytes = Uint8List.fromList([1, 2, 3, 4]);

    final first = await store.store(bytes: bytes, originalFileName: 'a.uddf');
    final second = await store.store(bytes: bytes, originalFileName: 'a.uddf');

    expect(second, first);
    final entries = Directory(p.join(tempDocsDir.path, 'imported')).listSync();
    expect(entries, hasLength(1));
  });

  test('two different files never collide', () async {
    final a = await store.store(
      bytes: Uint8List.fromList([1, 2, 3]),
      originalFileName: 'a.uddf',
    );
    final b = await store.store(
      bytes: Uint8List.fromList([4, 5, 6]),
      originalFileName: 'a.uddf',
    );

    expect(a, isNot(b));
  });

  test('directory resolves to <docs>/imported without creating it', () async {
    final dir = await store.directory();

    expect(dir.path, p.join(tempDocsDir.path, 'imported'));
    expect(await dir.exists(), isFalse);
  });

  test('read returns null for a path that does not exist', () async {
    expect(
      await store.read(p.join(tempDocsDir.path, 'imported', 'missing.uddf')),
      isNull,
    );
  });

  test('read returns the stored bytes', () async {
    final bytes = Uint8List.fromList([5, 6, 7]);
    final path = await store.store(bytes: bytes, originalFileName: 'x.fit');

    expect(await store.read(path), bytes);
  });

  test('exists reports whether the stored copy is still on disk', () async {
    final path = await store.store(
      bytes: Uint8List.fromList([1]),
      originalFileName: 'x.fit',
    );

    expect(await store.exists(path), isTrue);
    await store.delete(path);
    expect(await store.exists(path), isFalse);
  });

  test('delete removes the file and is a no-op if already gone', () async {
    final path = await store.store(
      bytes: Uint8List.fromList([1]),
      originalFileName: 'x.fit',
    );

    await store.delete(path);
    expect(await File(await store.absolutePathFor(path)).exists(), isFalse);

    // Second delete of the same (now-missing) path must not throw.
    await store.delete(path);
  });

  group('documents-relative paths (issue #478)', () {
    test('a stored copy still reads after the documents directory '
        'moves', () async {
      // iOS gives the app container a fresh UUID on reinstall and on
      // restore-from-backup, so an absolute path stored yesterday names a
      // directory that no longer exists while the bytes sit untouched under
      // the new one. Same shape as a desktop diver moving their documents
      // folder.
      var docs = await Directory.systemTemp.createTemp('docs_before');
      final movingStore = ImportedFileStore(
        documentsDirectory: () async => docs,
      );
      final bytes = Uint8List.fromList([4, 5, 6, 7]);

      final path = await movingStore.store(
        bytes: bytes,
        originalFileName: 'logbook.uddf',
      );

      final moved = await Directory.systemTemp.createTemp('docs_after');
      addTearDown(() async {
        if (await moved.exists()) await moved.delete(recursive: true);
      });
      await Directory(p.join(moved.path, 'imported')).create(recursive: true);
      for (final entry in Directory(p.join(docs.path, 'imported')).listSync()) {
        await File(
          entry.path,
        ).copy(p.join(moved.path, 'imported', p.basename(entry.path)));
      }
      await docs.delete(recursive: true);
      docs = moved;

      expect(await movingStore.exists(path), isTrue);
      expect(await movingStore.read(path), bytes);
    });

    test('an absolute path from an earlier build still resolves', () async {
      // Rows written before the path fix carry an absolute path. As long as
      // it still names a real file, the resync must keep working from it.
      final legacy = p.join(tempDocsDir.path, 'imported', 'legacy.uddf');
      await Directory(
        p.join(tempDocsDir.path, 'imported'),
      ).create(recursive: true);
      final bytes = Uint8List.fromList([8, 8]);
      await File(legacy).writeAsBytes(bytes, flush: true);

      expect(await store.absolutePathFor(legacy), legacy);
      expect(await store.exists(legacy), isTrue);
      expect(await store.read(legacy), bytes);

      await store.delete(legacy);
      expect(await store.exists(legacy), isFalse);
    });

    test('spellingsOf names both forms of a copy under documents', () async {
      final bytes = Uint8List.fromList([1, 1, 1]);
      final path = await store.store(bytes: bytes, originalFileName: 'a.uddf');
      final absolute = await store.absolutePathFor(path);

      expect(await store.spellingsOf(path), {path, absolute});
      expect(await store.spellingsOf(absolute), {path, absolute});
    });

    test('spellingsOf leaves a path outside documents alone', () async {
      final outside = await Directory.systemTemp.createTemp('foreign_docs');
      addTearDown(() async {
        if (await outside.exists()) await outside.delete(recursive: true);
      });
      final foreign = p.join(outside.path, 'imported', 'x.uddf');

      expect(await store.spellingsOf(foreign), {foreign});
    });
  });

  test('rewrites a destination truncated by a crash mid-write', () async {
    // A process that died inside writeAsBytes leaves a short file at the
    // content-hash path. Reusing it would feed every later resync truncated
    // bytes, silently.
    final bytes = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final destPath = p.join(
      tempDocsDir.path,
      'imported',
      '${sha256.convert(bytes)}.uddf',
    );
    await Directory(
      p.join(tempDocsDir.path, 'imported'),
    ).create(recursive: true);
    await File(destPath).writeAsBytes(bytes.sublist(0, 10), flush: true);

    final path = await store.store(bytes: bytes, originalFileName: 'a.uddf');

    expect(await store.absolutePathFor(path), destPath);
    expect(await File(destPath).readAsBytes(), bytes);
  });

  test('leaves no temporary file behind on a successful store', () async {
    await store.store(
      bytes: Uint8List.fromList([1, 2, 3, 4]),
      originalFileName: 'a.uddf',
    );

    final entries = Directory(
      p.join(tempDocsDir.path, 'imported'),
    ).listSync().map((e) => p.basename(e.path)).toList();
    expect(entries, hasLength(1));
    expect(entries.single, endsWith('.uddf'));
  });

  test('leaves no temporary file behind when the write fails', () async {
    // A directory squatting on the destination path makes the rename fail;
    // any temporary the store wrote first must not survive the failure.
    final bytes = Uint8List.fromList([7, 7, 7]);
    final destPath = p.join(
      tempDocsDir.path,
      'imported',
      '${sha256.convert(bytes)}.uddf',
    );
    await Directory(destPath).create(recursive: true);

    await expectLater(
      store.store(bytes: bytes, originalFileName: 'a.uddf'),
      throwsA(isA<FileSystemException>()),
    );

    final entries = Directory(
      p.join(tempDocsDir.path, 'imported'),
    ).listSync().map((e) => p.basename(e.path)).toList();
    expect(entries, [p.basename(destPath)]);
  });
}
