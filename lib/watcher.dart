import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'uploader.dart';

/// 端末側(ネイティブ)との橋渡し。「すべてのファイルへのアクセス」許可の
/// 確認と、その設定画面を開く操作だけを担当する。
class StorageBridge {
  static const MethodChannel _channel = MethodChannel('drive_bridge/storage');

  static Future<bool> isAllFilesAccessGranted() async {
    try {
      final v = await _channel.invokeMethod<bool>('isAllFilesAccessGranted');
      return v ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openAllFilesAccessSettings() async {
    try {
      await _channel.invokeMethod<void>('openAllFilesAccessSettings');
    } catch (_) {
      // 設定画面が開けない環境では何もしない(画面側で再確認する)。
    }
  }
}

/// 送信ずみファイルの記録。
class SentRecord {
  SentRecord({
    required this.name,
    required this.driveName,
    required this.size,
    required this.sentAtMillis,
  });

  /// 端末側の元の名前。
  final String name;

  /// ドライブへ入れた名前(文字化けを直した後)。
  final String driveName;
  final int size;
  final int sentAtMillis;

  Map<String, dynamic> toJson() => <String, dynamic>{
        'name': name,
        'driveName': driveName,
        'size': size,
        'sentAtMillis': sentAtMillis,
      };

  factory SentRecord.fromJson(Map<String, dynamic> j) => SentRecord(
        name: j['name'] as String? ?? '',
        driveName: j['driveName'] as String? ?? '',
        size: (j['size'] as num?)?.toInt() ?? 0,
        sentAtMillis: (j['sentAtMillis'] as num?)?.toInt() ?? 0,
      );
}

/// 監視の土台データ(監視開始時点で既にあったファイル)と送信ずみ記録を、
/// アプリ内のファイルに保存する。
class WatchStore {
  bool baselineDone = false;

  /// 監視を始めた時点で既にダウンロードフォルダにあったファイル。
  /// 名前 -> "サイズ:更新時刻"。これらは「新しく来たもの」ではないので送らない。
  final Map<String, String> baseline = <String, String>{};
  final List<SentRecord> sent = <SentRecord>[];

  bool alreadySent(String name, int size) =>
      sent.any((r) => r.name == name && r.size == size);

  Future<File> _file() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/watch_state.json');
  }

  Future<void> load() async {
    try {
      final f = await _file();
      if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      baselineDone = j['baselineDone'] == true;
      final b = j['baseline'];
      if (b is Map) {
        b.forEach((k, v) => baseline['$k'] = '$v');
      }
      final s = j['sent'];
      if (s is List) {
        sent
          ..clear()
          ..addAll(s
              .whereType<Map>()
              .map((m) => SentRecord.fromJson(m.cast<String, dynamic>())));
      }
    } catch (_) {
      // 壊れていたら最初からやり直す(土台が無い=次回が初回扱い)。
    }
  }

  Future<void> save() async {
    try {
      final f = await _file();
      await f.writeAsString(jsonEncode(<String, dynamic>{
        'baselineDone': baselineDone,
        'baseline': baseline,
        'sent': sent.map((r) => r.toJson()).toList(),
      }));
    } catch (_) {
      // 保存できなくても監視自体は続ける。
    }
  }
}

/// ダウンロードフォルダを見張り、新しく来た rar / zip を自動でドライブへ送る。
/// アプリを開いている間だけ、10秒ごとに確認する。
class DownloadWatcher {
  DownloadWatcher({
    required this.store,
    required this.authHeaders,
    required this.onChanged,
  });

  final WatchStore store;

  /// 送信のたびに最新の認証ヘッダーをもらう(未ログインなら null)。
  final Future<Map<String, String>?> Function() authHeaders;

  /// 画面の再描画用コールバック。
  final void Function() onChanged;

  static const String downloadPath = '/storage/emulated/0/Download';
  static const Duration interval = Duration(seconds: 10);

  bool permissionGranted = false;
  bool watching = false;
  bool uploading = false;
  String? statusText;
  String? currentName;
  int currentSent = 0;
  int currentTotal = 0;

  Timer? _timer;
  bool _scanning = false;

  /// 落ち着き待ちのファイル(名前 -> 前回見たサイズ)。
  /// サイズが2回続けて同じだったら「ダウンロード完了」とみなす。
  final Map<String, int> _seenSizes = <String, int>{};

