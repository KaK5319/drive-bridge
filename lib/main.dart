import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:google_sign_in/google_sign_in.dart';

/// ドライブ移行 - スマホのダウンロードフォルダに新しく来た rar / zip を、
/// 名前の文字化けを直しながら Google ドライブへ自動で送るアプリ。
/// 第1歩:Google ログインだけを実装。ログインできることが確認できたら、
/// 次にダウンロード監視とドライブ送信を作る。

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

class _HomePageState extends State<HomePage> {
  GoogleSignInAccount? _account;
  bool _busy = false;
  String? _errorText;

  @override
  void initState() {
    super.initState();
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

  Future<void> _signOut() async {
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
                  else if (account != null)
                    OutlinedButton(
                      onPressed: _signOut,
                      child: const Text('ログアウト'),
                    )
                  else
                    ElevatedButton(
                      onPressed: _signIn,
                      child: const Text('Googleにログイン'),
                    ),
                ],
              ),
            ),
          ),
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
