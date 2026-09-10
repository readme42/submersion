import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'package:submersion/core/database/raw_dive_data_codec.dart';
import 'package:submersion/core/services/logger_service.dart';

const _log = LoggerService('ImportedFileFolderAdoption');

/// Moves the stored logbook files of the pre-database design into
/// `imported_files` (issue #478).
///
/// The first cut of the resync feature kept them in
/// `<documents>/Submersion/imported/`, content-addressed, with
/// `dive_data_sources.imported_file_path` naming them. The maintainers settled
/// on the database instead so the files ride backups and sync. No released
/// build ever wrote the folder, but the device the branch was tested on has
/// one, and leaving it there would cost every dive on it its Resync action and
/// turn the folder into garbage no sweep can reach.
///
/// Gated on its own leftovers: it only looks at the disk while the legacy
/// column exists AND some row still carries a path, and every pass either
/// adopts a path or clears one. Once the column holds nothing, this is two
/// cheap queries and no I/O, forever. That is what makes it safe to call from
/// the `beforeOpen` backstop as well as from the rung -- the device this exists
/// for is already stamped v208, so the rung alone would never run.
///
/// Local-only, like the other migration-time backfills: a migration has no
/// clock and no sync bookkeeping to hand, so the adopted row lands with
/// `hlc IS NULL` and `SyncRepository.backfillMissingHlc` stamps it at the start
/// of the next sync. The `imported_file_id` it writes onto the source rows
/// reaches peers when those dives next sync.
///
/// Best effort throughout and never fatal: a file that cannot be read keeps its
/// path for the next pass to retry, and any failure at all leaves the database
/// exactly as usable as it was.
Future<void> adoptImportedFileFolder(
  GeneratedDatabase db, {
  Future<Directory> Function()? documentsDirectory,
}) async {
  try {
    final columns = await db
        .customSelect("PRAGMA table_info('dive_data_sources')")
        .get();
    final names = columns.map((c) => c.read<String>('name')).toSet();
    if (!names.contains('imported_file_path') ||
        !names.contains('imported_file_id')) {
      return;
    }

    final pending = await db
        .customSelect(
          'SELECT DISTINCT imported_file_path AS path FROM dive_data_sources '
          'WHERE imported_file_path IS NOT NULL',
        )
        .get();
    if (pending.isEmpty) return;

    final docs =
        await (documentsDirectory ?? getApplicationDocumentsDirectory)();
    final root = p.join(docs.path, 'Submersion');
    var adopted = 0;
    for (final row in pending) {
      final storedPath = row.read<String>('path');
      if (await _adoptOne(db, storedPath, root)) adopted++;
    }
    if (adopted > 0) {
      _log.info('Adopted $adopted imported file(s) into the database');
    }
    await _removeFolderIfDone(db, root);
  } catch (e, stackTrace) {
    _log.warning(
      'Could not adopt the imported-file folder',
      error: e,
      stackTrace: stackTrace,
    );
  }
}

/// Returns whether [storedPath]'s bytes made it into the table.
Future<bool> _adoptOne(
  GeneratedDatabase db,
  String storedPath,
  String root,
) async {
  final file = File(
    p.isAbsolute(storedPath)
        ? storedPath
        : p.joinAll([root, ...p.url.split(storedPath)]),
  );
  if (!await file.exists()) {
    // Nothing to adopt and nothing to wait for. Clearing the path is what
    // keeps this pass from running again for a file that is not coming back.
    await _clearPath(db, storedPath);
    return false;
  }

  final Uint8List bytes;
  try {
    bytes = await file.readAsBytes();
  } catch (e) {
    // Present but unreadable: keep the path so the next open retries rather
    // than discarding the last reference to bytes that are still there.
    _log.warning('Could not read ${file.path} for adoption: $e');
    return false;
  }

  final id = sha256.convert(bytes).toString();
  final now = DateTime.now().millisecondsSinceEpoch;
  await db.customStatement(
    'INSERT OR IGNORE INTO imported_files '
    '(id, bytes, file_name, byte_count, created_at, updated_at) '
    'VALUES (?, ?, ?, ?, ?, ?)',
    [
      id,
      encodeRawDiveData(bytes),
      p.basename(file.path),
      bytes.length,
      now,
      now,
    ],
  );
  await db.customStatement(
    'UPDATE dive_data_sources SET imported_file_id = ?, '
    'imported_file_path = NULL WHERE imported_file_path = ?',
    [id, storedPath],
  );
  try {
    await file.delete();
  } catch (e) {
    // The bytes are in the table; a file left behind is only disk.
    _log.warning('Could not remove ${file.path} after adoption: $e');
  }
  return true;
}

Future<void> _clearPath(GeneratedDatabase db, String storedPath) {
  return db.customStatement(
    'UPDATE dive_data_sources SET imported_file_path = NULL '
    'WHERE imported_file_path = ?',
    [storedPath],
  );
}

/// Removes the now-empty folder, but only once no row still names anything in
/// it. A non-empty directory delete fails and is swallowed, which is the right
/// outcome: whatever is left is a file a later pass may still want.
Future<void> _removeFolderIfDone(GeneratedDatabase db, String root) async {
  final remaining = await db
      .customSelect(
        'SELECT COUNT(*) AS n FROM dive_data_sources '
        'WHERE imported_file_path IS NOT NULL',
      )
      .getSingle();
  if (remaining.read<int>('n') > 0) return;
  try {
    final folder = Directory(p.join(root, 'imported'));
    if (await folder.exists() && await folder.list().isEmpty) {
      await folder.delete();
    }
  } catch (e) {
    _log.warning('Could not remove the imported-file folder: $e');
  }
}
