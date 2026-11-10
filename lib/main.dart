import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

/// ドライブ移行 - スマホのダウンロードフォルダに新しく来た rar / zip を、
/// 名前の文字化けを直しながら Google ドライブへ自動で送るアプリ。
/// これは土台だけの版:画面の骨組みと見た目だけで、機能はまだ無い。

// ---------- 見た目の色(映画棚・漫画棚と同系列の明るい木の色) ----------
const Color kCream = Color(0xFFF7EFE3); // 背景の温かいクリーム色
const Color kCard = Color(0xFFFFFDF8); // カードの温かい白
const Color kWood = Color(0xFF7A4A21); // アクセントの木の茶色
const Color kWoodBar = Color(0xFF8D5A33); // AppBarの木の茶色
const Color kInk = Color(0xFF2B211B); // 本文の濃い茶色
const Color kSub = Color(0xFF7A6A5F); // 補足テキストの茶灰色

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

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ドライブ移行')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: const [
          Card(
            color: kCard,
            child: Padding(
              padding: EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('状態', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: kInk)),
                  SizedBox(height: 8),
                  Text('準備中：土台が入りました。これから機能を作ります。', style: TextStyle(color: kInk)),
                ],
              ),
            ),
          ),
          SizedBox(height: 16),
          Card(
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
