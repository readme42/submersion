import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

/// Stores the raw bytes of a file-imported dive log, untouched, in a
/// dedicated `imported/` folder under the app's documents directory --
/// mirroring the existing `scanned_logs/` convention used for OCR'd logbook
/// pages (see [MediaImportService]). Kept outside the database so a fresh
/// parse fix never grows `dive_data_sources.rawData`/sync payloads (issue
/// #478 comment thread, 2026-07-07/2026-08-20): the folder is local-only by
/// default, opt-in to sync via the media object store queue.
class ImportedFileStore {
  final Future<Directory> Function() _documentsDirectory;
  static const _uuid = Uuid();

  ImportedFileStore({Future<Directory> Function()? documentsDirectory})
    : _documentsDirectory =
          documentsDirectory ?? getApplicationDocumentsDirectory;

  /// The folder name every stored copy lives in, under the app's documents
  /// directory.
  static const folder = 'imported';

  /// The `imported/` folder under the app's documents directory, resolved
  /// through the same [documentsDirectory] callback [store] uses. Does not
  /// create it -- callers that only want to measure or list it must not have
  /// the side effect of bringing it into existence.
  Future<Directory> directory() async {
    final docs = await _documentsDirectory();
    return Directory(p.join(docs.path, folder));
  }

  /// Where [storedPath] -- a value of `dive_data_sources.imported_file_path`
  /// -- actually is on this device right now.
  ///
  /// Stored paths are documents-relative (`imported/<name>`, POSIX-separated
  /// so the value means the same thing on every platform it syncs to) and
  /// are resolved here against wherever the documents directory is at read
  /// time. iOS gives the app container a new UUID on reinstall and on
  /// restore-from-backup, so an absolute path recorded at import time stops
  /// naming the bytes it was written for while the bytes themselves are
  /// untouched; a desktop diver moving their documents folder breaks the
  /// same way.
  ///
  /// A value that is already absolute was written before that fix and is
  /// used as it stands, so the rows that still resolve keep working.
  Future<String> absolutePathFor(String storedPath) async {
    if (p.isAbsolute(storedPath)) return storedPath;
    final docs = await _documentsDirectory();
    return p.joinAll([docs.path, ...p.url.split(storedPath)]);
  }

  /// Every value of `dive_data_sources.imported_file_path` that names the
  /// same copy as [storedPath] on this device: the documents-relative form
  /// written since the path fix, and the absolute form earlier rows carry.
  ///
  /// Refcounting has to count both spellings, or deleting the last relative
  /// row would take bytes an absolute row still points at.
  Future<Set<String>> spellingsOf(String storedPath) async {
    final absolute = await absolutePathFor(storedPath);
    final docs = (await _documentsDirectory()).path;
    if (!p.isWithin(docs, absolute)) return {storedPath, absolute};
    return {
      storedPath,
      absolute,
      p.url.joinAll(p.split(p.relative(absolute, from: docs))),
    };
  }

  /// Copies [bytes] into `<documents>/imported/<sha256 of bytes><ext>`, where
  /// `<ext>` is taken from [originalFileName] (empty when it has none).
  /// Returns the documents-relative path to record in
  /// `dive_data_sources.imported_file_path`; see [absolutePathFor] for why
  /// the column may not hold an absolute one.
  ///
  /// Content-addressed, so one import run's N dives all point at one copy and
  /// re-importing the same file reuses it instead of orphaning the previous
  /// one. Two genuinely different files land on different paths.
  ///
  /// Written through a temporary in the same directory and renamed over the
  /// destination, so a crash mid-write can never publish a short file that
  /// every later store of the same content would reuse and every resync
  /// would parse as truncated data. An existing destination is reused only
  /// when its length matches: the path already pins the content, so a
  /// wrong-length file is the only way the bytes can disagree, and a length
  /// check costs a stat where re-hashing costs a full read of a logbook that
  /// can run to tens of megabytes on every import.
  Future<String> store({
    required Uint8List bytes,
    required String originalFileName,
  }) async {
    final dir = await directory();
    await dir.create(recursive: true);
    final ext = p.extension(originalFileName);
    final name = '${sha256.convert(bytes)}$ext';
    final storedPath = p.url.join(folder, name);
    final destPath = p.join(dir.path, name);
    final dest = File(destPath);
    if (await dest.exists() && await dest.length() == bytes.length) {
      return storedPath;
    }
    final temp = File(p.join(dir.path, '.${_uuid.v4()}.tmp'));
    try {
      await temp.writeAsBytes(bytes, flush: true);
      await temp.rename(destPath);
    } catch (_) {
      try {
        if (await temp.exists()) await temp.delete();
      } catch (_) {
        // A temporary we cannot remove must not mask the write failure.
      }
      rethrow;
    }
    return storedPath;
  }

  /// Reads back a previously stored file, or null if it no longer exists
  /// (manual deletion, an absolute path from a build before [absolutePathFor],
  /// restored from a backup that predates this feature).
  Future<Uint8List?> read(String path) async {
    final file = File(await absolutePathFor(path));
    if (!await file.exists()) return null;
    return file.readAsBytes();
  }

  /// Whether a stored copy is still on this device's disk. `imported_file_path`
  /// syncs verbatim, so a peer can hold a path -- an absolute one from an older
  /// build especially -- that never resolves here.
  Future<bool> exists(String path) async =>
      File(await absolutePathFor(path)).exists();

  /// Deletes a stored file. A no-op if it is already gone.
  Future<void> delete(String path) async {
    final file = File(await absolutePathFor(path));
    if (await file.exists()) {
      await file.delete();
    }
  }
}
