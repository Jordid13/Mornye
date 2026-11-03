import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_storage_service.dart';

/// Saves songs that stream from network storage (`network://`: WebDAV, SMB,
/// HTTP, Subsonic) to this phone, with the same saver as Mornye Link's
/// "Save to this phone": the original file goes into the download folder and
/// a history record makes it a Library download.
///
/// A song that already has a history record (a download published to the
/// network destination) keeps that one record, now pointing at the phone
/// copy. [NetworkOfflineOrigins] remembers the server file, so "Remove from
/// this phone" points the record back at it. The server file is never
/// changed.

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

/// Where a phone copy came from.
class NetworkOrigin {
  const NetworkOrigin(this.source, {required this.restore});

  /// The `network://` song the copy was saved from.
  final String source;

  /// Whether removing the copy points its history record back at [source]
  /// (it was a network download's record) instead of deleting the record.
  final bool restore;
}

/// Phone copies and the network songs they came from, kept in their own
/// file beside the download history, so the history schema stays upstream's
/// and an official build simply ignores it.
class NetworkOfflineOrigins {
  NetworkOfflineOrigins({
    Future<File> Function()? file,
    Future<Directory> Function()? documents,
  }) : _file = file ?? _defaultFile,
       _documents = documents ?? getApplicationDocumentsDirectory;

  static final instance = NetworkOfflineOrigins();

  final Future<File> Function() _file;
  final Future<Directory> Function() _documents;
  Map<String, NetworkOrigin>? _entries;
  Future<void> _mutation = Future.value();

  static Future<File> _defaultFile() async => File(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'network_offline_origins.json',
    ),
  );

  /// iOS moves the app's container on updates, so copies under Documents
  /// are keyed relative to it.
  static String _key(String path) {
    final index = path.indexOf('/Documents/');
    return index < 0 ? path : path.substring(index + 1);
  }

  Future<String> _path(String key) async => key.startsWith('Documents/')
      ? p.join((await _documents()).parent.path, key)
      : key;

  Future<Map<String, NetworkOrigin>> load() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, NetworkOrigin>{};
    try {
      final json = jsonDecode(await (await _file()).readAsString());
      if (json is Map) {
        json.forEach((key, value) {
          if (key is! String || value is! Map) return;
          final source = value['source'];
          if (source is String) {
            entries[key] = NetworkOrigin(
              source,
              restore: value['restore'] == true,
            );
          }
        });
      }
    } on Object {
      // No file yet, or unreadable: no copies are known.
    }
    return _entries ??= entries;
  }

  /// The origin of the phone copy at [path], once [load] has run.
  NetworkOrigin? cached(String path) => _entries?[_key(path)];

  Future<NetworkOrigin?> of(String path) async => (await load())[_key(path)];

  /// Whether a phone copy of [source] is still there.
  Future<bool> hasCopyOf(String source) async {
    for (final entry in (await load()).entries) {
      if (entry.value.source == source &&
          await File(await _path(entry.key)).exists()) {
        return true;
      }
    }
    return false;
  }

  Future<void> put(String path, NetworkOrigin origin) =>
      _write((entries) => entries[_key(path)] = origin);

  Future<void> remove(String path) =>
      _write((entries) => entries.remove(_key(path)));

  Future<void> _write(void Function(Map<String, NetworkOrigin>) change) {
    final next = _mutation.then((_) async {
      final entries = await load();
      change(entries);
      final file = await _file();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(
        jsonEncode({
          for (final entry in entries.entries)
            entry.key: {
              'source': entry.value.source,
              'restore': entry.value.restore,
            },
        }),
      );
      // Atomic: a crash never leaves half a file.
      await temp.rename(file.path);
    });
    _mutation = next.catchError((Object _) {});
    return next;
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
    required this.record,
    required this.forget,
    required this.deleteLocalFile,
    required this.temporaryDirectory,
    NetworkOfflineOrigins? origins,
    LinkOfflineTransport Function()? openTransport,
  }) : origins = origins ?? NetworkOfflineOrigins.instance,
       openTransport = openTransport ?? NetworkFileTransport.new;

  final LinkOfflineDestination destination;

  /// Adds or replaces a history record.
  final Future<void> Function(DownloadHistoryItem item) record;

  /// Removes the history record with this id.
  final Future<void> Function(String id) forget;
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
    final bySaverId = <String, UnifiedLibraryItem>{};
    final saver = LinkOfflineSaver(
      serverId: 'network',
      openTransport: openTransport,
      destination: destination,
      temporaryDirectory: temporaryDirectory,
      record: (saved) async {
        final item = bySaverId[saved.id]!;
        final download = item.historyItem;
        // A network download's record now points at the phone copy.
        await record(
          download == null
              ? saved
              : download.copyWith(
                  filePath: saved.filePath,
                  storageMode: saved.storageMode,
                  downloadTreeUri: saved.downloadTreeUri,
                  safRelativeDir: saved.safRelativeDir,
                  safFileName: saved.safFileName,
                ),
        );
        await origins.put(
          saved.filePath,
          NetworkOrigin(item.filePath, restore: download != null),
        );
      },
      exists: (id) => origins.hasCopyOf(bySaverId[id]!.filePath),
    );
    for (final item in songs) {
      bySaverId[saver.historyId(item.filePath)] = item;
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

  /// Deletes the phone copy [item] records, keeping the server file. Returns
  /// false when [item] is not a copy of a network song or stays.
  Future<bool> remove(DownloadHistoryItem item) async {
    final origin = await origins.of(item.filePath);
    if (origin == null || !await deleteLocalFile(item.filePath)) return false;
    if (origin.restore) {
      await record(
        item.copyWith(filePath: origin.source, storageMode: 'network'),
      );
    } else {
      await forget(item.id);
    }
    await origins.remove(item.filePath);
    return true;
  }
}
