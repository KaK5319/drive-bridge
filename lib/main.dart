import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'uploader.dart';
import 'watcher.dart';

/// ドライブ移行 - スマホのダウンロードフォルダに新しく来た rar / zip を、
/// 名前の文字化けを直しながら Google ドライブへ自動で送るアプリ。
/// 第3歩:ダウンロード監視。アプリを開いている間、10秒ごとにダウンロード
/// フォルダを確認し、新しく来て落ち着いた rar / zip を自動で送る。
/// 監視を始めた時点で既にあったファイルは送らない。送ったものは記録して
/// 二度送らない。

// ---------- 見た目の色(映画棚・漫画棚と同系列の明るい木の色) ----------
const Color kCream = Color(0xFFF7EFE3); // 背景の温かいクリーム色
const Color kCard = Color(0xFFFFFDF8); // カードの温かい白
const Color kWood = Color(0xFF7A4A21); // アクセントの木の茶色
const Color kWoodBar = Color(0xFF8D5A33); // AppBarの木の茶色
const Color kInk = Color(0xFF2B211B); // 本文の濃い茶色
const Color kSub = Color(0xFF7A6A5F); // 補足テキストの茶灰色

/// アプリが Google ドライブで使う許可範囲。
/// drive.file は「このアプリが作ったファイルだけ」に触れる狭い許可。
const String kDriveFileScope = 'https://www.googleapis.com/auth/drive.file';

final GoogleSignIn _googleSignIn = GoogleSignIn(
  scopes: const <String>['email', kDriveFileScope],
);

void main() {
  runApp(const DriveBridgeApp());
}

