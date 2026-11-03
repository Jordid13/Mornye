import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

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
  String? _container;

  /// Moves on whenever a copy is saved or removed, for views that show it.
  final revision = ValueNotifier<int>(0);
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

  String _path(String key) => key.startsWith('Documents/') && _container != null
      ? p.join(_container!, key)
      : key;

  Future<Map<String, NetworkOrigin>> load() async {
    final loaded = _entries;
    if (loaded != null) return loaded;
    final entries = <String, NetworkOrigin>{};
    try {
      _container ??= (await _documents()).parent.path;
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
      // No file yet, unreadable, or no app folders (tests): no copies.
    }
    return _entries ??= entries;
  }

  /// The origin of the phone copy at [path], once [load] has run.
  NetworkOrigin? cached(String path) => _entries?[_key(path)];

  Future<NetworkOrigin?> of(String path) async => (await load())[_key(path)];

  /// Where the phone copy of [source] is, once [load] has run.
  String? cachedCopyOf(String source) {
    for (final entry in (_entries ?? const <String, NetworkOrigin>{}).entries) {
      if (entry.value.source == source) return _path(entry.key);
    }
    return null;
  }

  /// The phone copy of [source] while it is still there.
  Future<String?> copyOf(String source) async {
    await load();
    final path = cachedCopyOf(source);
    return path != null && await File(path).exists() ? path : null;
  }

  /// Whether a phone copy of [source] is still there.
  Future<bool> hasCopyOf(String source) async => await copyOf(source) != null;

  /// Every phone copy, by its current path.
  Future<Map<String, NetworkOrigin>> copies() async => {
    for (final entry in (await load()).entries) _path(entry.key): entry.value,
  };

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
      revision.value++;
    });
    _mutation = next.catchError((Object _) {});
    return next;
  }
}
