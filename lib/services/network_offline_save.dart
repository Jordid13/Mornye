import 'dart:io';

import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_offline_origins.dart';
import 'package:mornye/services/network_storage_service.dart';

export 'package:mornye/services/network_offline_origins.dart';

/// Saves songs that stream from network storage (`network://`: WebDAV, SMB,
/// HTTP) to this phone, with the same saver as Mornye Link's "Save to this
/// phone": the original file goes into the download folder and
/// [NetworkOfflineOrigins] notes it. The song's Library row or download
/// record stays as it is; [NetworkStorageService] serves it from the copy.
/// The server file is never changed.

/// Fetches a network song's original file through [NetworkStorageService]'s
/// proxy, with its credentials and trusted certificate.
class NetworkFileTransport implements LinkOfflineTransport {
  NetworkFileTransport({NetworkStorageService? storage})
    : _storage = storage ?? NetworkStorageService.instance;

  final NetworkStorageService _storage;
  HttpClient? _client;
  bool _closed = false;

  @override
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    if (_closed) throw StateError('Network download closed');
    final location = await _storage.resolve(source);
    final local = _localFile(location);
    if (local != null) {
      // Virtual sources may answer with a file this device already has.
      final copy = await local.copy(output.path);
      final size = await copy.length();
      progress(size, size);
      return;
    }
    final client = _client ??= HttpClient();
    final response = await (await client.getUrl(Uri.parse(location))).close();
    if (response.statusCode != HttpStatus.ok) {
      await response.drain<void>();
      throw HttpException('Network song answered ${response.statusCode}');
    }
    final total = response.contentLength >= 0 ? response.contentLength : null;
    final sink = output.openWrite();
    var received = 0;
    try {
      await for (final chunk in response) {
        checkpoint();
        sink.add(chunk);
        received += chunk.length;
        progress(received, total);
      }
      await sink.flush();
    } finally {
      await sink.close();
    }
    if (total != null && received != total) {
      throw const HttpException('Network song ended early');
    }
  }

  static File? _localFile(String location) {
    if (location.startsWith('/')) return File(location);
    final uri = Uri.tryParse(location);
    return uri != null && uri.isScheme('file') ? File(uri.toFilePath()) : null;
  }

  @override
  void close() {
    _closed = true;
    _client?.close(force: true);
    _client = null;
  }
}

/// The network songs among [items], once each.
List<UnifiedLibraryItem> networkSongItems(Iterable<UnifiedLibraryItem> items) {
  final seen = <String>{};
  return [
    for (final item in items)
      if (item.filePath.startsWith('network://') && seen.add(item.filePath))
        item,
  ];
}

LocalLibraryItem _songOf(UnifiedLibraryItem item) {
  if (item.localItem case final local?) return local;
  final history = item.historyItem!;
  return LocalLibraryItem(
    id: history.id,
    trackName: history.trackName,
    artistName: history.artistName,
    albumName: history.albumName,
    albumArtist: history.albumArtist,
    filePath: history.filePath,
    coverPath: history.coverUrl,
    scannedAt: history.downloadedAt,
    isrc: history.isrc,
    trackNumber: history.trackNumber,
    discNumber: history.discNumber,
    duration: history.duration,
    releaseDate: history.releaseDate,
    bitDepth: history.bitDepth,
    sampleRate: history.sampleRate,
    bitrate: history.bitrate,
    genre: history.genre,
    explicit: history.explicit,
    format: history.format,
  );
}

/// Saves network songs to this phone and removes those copies again.
class NetworkOfflineSaver {
  NetworkOfflineSaver({
    required this.destination,
    required this.deleteLocalFile,
    required this.temporaryDirectory,
    NetworkOfflineOrigins? origins,
    LinkOfflineTransport Function()? openTransport,
  }) : origins = origins ?? NetworkOfflineOrigins.instance,
       openTransport = openTransport ?? NetworkFileTransport.new;

  final LinkOfflineDestination destination;
  final Future<bool> Function(String path) deleteLocalFile;
  final Future<Directory> Function() temporaryDirectory;
  final NetworkOfflineOrigins origins;
  final LinkOfflineTransport Function() openTransport;

  /// Saves the network songs among [items], skipping those this phone has.
  Future<LinkOfflineResult> save(
    List<UnifiedLibraryItem> items, {
    void Function(LinkOfflineProgress progress)? onProgress,
    LinkOfflineCancel? cancel,
  }) {
    final songs = networkSongItems(items);
    final sourceBySaverId = <String, String>{};
    final saver = LinkOfflineSaver(
      serverId: 'network',
      openTransport: openTransport,
      destination: destination,
      temporaryDirectory: temporaryDirectory,
      record: (saved) =>
          origins.put(sourceBySaverId[saved.id]!, saved.filePath),
      exists: (id) async =>
          await origins.existingCopyOf(sourceBySaverId[id]!) != null,
    );
    for (final item in songs) {
      sourceBySaverId[saver.historyId(item.filePath)] = item.filePath;
    }
    return saver.save(
      [
        for (final item in songs)
          LinkOfflineSong(item: _songOf(item), songId: item.filePath),
      ],
      onProgress: onProgress,
      cancel: cancel,
    );
  }

  /// Deletes the phone copy of [source], keeping the song on the server.
  /// Returns false when it has none or the copy stays.
  Future<bool> remove(String source) async {
    await origins.load();
    final copy = origins.copyOf(source);
    if (copy == null) return false;
    if (await File(copy).exists() && !await deleteLocalFile(copy)) return false;
    await origins.remove(source);
    return true;
  }
}

/// Points download records the first builds moved onto a phone copy back at
/// their network song, which now plays the copy itself.
Future<void> restoreLegacyNetworkDownloads({
  NetworkOfflineOrigins? origins,
  HistoryDatabase? history,
}) async {
  final copies = origins ?? NetworkOfflineOrigins.instance;
  final db = history ?? HistoryDatabase.instance;
  await copies.load();
  final legacy = copies.legacyDownloads;
  if (legacy.isEmpty) return;
  for (final MapEntry(key: copy, value: source) in legacy.entries) {
    final json = await db.findByFilePath(copy);
    if (json == null || json['filePath'] == source) continue;
    await db.upsert({...json, 'filePath': source, 'storageMode': 'network'});
  }
  // Written once in the current format, without the legacy flags.
  final first = legacy.values.first;
  await copies.put(first, copies.copyOf(first)!);
}
