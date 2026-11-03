import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:mornye/utils/ios_container_paths.dart';

/// Network songs saved to this device: each `network://` song and its phone
/// copy. A saved song keeps its Library row and download record;
/// [NetworkStorageService] serves it from the copy, offline too. Kept in its
/// own file, so an official build simply ignores it.
class NetworkOfflineOrigins {
  NetworkOfflineOrigins({
    Future<File> Function()? file,
    Future<Directory> Function()? documents,
  }) : _file = file ?? _defaultFile,
       _documents = documents ?? getApplicationDocumentsDirectory;

  static final instance = NetworkOfflineOrigins();

  final Future<File> Function() _file;
  final Future<Directory> Function() _documents;

  /// Copy path by song.
  final _copies = <String, String>{};
  final _legacyDownloads = <String, String>{};
  Future<void>? _loading;
  Future<void> _mutation = Future.value();

  /// Moves on whenever copies load, or one is saved or removed.
  final revision = ValueNotifier<int>(0);

  static Future<File> _defaultFile() async => File(
    p.join(
      (await getApplicationSupportDirectory()).path,
      'network_offline_origins.json',
    ),
  );

  Future<void> load() => _loading ??= _read();

  /// Waits for a load already started (at app start), without starting one.
  Future<void> get ready => _loading ?? Future<void>.value();

  /// Whether the last load could not read the file. Writing then would erase
  /// every copy it lists, so writes wait for a read that works.
  bool _unreadable = false;

  Future<void> _read() async {
    try {
      final documents = (await _documents()).path;
      final file = await _file();
      _unreadable = false;
      if (!await file.exists()) return;
      final json = jsonDecode(await file.readAsString());
      if (json is! Map) return;
      json.forEach((key, value) {
        if (key is! String) return;
        if (value is String) {
          // iOS moves the app's container on updates.
          _copies[key] = rebaseIosSandboxPath(value, documents);
        } else if (value is Map && value['source'] is String) {
          // The first builds keyed copies by a Documents-relative path, and
          // pointed a saved download's record at its copy ("restore").
          final copy = key.startsWith('Documents/')
              ? p.join(p.dirname(documents), key)
              : rebaseIosSandboxPath(key, documents);
          _copies[value['source'] as String] = copy;
          if (value['restore'] == true) {
            _legacyDownloads[copy] = value['source'] as String;
          }
        }
      });
    } on Object {
      // Locked before the first unlock, damaged, or no app folders (tests).
      _unreadable = true;
      _loading = null;
    } finally {
      revision.value++;
    }
  }

  /// The phone copy of the network song [source], once [load] has run.
  String? copyOf(String source) => _copies[source];

  /// Whether the song at [path] is a network song saved to this device.
  bool isSaved(String path) => _copies.containsKey(path);

  /// [copyOf] while that file is still there. A copy deleted outside the app
  /// is forgotten, so the song streams and shows as on the server again.
  Future<String?> existingCopyOf(String source) async {
    await load();
    final copy = _copies[source];
    if (copy == null) return null;
    if (await File(copy).exists()) return copy;
    await remove(source);
    return null;
  }

  /// Every saved song and its copy.
  Map<String, String> get copies => Map.unmodifiable(_copies);

  /// Download records the first builds pointed at a copy, by that copy, with
  /// the song to point them back at. Empty once [put] or [remove] runs.
  Map<String, String> get legacyDownloads => Map.unmodifiable(_legacyDownloads);

  Future<void> put(String source, String copy) =>
      _write(() => _copies[source] = copy);

  Future<void> remove(String source) => _write(() => _copies.remove(source));

  Future<void> _write(void Function() change) {
    final next = _mutation.then((_) async {
      await load();
      if (_unreadable) {
        throw const FileSystemException('Saved songs could not be read');
      }
      change();
      _legacyDownloads.clear();
      final file = await _file();
      await file.parent.create(recursive: true);
      final temp = File('${file.path}.tmp');
      await temp.writeAsString(jsonEncode(_copies));
      // Atomic: a crash never leaves half a file.
      await temp.rename(file.path);
      revision.value++;
    });
    _mutation = next.catchError((Object _) {});
    return next;
  }
}
