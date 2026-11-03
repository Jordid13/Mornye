import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/history_database.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_offline_save.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:path/path.dart' as p;

const _webdav = 'network://conn1/Mornye/Artist/Album/Song%20-%20Artist.flac';
const _scanned = 'network://conn1/Mornye/Band/Record/Other.flac';

final _bytes = List<int>.generate(4096, (i) => i % 251);

/// A network download's record, as Mornye writes it after publishing a
/// download to a network destination.
UnifiedLibraryItem _download({String path = _webdav}) =>
    UnifiedLibraryItem.fromDownloadHistory(
      DownloadHistoryItem(
        id: 'dl1',
        trackName: 'Song',
        artistName: 'Artist',
        albumName: 'Album',
        filePath: path,
        storageMode: 'network',
        service: 'tidal',
        downloadedAt: DateTime(2026, 11, 1),
        format: 'flac',
      ),
    );

UnifiedLibraryItem _row({String path = _scanned}) =>
    UnifiedLibraryItem.fromLocalLibrary(
      LocalLibraryItem(
        id: 'row1',
        trackName: 'Other',
        artistName: 'Band',
        albumName: 'Record',
        filePath: path,
        scannedAt: DateTime(2026),
        format: 'flac',
      ),
    );

class _Transport implements LinkOfflineTransport {
  final requested = <String>[];

  @override
  Future<void> download(
    String source,
    File output, {
    required void Function() checkpoint,
    required void Function(int received, int? total) progress,
  }) async {
    requested.add(source);
    await output.writeAsBytes(_bytes);
    progress(_bytes.length, _bytes.length);
  }

  @override
  void close() {}
}

class _Destination implements LinkOfflineDestination {
  _Destination(this.root);

  final Directory root;

  @override
  Future<LinkOfflineStored> store(
    File file, {
    required String relativeDir,
    required String fileName,
    required String mimeType,
  }) async {
    final target = File(p.join(root.path, relativeDir, fileName));
    await target.parent.create(recursive: true);
    await file.copy(target.path);
    return LinkOfflineStored(filePath: target.path, storageMode: 'app');
  }
}

/// Answers every song with one location, a local test server or file.
class _Storage extends NetworkStorageService {
  _Storage(this.location)
    : super(
        read: () async => null,
        write: (_) async {},
        ensureAccess: (_) async {},
      );

  final String location;

  @override
  Future<String> resolve(String source) async => location;
}

class _History implements HistoryDatabase {
  final rows = <String, Map<String, dynamic>>{};

  @override
  Future<Map<String, dynamic>?> findByFilePath(String filePath) async =>
      rows.values.where((row) => row['filePath'] == filePath).firstOrNull;

  @override
  Future<void> upsert(Map<String, dynamic> json) async =>
      rows[json['id'] as String] = json;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late Directory temp;
  late Directory documents;
  late File originsFile;
  late NetworkOfflineOrigins origins;
  late _Transport transport;
  late NetworkOfflineSaver saver;

  NetworkOfflineOrigins newOrigins([Directory? docs]) => NetworkOfflineOrigins(
    file: () async => originsFile,
    documents: () async => docs ?? documents,
  );