class DriveBridgeApp extends StatelessWidget {
  const DriveBridgeApp({super.key});
  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'ドライブ移行',
        debugShowCheckedModeBanner: false,
        // フレームワーク標準の文言(コピー/貼り付け等のテキスト選択メニュー、
        // ツールチップ等)を最初から日本語にするためのロケール設定。
        locale: const Locale('ja'),
        supportedLocales: const [Locale('ja'), Locale('en')],
        localizationsDelegates: const [
          GlobalMaterialLocalizations.delegate,
          GlobalWidgetsLocalizations.delegate,
          GlobalCupertinoLocalizations.delegate,
        ],
        theme: ThemeData(
          useMaterial3: true,
          brightness: Brightness.light,
          scaffoldBackgroundColor: kCream,
          colorScheme: ColorScheme.fromSeed(seedColor: kWood, brightness: Brightness.light).copyWith(
            primary: kWood,
            onPrimary: Colors.white,
            secondary: kWoodBar,
            surface: kCream,
            onSurface: kInk,
          ),
          appBarTheme: const AppBarTheme(backgroundColor: kWoodBar, foregroundColor: Colors.white),
          snackBarTheme: const SnackBarThemeData(
            backgroundColor: kInk,
            contentTextStyle: TextStyle(color: Colors.white),
          ),
        ),
        home: const HomePage(),
      );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> with WidgetsBindingObserver {
  GoogleSignInAccount? _account;
  bool _busy = false;
  String? _errorText;

  // テスト送信の状態。
  bool _uploading = false;
  int _sentBytes = 0;
  int _totalBytes = 0;
  String? _uploadText;
  bool _uploadError = false;

  // ダウンロード監視。
  late final WatchStore _watchStore;
  late final DownloadWatcher _watcher;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _watchStore = WatchStore();
    _watcher = DownloadWatcher(
      store: _watchStore,
      authHeaders: () async {
        final a = _googleSignIn.currentUser ?? _account;
        if (a == null) return null;
        return a.authHeaders;
      },
      onChanged: () {
        if (mounted) setState(() {});
      },
    );
    _watcher.init();
    _googleSignIn.onCurrentUserChanged.listen((GoogleSignInAccount? account) {
      if (!mounted) return;
      setState(() {
        _account = account;
      });
    });
    // 前回のログインが残っていれば黙って復元する。
    _googleSignIn.signInSilently().catchError((Object _) {
      // 復元できないのは異常ではない(初回など)。エラー表示はしない。
      return null;
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _watcher.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // 許可の設定画面から戻ってきたら、許可の状態を確認し直す。
    if (state == AppLifecycleState.resumed) {
      _watcher.refreshPermission();
    }
  }

  Future<void> _signIn() async {
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      final account = await _googleSignIn.signIn();
      if (!mounted) return;
      setState(() {
        _account = account;
        _busy = false;
        if (account == null) {
          // アカウント選択の途中で戻ると null が返る。無言にせず理由を示す。
          _errorText =
              'ログインが完了しませんでした。アカウントを選んだ後の画面で「続行」と「許可」まで進んでください。';
        }
      });
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorText = 'ログインできませんでした（${e.code}）${e.message ?? ''}';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _errorText = 'ログインできませんでした：$e';
      });
    }
  }

  static String _mb(int bytes) => (bytes / (1024 * 1024)).toStringAsFixed(1);

  Future<void> _pickAndUpload() async {
    final account = _account;
    if (account == null) return;
    final picked = await FilePicker.platform.pickFiles();
    final path = picked?.files.single.path;
    if (path == null) return; // 選ばずに戻った
    final file = File(path);
    final originalName = path.split('/').last;
    final fixedName = fixMojibakeName(originalName);
    setState(() {
      _uploading = true;
      _uploadText = null;
      _sentBytes = 0;
      _totalBytes = 0;
    });
    final uploader = ResumableUploader(await account.authHeaders);
    try {
      await uploader.upload(file, fixedName, onProgress: (sent, total) {
        if (!mounted) return;
        setState(() {
          _sentBytes = sent;
          _totalBytes = total;
        });
      });
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadText = 'ドライブに「$fixedName」を入れました';
        _uploadError = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _uploading = false;
        _uploadText = '送信できませんでした：$e';
        _uploadError = true;
      });
    } finally {
      uploader.close();
    }
  }

  Future<void> _signOut() async {
    _watcher.setWatching(false);
    setState(() {
      _busy = true;
      _errorText = null;
    });
    try {
      await _googleSignIn.signOut();
    } catch (_) {
      // ログアウト失敗でも画面側は未ログイン扱いに戻す。
    }
    if (!mounted) return;
    setState(() {
      _account = null;
      _busy = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final account = _account;
    return Scaffold(
      appBar: AppBar(title: const Text('ドライブ移行')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            color: kCard,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('状態', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kInk)),
                  const SizedBox(height: 8),
                  if (account != null) ...[
                    const Text('ログインできています。', style: TextStyle(color: kInk)),
                    const SizedBox(height: 4),
                    Text('アカウント：${account.email}', style: const TextStyle(color: kInk)),
                    if (account.displayName != null)
                      Text('名前：${account.displayName}', style: const TextStyle(color: kSub)),
                  ] else
                    const Text('まだログインしていません。', style: TextStyle(color: kInk)),
                  if (_errorText != null) ...[
                    const SizedBox(height: 8),
                    Text(_errorText!, style: const TextStyle(color: Color(0xFFC62828))),
                  ],
                  const SizedBox(height: 12),
                  if (_busy)
                    const Row(
                      children: [
                        SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
                        SizedBox(width: 10),
                        Text('処理中…', style: TextStyle(color: kSub)),
                      ],
                    )
                  else if (account != null) ...[
                    if (_uploading) ...[
                      LinearProgressIndicator(
                        value: _totalBytes > 0 ? _sentBytes / _totalBytes : null,
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '送信中… ${_mb(_sentBytes)} / ${_mb(_totalBytes)} MB',
                        style: const TextStyle(color: kInk),
                      ),
                    ] else
                      ElevatedButton(
                        onPressed: _pickAndUpload,
                        child: const Text('テスト送信（ファイルを選ぶ）'),
                      ),
                    if (_uploadText != null) ...[
                      const SizedBox(height: 8),
                      Text(
                        _uploadText!,
                        style: TextStyle(color: _uploadError ? const Color(0xFFC62828) : kInk),
                      ),
                    ],
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => StorageBridge.openGoogleDrive(),
                      child: const Text('Googleドライブを開く'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => StorageBridge.openChrome(),
                      child: const Text('Google Chromeを開く'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: () => StorageBridge.openMuse(),
                      child: const Text('ミューズを開く'),
                    ),
                    const SizedBox(height: 8),
                    OutlinedButton(
                      onPressed: _signOut,
                      child: const Text('ログアウト'),
                    ),
                  ] else
                    ElevatedButton(
                      onPressed: _signIn,
                      child: const Text('Googleにログイン'),
                    ),
                ],
              ),
            ),
          ),
          if (account != null) ...[
            const SizedBox(height: 16),
            Card(
              color: kCard,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('ダウンロード監視', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kInk)),
                    const SizedBox(height: 8),
                    if (!_watcher.permissionGranted) ...[
                      const Text('監視には「すべてのファイルへのアクセス」の許可が必要です。', style: TextStyle(color: kInk)),
                      const SizedBox(height: 8),
                      ElevatedButton(
                        onPressed: () => StorageBridge.openAllFilesAccessSettings(),
                        child: const Text('許可を設定する'),
                      ),
                    ] else ...[
                      Row(
                        children: [
                          const Text('監視する', style: TextStyle(color: kInk)),
                          const Spacer(),
                          Switch(value: _watcher.watching, onChanged: _watcher.setWatching),
                        ],
                      ),
                      if (_watcher.statusText != null)
                        Text(_watcher.statusText!, style: const TextStyle(color: kSub)),
                      if (_watcher.uploading) ...[
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value: _watcher.currentTotal > 0 ? _watcher.currentSent / _watcher.currentTotal : null,
                        ),
                        const SizedBox(height: 4),
                        Text(
                          '送信中：${_watcher.currentName ?? ''}（${_mb(_watcher.currentSent)} / ${_mb(_watcher.currentTotal)} MB）',
                          style: const TextStyle(color: kInk),
                        ),
                      ],
                      if (_watchStore.sent.isNotEmpty) ...[
                        const SizedBox(height: 12),
                        const Text('送信ずみ', style: TextStyle(fontWeight: FontWeight.bold, color: kInk)),
                        const SizedBox(height: 4),
                        for (final r in _watchStore.sent.reversed.take(5))
                          Text('・${r.driveName}', style: const TextStyle(color: kInk)),
                      ],
                    ],
                  ],
                ),
              ),
            ),
          ],
          const SizedBox(height: 16),
          const Card(
            color: kCard,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('このアプリの仕様', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kInk)),
                  SizedBox(height: 8),
                  Text('・ダウンロードフォルダを見張る', style: TextStyle(color: kInk)),
                  Text('・新しく来た rar・zip だけを自動でドライブへ送る', style: TextStyle(color: kInk)),
                  Text('・ファイル名は文字化けを直して入れる', style: TextStyle(color: kInk)),
                  Text('・大きいファイルは小さい塊に分けて送る（途中で止まっても再開できる）', style: TextStyle(color: kInk)),
                  SizedBox(height: 8),
                  Text('機能はこれだけです。', style: TextStyle(color: kSub)),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
