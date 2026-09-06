import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:submersion/core/providers/ref_invalidate_on_change.dart';
import 'package:submersion/core/services/database_service.dart';
import 'package:submersion/features/dive_import/data/services/dive_resync_orchestrator.dart';
import 'package:submersion/features/dive_import/data/services/imported_file_store.dart';
import 'package:submersion/features/dive_log/presentation/providers/dive_repository_provider.dart';

/// Shared [ImportedFileStore]; overridable so tests can point it at a temp
/// documents directory.
final importedFileStoreProvider = Provider<ImportedFileStore>(
  (ref) => ImportedFileStore(),
);

/// Provider for the [DiveResyncOrchestrator] singleton.
final diveResyncOrchestratorProvider = Provider<DiveResyncOrchestrator>((ref) {
  final db = DatabaseService.instance.database;
  return DiveResyncOrchestrator(
    db: db,
    importedFileStore: ref.watch(importedFileStoreProvider),
  );
});

/// Whether [diveId] has a stored original file it can be resynced from
/// (Task 3's `dive_data_sources.imported_file_path`), still readable HERE.
///
/// The path column syncs verbatim, so a peer that never imported the file
/// holds a pointer to bytes it does not have. Gating on the pointer alone
/// would offer the action there, so the existence check -- which resolves a
/// documents-relative path against this device's own documents directory --
/// is part of the answer.
final diveHasImportedFileProvider = FutureProvider.family<bool, String>((
  ref,
  diveId,
) async {
  ref.invalidateSelfWhen(
    ref.watch(diveRepositoryProvider).watchDiveDetailChanges(),
  );
  final db = DatabaseService.instance.database;
  final source =
      await (db.select(db.diveDataSources)
            ..where((t) => t.diveId.equals(diveId))
            ..where((t) => t.isPrimary.equals(true))
            ..limit(1))
          .getSingleOrNull();
  final path = source?.importedFilePath;
  if (path == null) return false;
  return ref.read(importedFileStoreProvider).exists(path);
});
