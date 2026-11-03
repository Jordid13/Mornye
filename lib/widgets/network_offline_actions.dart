import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:mornye/l10n/l10n.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/providers/settings_provider.dart';
import 'package:mornye/services/link/features/link_phone_client.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/link/features/link_track_refs.dart';
import 'package:mornye/services/network_offline_save.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:mornye/utils/file_access.dart';
import 'package:mornye/utils/logger.dart';
import 'package:mornye/widgets/app_snack_bar.dart';
import 'package:mornye/widgets/selection_action_button.dart';

final _log = AppLogger('NetworkOfflineSave');

/// Saves network songs into the download folder the settings choose. Copies
/// are read as plain files, so a storage-access (SAF) folder is not used.
final networkOfflineSaverProvider = Provider<NetworkOfflineSaver>((ref) {
  final settings = ref.watch(settingsProvider);
  return NetworkOfflineSaver(
    destination: LinkDownloadFolderDestination(
      settings.storageMode == 'saf'
          ? settings.copyWith(storageMode: 'app')
          : settings,
    ),
    deleteLocalFile: deleteFile,
    temporaryDirectory: getTemporaryDirectory,
  );
});

/// Runs one save at a time, in the order they were asked for.
Future<void> _queue = Future.value();

/// Rebuilds [builder] with whether the song at [path] is saved to this
/// device, as copies are saved or removed.
class NetworkCopyBuilder extends StatelessWidget {
  const NetworkCopyBuilder({
    super.key,
    required this.path,
    required this.builder,
  });

  final String path;
  final Widget Function(BuildContext context, bool saved) builder;

  @override
  Widget build(BuildContext context) => ValueListenableBuilder<int>(
    valueListenable: NetworkOfflineOrigins.instance.revision,
    builder: (context, _, _) =>
        builder(context, NetworkOfflineOrigins.instance.isSaved(path)),
  );
}

/// The tag for where a network song is, or null for other songs.
String? networkLocationLabel(BuildContext context, String path, bool saved) =>
    !path.startsWith('network://')
    ? null
    : saved
    ? context.l10n.librarySourceDownloaded
    : context.l10n.networkServer;

/// The network songs among [items] that can be saved: not saved yet, and
/// not a Mornye Link song, which Link saves itself.
List<UnifiedLibraryItem> networkSavableItems(
  WidgetRef ref,
  Iterable<UnifiedLibraryItem> items,
) {
  final server = ref.read(linkPhoneClientProvider)?.server;
  final storage = NetworkStorageService.instance;
  return networkSongItems(items)
      .where((item) {
        final host = Uri.parse(item.filePath).host;
        return !NetworkOfflineOrigins.instance.isSaved(item.filePath) &&
            storage.virtualFor(host) == null &&
            (server == null ||
                linkDesktopSongId(item.filePath, server) == null);
      })
      .toList(growable: false);
}

/// "Save to this phone" for network songs: copies them into the download
/// folder in the background, says when it starts, and can be cancelled.
void networkSaveToPhone(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items,
) {
  final songs = networkSavableItems(ref, items);
  if (songs.isEmpty) return;
  final saver = ref.read(networkOfflineSaverProvider);
  final root = Navigator.of(context, rootNavigator: true).context;
  final l10n = context.l10n;
  final cancel = LinkOfflineCancel();
  showAppSnackBar(
    context,
    content: Text(l10n.linkSavingToPhone),
    action: SnackBarAction(label: l10n.dialogCancel, onPressed: cancel.cancel),
  );
  _queue = _queue.then((_) async {
    String? message;
    try {
      final result = await saver.save(songs, cancel: cancel);
      if (!result.cancelled) {
        message = result.failed == 0
            ? l10n.linkSavedToPhone(result.saved + result.skipped)
            : l10n.linkSaveToPhoneFailed(result.failed);
      }
    } on Object catch (error, stack) {
      _log.e('Saving network songs failed: $error', error, stack);
      message = l10n.linkSaveToPhoneFailed(songs.length);
    }
    if (message != null && root.mounted) {
      showAppSnackBar(root, content: Text(message));
    }
  });
}

/// "Remove from this phone": deletes the phone copies of [sources], keeping
/// the songs on the server.
Future<void> networkRemoveFromPhone(
  BuildContext context,
  WidgetRef ref,
  Iterable<String> sources,
) async {
  final l10n = context.l10n;
  final saver = ref.read(networkOfflineSaverProvider);
  var removed = 0;
  for (final source in sources) {
    if (await saver.remove(source)) removed++;
  }
  if (removed > 0 && context.mounted) {
    showAppSnackBar(context, content: Text(l10n.networkRemovedFromPhone));
  }
}

/// The Library selection toolbar's "Save to this phone" and "Remove from
/// this phone" for network songs.
List<Widget> networkSaveSelectionActions(
  BuildContext context,
  WidgetRef ref,
  List<UnifiedLibraryItem> items, {
  required VoidCallback onClose,
}) {
  final savable = networkSavableItems(ref, items);
  final saved = [
    for (final item in items)
      if (NetworkOfflineOrigins.instance.isSaved(item.filePath)) item.filePath,
  ];
  final colors = Theme.of(context).colorScheme;
  return [
    if (savable.isNotEmpty)
      SelectionActionButton(
        icon: Icons.phone_android,
        label: context.l10n.linkSaveToPhone,
        colorScheme: colors,
        onPressed: () {
          networkSaveToPhone(context, ref, savable);
          onClose();
        },
      ),
    if (saved.isNotEmpty)
      SelectionActionButton(
        icon: Icons.cloud_done_outlined,
        label: context.l10n.networkRemoveFromPhone,
        colorScheme: colors,
        onPressed: () {
          final root = Navigator.of(context, rootNavigator: true).context;
          final removing = networkRemoveFromPhone(root, ref, saved);
          onClose();
          unawaited(removing);
        },
      ),
  ];
}
