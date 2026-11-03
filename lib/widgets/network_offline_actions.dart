import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/download_history_provider.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/network_offline_save.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';

final _log = AppLogger('NetworkOfflineSave');

/// Saves network songs into the download folder the settings choose.
final networkOfflineSaverProvider = Provider<NetworkOfflineSaver>((ref) {
  final history = ref.watch(downloadHistoryProvider.notifier);
  return NetworkOfflineSaver(
    destination: LinkDownloadFolderDestination(ref.watch(settingsProvider)),
    record: history.addToHistory,
    forget: history.removeFromHistory,
    deleteLocalFile: deleteFile,
    temporaryDirectory: getTemporaryDirectory,
  );
});

/// Runs one save at a time, in the order they were asked for.
Future<void> _queue = Future.value();

/// The network songs among [items] that "Save to this phone" of Mornye Link
/// does not already cover: those not from the paired desktop.
List<UnifiedLibraryItem> networkSavableItems(
  WidgetRef ref,
  Iterable<UnifiedLibraryItem> items,
) {
  final server = ref.read(linkPhoneClientProvider)?.server;
  return networkSongItems(items)
      .where(
        (item) =>
            server == null || linkDesktopSongId(item.filePath, server) == null,
      )
      .toList(growable: false);
}

/// "Save to this phone" for network songs: copies them into the download
/// folder in the background and says when it starts and ends.
void networkSaveToPhone(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) {
  final songs = networkSongItems(items);
  if (songs.isEmpty) return;
  final saver = ref.read(networkOfflineSaverProvider);
  final root = Navigator.of(context, rootNavigator: true).context;
  final l10n = context.l10n;
  showAppSnackBar(
    context,
    content: Text(l10n.networkSaveStarted(songs.length, songs.first.trackName)),
  );
  _queue = _queue.then((_) async {
    String message;
    try {
      final result = await saver.save(songs);
      message = result.failed == 0
          ? l10n.networkSaveFinished(result.saved + result.skipped)
          : l10n.networkSaveFailed(result.failed);
    } on LinkOfflineNoFolder {
      message = l10n.networkSaveFailed(songs.length);
    } on Object catch (error, stack) {
      _log.e('Saving network songs failed: $error', error, stack);
      message = l10n.networkSaveFailed(songs.length);
    }
    if (root.mounted) showAppSnackBar(root, content: Text(message));
  });
}

/// Whether [item] is a phone copy of a network song.
bool isNetworkPhoneCopy(DownloadHistoryItem? item) =>
    item != null &&
    NetworkOfflineOrigins.instance.cached(item.filePath) != null;

/// "Remove from this phone": deletes the phone copy [item] records, keeping
/// the song on the server.
Future<void> networkRemoveFromPhone(
  BuildContext context,
  WidgetRef ref,
  DownloadHistoryItem item,
) async {
  final l10n = context.l10n;
  final removed = await ref.read(networkOfflineSaverProvider).remove(item);
  if (context.mounted && removed) {
    showAppSnackBar(context, content: Text(l10n.networkRemovedFromPhone));
  }
}

/// The Library selection toolbar's "Save to this phone" for network songs.
List<Widget> networkSaveSelectionActions(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items, {
  required VoidCallback onClose,
}) {
  final songs = networkSavableItems(ref, items);
  if (songs.isEmpty) return const [];
  return [
    SelectionActionButton(
      icon: Icons.phone_android,
      label: context.l10n.linkSaveToPhone,
      colorScheme: Theme.of(context).colorScheme,
      onPressed: () {
        networkSaveToPhone(context, ref, songs);
        onClose();
      },
    ),
  ];
}
