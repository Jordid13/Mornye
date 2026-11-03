import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mornye/models/download_history.dart';
import 'package:mornye/models/library_database_models.dart';
import 'package:mornye/models/unified_library_item.dart';
import 'package:mornye/services/link/features/link_save_offline.dart';
import 'package:mornye/services/network_offline_save.dart';
import 'package:mornye/services/network_storage_service.dart';
import 'package:path/path.dart' as p;

const _webdav = 'network://conn1/Mornye/Artist/Album/Song%20-%20Artist.flac';
const _subsonic = 'network://conn2/subsonic/song/abc.flac';

final _bytes = List<int>.generate(4096, (i) => i % 251);

/// A server download's history record: what Mornye writes after publishing
/// to a network destination.
DownloadHistoryItem _download({String path = _webdav}) => DownloadHistoryItem(
  id: 'dl1',
  trackName: 'Song',
  artistName: 'Artist',
  albumName: 'Album',
  albumArtist: 'Artist',
  filePath: path,
  storageMode: 'network',
  service: 'tidal',
  downloadedAt: DateTime(2026, 11, 1),
  isrc: 'USABC2600001',
  format: 'flac',
);

LocalLibraryItem _row({String path = _subsonic}) => LocalLibraryItem(
  id: 'row1',
  trackName: 'Other',
  artistName: 'Band',
  albumName: 'Record',
  filePath: path,
  scannedAt: DateTime(2026),
  format: 'flac',
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

/// Answers every song with a URL on a local test server.
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

void main() {
  late Directory temp;
  late Directory documents;
  late File originsFile;
  late List<DownloadHistoryItem> records;
  late List<String> forgotten;
  late _Transport transport;
  late NetworkOfflineSaver saver;

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('network_offline');
    documents = Directory(p.join(temp.path, 'container', 'Documents'));
    await documents.create(recursive: true);
    originsFile = File(p.join(temp.path, 'origins.json'));
    records = [];
    forgotten = [];
    transport = _Transport();
    saver = NetworkOfflineSaver(
      destination: _Destination(Directory(p.join(documents.path, 'Mornye'))),
      record: (item) async => records.add(item),
      forget: (id) async => forgotten.add(id),
      deleteLocalFile: (path) async {
        await File(path).delete();
        return true;
      },
      temporaryDirectory: () async => temp,
      origins: NetworkOfflineOrigins(
        file: () async => originsFile,
        documents: () async => documents,
      ),
      openTransport: () => transport,
    );
  });

  tearDown(() => temp.delete(recursive: true));

  test('a server download keeps its one record, now on the phone', () async {
    final result = await saver.save([
      UnifiedLibraryItem.fromDownloadHistory(_download()),
    ]);

    expect(result.saved, 1);
    expect(transport.requested, [_webdav]);
    final saved = records.single;
    expect(saved.id, 'dl1', reason: 'same record, no duplicate entry');
    expect(saved.service, 'tidal');
    expect(saved.storageMode, 'app');
    expect(saved.filePath, startsWith(documents.path));
    expect(await File(saved.filePath).readAsBytes(), _bytes);
  });

  test('a scanned network song gets a record of its own', () async {
    await saver.save([UnifiedLibraryItem.fromLocalLibrary(_row())]);

    final saved = records.single;
    expect(saved.id, isNot('row1'));
    expect(saved.trackName, 'Other');
    expect(await File(saved.filePath).exists(), isTrue);
  });

  test('only network songs are saved, each once', () async {
    final download = UnifiedLibraryItem.fromDownloadHistory(_download());
    final phone = UnifiedLibraryItem.fromDownloadHistory(
      _download(path: '/var/mobile/song.flac'),
    );
    await saver.save([download, download, phone]);

    expect(transport.requested, [_webdav]);
  });

  test('a song already on the phone is skipped', () async {
    final item = UnifiedLibraryItem.fromDownloadHistory(_download());
    await saver.save([item]);
    final again = await saver.save([item]);

    expect(again.skipped, 1);
    expect(transport.requested, [_webdav]);
  });

  test(
    'removing a download copy points the record back at the server',
    () async {
      await saver.save([UnifiedLibraryItem.fromDownloadHistory(_download())]);
      final copy = records.single;

      expect(await saver.remove(copy), isTrue);
      expect(await File(copy.filePath).exists(), isFalse);
      final restored = records.last;
      expect(restored.id, 'dl1');
      expect(restored.filePath, _webdav);
      expect(restored.storageMode, 'network');
      expect(forgotten, isEmpty);
    },
  );

  test('removing a scanned song copy deletes its record', () async {
    await saver.save([UnifiedLibraryItem.fromLocalLibrary(_row())]);
    final copy = records.single;

    expect(await saver.remove(copy), isTrue);
    expect(forgotten, [copy.id]);
  });

  test('remove leaves other downloads alone', () async {
    expect(await saver.remove(_download(path: '/var/mobile/x.flac')), isFalse);
    expect(records, isEmpty);
  });

  test('origins survive a restart and a moved iOS container', () async {
    await saver.save([UnifiedLibraryItem.fromDownloadHistory(_download())]);
    final copy = records.single;

    // A new container path for the same Documents-relative file.
    final moved = Directory(p.join(temp.path, 'moved', 'Documents'));
    await Directory(
      p.dirname(copy.filePath.replaceFirst(documents.path, moved.path)),
    ).create(recursive: true);
    final movedPath = copy.filePath.replaceFirst(documents.path, moved.path);
    await File(copy.filePath).rename(movedPath);
    final reloaded = NetworkOfflineOrigins(
      file: () async => originsFile,
      documents: () async => moved,
    );

    expect((await reloaded.of(movedPath))?.source, _webdav);
    expect(await reloaded.hasCopyOf(_webdav), isTrue);
  });

  group('NetworkFileTransport', () {
    late HttpServer server;
    late List<int> body;
    late int? declared;

    setUp(() async {
      body = _bytes;
      declared = null;
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((request) async {
        request.response.contentLength = declared ?? body.length;
        request.response.add(body);
        await request.response.close().catchError((Object _) {});
      });
    });

    tearDown(() => server.close(force: true));

    NetworkFileTransport transportFor() => NetworkFileTransport(
      storage: _Storage('http://127.0.0.1:${server.port}/song'),
    );

    test('streams the original file', () async {
      final output = File(p.join(temp.path, 'out.flac'));
      final seen = <int>[];
      final transport = transportFor();
      await transport.download(
        _webdav,
        output,
        checkpoint: () {},
        progress: (received, _) => seen.add(received),
      );
      transport.close();

      expect(await output.readAsBytes(), _bytes);
      expect(seen.last, _bytes.length);
    });

    test('a cut-off response fails instead of saving half a song', () async {
      declared = _bytes.length * 2;
      final transport = transportFor();
      await expectLater(
        transport.download(
          _webdav,
          File(p.join(temp.path, 'out.flac')),
          checkpoint: () {},
          progress: (_, _) {},
        ),
        throwsA(anything),
      );
      transport.close();
    });

    test('a local file from a virtual source is copied', () async {
      final local = File(p.join(temp.path, 'local.flac'));
      await local.writeAsBytes(_bytes);
      final transport = NetworkFileTransport(storage: _Storage(local.path));
      final output = File(p.join(temp.path, 'out.flac'));
      await transport.download(
        _webdav,
        output,
        checkpoint: () {},
        progress: (_, _) {},
      );

      expect(await output.readAsBytes(), _bytes);
    });
  });
}