  /// 送信に失敗したファイルの再試行をしばらく抑える(名前 -> 再試行可能時刻)。
  final Map<String, int> _retryAfter = <String, int>{};

  Future<void> init() async {
    await store.load();
    permissionGranted = await StorageBridge.isAllFilesAccessGranted();
    onChanged();
  }

  Future<void> refreshPermission() async {
    permissionGranted = await StorageBridge.isAllFilesAccessGranted();
    onChanged();
  }

  void setWatching(bool on) {
    watching = on;
    _timer?.cancel();
    if (on) {
      statusText = '監視を開始します…';
      _timer = Timer.periodic(interval, (_) => scan());
      scan();
    } else {
      statusText = '停止中';
    }
    onChanged();
  }

  void dispose() => _timer?.cancel();

  static String _sig(FileStat st) =>
      '${st.size}:${st.modified.millisecondsSinceEpoch}';

  static String _nowText() {
    final n = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(n.hour)}:${two(n.minute)}:${two(n.second)}';
  }

  Future<void> scan() async {
    if (_scanning || !watching) return;
    _scanning = true;
    try {
      final dir = Directory(downloadPath);
      if (!await dir.exists()) {
        statusText = 'ダウンロードフォルダが見つかりません';
        onChanged();
        return;
      }
      final now = DateTime.now().millisecondsSinceEpoch;
      final queue = <File>[];
      await for (final e in dir.list(followLinks: false)) {
        if (e is! File) continue;
        final name = e.uri.pathSegments.last;
        final lower = name.toLowerCase();
        if (!(lower.endsWith('.rar') || lower.endsWith('.zip'))) continue;
        FileStat st;
        try {
          st = await e.stat();
        } catch (_) {
          continue;
        }
        if (st.size <= 0) continue;
        final s = _sig(st);
        if (store.alreadySent(name, st.size)) {
          _seenSizes.remove(name);
          continue;
        }
        if (!store.baselineDone) {
          // 初回は今あるものを土台として記録するだけ(送らない)。
          store.baseline[name] = s;
          continue;
        }
        if (store.baseline[name] == s) continue; // 監視開始前からあったもの
        if (now < (_retryAfter[name] ?? 0)) continue; // 失敗直後は少し待つ
        if (_seenSizes[name] != st.size) {
          _seenSizes[name] = st.size; // 初めて見た。落ち着くまで待つ
          continue;
        }
        queue.add(e); // サイズが前回と同じ=ダウンロード完了とみなす
      }
      if (!store.baselineDone) {
        store.baselineDone = true;
        await store.save();
        statusText = '監視を開始しました(既にあったファイルは送りません)';
        onChanged();
        return;
      }
      statusText = '監視中(最終確認 ${_nowText()})';
      onChanged();
      for (final f in queue) {
        if (!watching) break;
        await _uploadOne(f);
      }
    } catch (e) {
      statusText = '確認でエラー：$e';
      onChanged();
    } finally {
      _scanning = false;
    }
  }

  Future<void> _uploadOne(File f) async {
    final name = f.uri.pathSegments.last;
    final headers = await authHeaders();
    if (headers == null) {
      statusText = 'ログインが必要です';
      onChanged();
      return;
    }
    uploading = true;
    currentName = name;
    currentSent = 0;
    currentTotal = 0;
    onChanged();
    final uploader = ResumableUploader(headers);
    try {
      final size = await f.length();
      final driveName = fixMojibakeName(name);
      await uploader.upload(f, driveName, onProgress: (sent, total) {
        currentSent = sent;
        currentTotal = total;
        onChanged();
      });
      store.sent.add(SentRecord(
        name: name,
        driveName: driveName,
        size: size,
        sentAtMillis: DateTime.now().millisecondsSinceEpoch,
      ));
      await store.save();
      _seenSizes.remove(name);
      statusText = '「$driveName」をドライブへ送りました';
    } catch (e) {
      _retryAfter[name] =
          DateTime.now().millisecondsSinceEpoch + 2 * 60 * 1000;
      statusText = '「$name」の送信に失敗しました：$e';
    } finally {
      uploader.close();
      uploading = false;
      currentName = null;
      onChanged();
    }
  }
}