  /// A service whose only connection refuses connections, with [source]
  /// saved to this device.
  Future<NetworkStorageService> offlineStorage(String source) async {
    final copy = File(p.join(documents.path, 'Mornye', 'saved.flac'));
    await copy.parent.create(recursive: true);
    await copy.writeAsBytes(_bytes);
    await origins.put(source, copy.path);
    return NetworkStorageService(
      read: () async => jsonEncode([
        const NetworkConnection(
          id: 'conn1',
          name: 'down',
          protocol: NetworkProtocol.webdav,
          address: 'http://127.0.0.1:1/',
        ).toJson(),
      ]),
      write: (_) async {},
      ensureAccess: (_) async {},
      offlineCopies: origins,
    );
  }

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('network_offline');
    documents = Directory(p.join(temp.path, 'container', 'Documents'));
    await documents.create(recursive: true);
    originsFile = File(p.join(temp.path, 'origins.json'));
    origins = newOrigins();
    transport = _Transport();
    saver = NetworkOfflineSaver(
      destination: _Destination(Directory(p.join(documents.path, 'Mornye'))),
      deleteLocalFile: (path) async {
        await File(path).delete();
        return true;
      },
      temporaryDirectory: () async => temp,
      origins: origins,
      openTransport: () => transport,
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('a saved song keeps its network path and gets a copy', () async {
    final result = await saver.save([_download(), _row()]);

    expect(result.saved, 2);
    expect(transport.requested, [_webdav, _scanned]);
    for (final source in [_webdav, _scanned]) {
      final copy = origins.copyOf(source)!;
      expect(copy, startsWith(documents.path));
      expect(await File(copy).readAsBytes(), _bytes);
      expect(origins.isSaved(source), isTrue);
    }
  });

  test('only network songs are saved, each once, and never twice', () async {
    final download = _download();
    await saver.save([download, download, _download(path: '/var/song.flac')]);
    final again = await saver.save([download]);

    expect(transport.requested, [_webdav]);
    expect(again.skipped, 1);
  });

  test('removing a copy keeps the song on the server', () async {
    await saver.save([_row()]);
    final copy = origins.copyOf(_scanned)!;

    expect(await saver.remove(_scanned), isTrue);
    expect(await File(copy).exists(), isFalse);
    expect(origins.isSaved(_scanned), isFalse);
    expect(await saver.remove(_scanned), isFalse);
  });

  test('a copy deleted outside the app is forgotten', () async {
    await saver.save([_row()]);
    await File(origins.copyOf(_scanned)!).delete();

    expect(await origins.existingCopyOf(_scanned), isNull);
    expect(origins.isSaved(_scanned), isFalse);
  });

  test('copies survive a restart and a moved iOS container', () async {
    const container = '/var/mobile/Containers/Data/Application';
    originsFile.writeAsStringSync(
      jsonEncode({
        _scanned:
            '$container/0A1B2C3D-0000-4000-8000-000000000001/Documents/Mornye/a.flac',
      }),
    );
    final reloaded = newOrigins(
      Directory('$container/9F8E7D6C-0000-4000-8000-000000000002/Documents'),
    );
    await reloaded.load();

    expect(
      reloaded.copyOf(_scanned),
      '$container/9F8E7D6C-0000-4000-8000-000000000002/Documents/Mornye/a.flac',
    );
  });

  test('download records the first builds moved are pointed back', () async {
    final copy = p.join(documents.path, 'Mornye', 'Song.flac');
    originsFile.writeAsStringSync(
      jsonEncode({
        'Documents/Mornye/Song.flac': {'source': _webdav, 'restore': true},
      }),
    );
    final history = _History()
      ..rows['dl1'] = {'id': 'dl1', 'filePath': copy, 'storageMode': 'app'};
    final legacy = newOrigins();

    await restoreLegacyNetworkDownloads(origins: legacy, history: history);

    expect(history.rows['dl1']!['filePath'], _webdav);
    expect(history.rows['dl1']!['storageMode'], 'network');
    expect(legacy.copyOf(_webdav), copy);
    expect(jsonDecode(originsFile.readAsStringSync()), {_webdav: copy});
  });

  test('an unreadable list is never overwritten, and leaves no copy', () async {
    originsFile.writeAsStringSync('{not json');
    final result = await saver.save([_row()]);

    expect(result.failed, 1);
    expect(originsFile.readAsStringSync(), '{not json');
    expect(
      Directory(
        p.join(documents.path, 'Mornye'),
      ).listSync(recursive: true).whereType<File>(),
      isEmpty,
    );
  });

  test('only the exact legacy record is pointed back', () async {
    final copy = p.join(documents.path, 'Mornye', 'Song.flac');
    originsFile.writeAsStringSync(
      jsonEncode({
        'Documents/Mornye/Song.flac': {'source': _webdav, 'restore': true},
      }),
    );
    // Path keys also match this other file (same name, other extension).
    final history = _History()
      ..rows['other'] = {
        'id': 'other',
        'filePath': copy.replaceFirst('.flac', '.m4a'),
        'storageMode': 'app',
      };

    await restoreLegacyNetworkDownloads(
      origins: newOrigins(),
      history: history,
    );

    expect(history.rows['other']!['storageMode'], 'app');
  });

  test('a saved song plays from its copy while the server is down', () async {
    final storage = await offlineStorage(_scanned);
    final client = HttpClient();
    try {
      expect(await storage.reachable(_scanned), isTrue);
      final url = Uri.parse(await storage.resolve(_scanned));
      expect(url.host, '127.0.0.1', reason: 'still the proxy, for tag reads');
      final whole = await (await client.getUrl(url)).close();
      expect(await whole.expand((chunk) => chunk).toList(), _bytes);
      final request = await client.getUrl(url);
      request.headers.set(HttpHeaders.rangeHeader, 'bytes=100-199');
      final part = await request.close();
      expect(part.statusCode, 206);
      expect(await part.expand((c) => c).toList(), _bytes.sublist(100, 200));
    } finally {
      client.close(force: true);
      await storage.dispose();
    }
  });

  test('a saved song is never deleted from the server', () async {
    final storage = await offlineStorage(_scanned);
    try {
      expect(await storage.canDeleteFile(_scanned), isFalse);
      expect(await storage.deleteFile(_scanned), isFalse);
      // Nor when its copy went missing: it still shows as saved.
      await File(origins.copyOf(_scanned)!).delete();
      expect(await storage.deleteFile(_scanned), isFalse);
    } finally {
      await storage.dispose();
    }
  });

  test('removing a connection removes its copies', () async {
    final storage = await offlineStorage(_scanned);
    final copy = origins.copyOf(_scanned)!;
    try {
      await storage.remove('conn1');
      expect(origins.isSaved(_scanned), isFalse);
      expect(await File(copy).exists(), isFalse);
    } finally {
      await storage.dispose();
    }
  });

  test('a proxy closed in the background comes back on its port', () async {
    final storage = await offlineStorage(_scanned);
    final client = HttpClient();
    Future<List<int>> fetch(String url) async => (await (await client.getUrl(
      Uri.parse(url),
    )).close()).expand((chunk) => chunk).toList();
    try {
      final before = await storage.resolve(_scanned);
      expect(await fetch(before), _bytes);
      // What iOS does to a suspended app's listening socket.
      await storage.debugCloseProxy();
      final after = await storage.resolve(_scanned);
      expect(Uri.parse(after).port, Uri.parse(before).port);
      expect(await fetch(after), _bytes);
      expect(await fetch(before), _bytes, reason: 'earlier addresses work');
    } finally {
      client.close(force: true);
      await storage.dispose();
    }
  });

  group('NetworkFileTransport', () {
    late HttpServer server;
    late int? declared;

    setUp(() async {
      declared = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = declared ?? _bytes.length;
        request.response.add(_bytes);
        await request.response.close().catchError((Object _) {});
      });
    });

    tearDown(() => server.close(force: true));

    NetworkFileTransport served() => NetworkFileTransport(
      storage: _Storage('http://127.0.0.1:${server.port}/song'),
    );

    Future<void> download(NetworkFileTransport transport, File output) =>
        transport.download(
          _webdav,
          output,
          checkpoint: () {},
          progress: (_, _) {},
        );

    test('streams the original file', () async {
      final output = File(p.join(temp.path, 'out.flac'));
      final transport = served();
      await download(transport, output);
      transport.close();

      expect(await output.readAsBytes(), _bytes);
    });

    test('a cut-off response fails instead of saving half a song', () async {
      declared = _bytes.length * 2;
      final transport = served();
      await expectLater(
        download(transport, File(p.join(temp.path, 'out.flac'))),
        throwsA(anything),
      );
      transport.close();
    });

    test('a local file from a virtual source is copied', () async {
      final local = File(p.join(temp.path, 'local.flac'))
        ..writeAsBytesSync(_bytes);
      final output = File(p.join(temp.path, 'out.flac'));
      await download(
        NetworkFileTransport(storage: _Storage(local.path)),
        output,
      );

      expect(await output.readAsBytes(), _bytes);
    });
  });
}
