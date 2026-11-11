import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:http/http.dart' as http;

/// Google ドライブへの「塊に分けて送る」アップロード(レジューマブル方式)。
/// 大きいファイルを 8MB ずつ送り、通信が切れてもサーバー側の受信済み位置を
/// 聞き直して続きから送る。セッションが切れていたら最初からやり直す。

const int kChunkBytes = 8 * 1024 * 1024;

/// UTF-8 のバイト列が Latin-1 として誤って読まれたファイル名
/// (例: ã_¤ã_³... のような文字化け)を元の日本語名に戻す。
/// 直せない・対象でない名前はそのまま返す。
String fixMojibakeName(String name) {
  if (!name.contains('ã') && !name.contains('Ã')) return name;
  try {
    final bytes = latin1.encode(name);
    final decoded = utf8.decode(bytes);
    if (decoded != name && !decoded.contains('\uFFFD')) return decoded;
  } catch (_) {
    // Latin-1 で表せない文字が混ざっている等。そのまま返す。
  }
  return name;
}

class ResumableUploader {
  ResumableUploader(this._authHeaders);

  /// GoogleSignInAccount.authHeaders の中身(Authorization を含む)。
  final Map<String, String> _authHeaders;

  final http.Client _client = http.Client();

  void close() => _client.close();

  /// [file] をドライブのルートへ [name] という名前で送る。
  /// [onProgress] には (送信済みバイト数, 全体バイト数) が渡る。
  /// 成功したらドライブ側のファイルIDを返す。
  Future<String> upload(
    File file,
    String name, {
    required void Function(int sent, int total) onProgress,
  }) async {
    final total = await file.length();
    var sessionUri = await _startSession(name, total);
    var offset = 0;
    var retries = 0;
    onProgress(0, total);

    final raf = await file.open();
    try {
      while (offset < total) {
        final endExclusive = (offset + kChunkBytes < total) ? offset + kChunkBytes : total;
        final len = endExclusive - offset;
        final buf = Uint8List(len);
        await raf.setPosition(offset);
        var filled = 0;
        while (filled < len) {
          final n = await raf.readInto(buf, filled, len - filled);
          if (n <= 0) break;
          filled += n;
        }
        try {
          final resp = await _client.put(
            Uri.parse(sessionUri),
            headers: <String, String>{
              'Content-Length': '$len',
              'Content-Range': 'bytes $offset-${endExclusive - 1}/$total',
            },
            body: buf,
          );
          if (resp.statusCode == 200 || resp.statusCode == 201) {
            onProgress(total, total);
            final body = jsonDecode(resp.body) as Map<String, dynamic>;
            return body['id'] as String? ?? '';
          }
          if (resp.statusCode == 308) {
            offset = _rangeEnd(resp.headers['range']) ?? endExclusive;
            retries = 0;
            onProgress(offset, total);
            continue;
          }
          if (resp.statusCode == 404) {
            // セッション失効。最初から作り直す。
            sessionUri = await _startSession(name, total);
            offset = 0;
            retries = 0;
            onProgress(0, total);
            continue;
          }
          throw HttpException('送信エラー (HTTP ${resp.statusCode})');
        } catch (e) {
          // 通信断など。受信済みの位置を聞き直して続きから送る。
          retries++;
          if (retries > 8) rethrow;
          await Future<void>.delayed(Duration(seconds: retries));
          int? resumeAt;
          var sessionDead = false;
          try {
            resumeAt = await _queryOffset(sessionUri, total);
          } catch (_) {
            sessionDead = true;
          }
          if (!sessionDead && resumeAt == null) {
            // すでに完了していた。
            onProgress(total, total);
            return '';
          }
          if (sessionDead) {
            // セッションが切れているので作り直して最初から。
            sessionUri = await _startSession(name, total);
            offset = 0;
          } else {
            offset = resumeAt!;
          }
          onProgress(offset, total);
        }
      }
      return '';
    } finally {
      await raf.close();
    }
  }

  Future<String> _startSession(String name, int total) async {
    final resp = await _client.post(
      Uri.parse('https://www.googleapis.com/upload/drive/v3/files?uploadType=resumable'),
      headers: <String, String>{
        ..._authHeaders,
        'Content-Type': 'application/json; charset=UTF-8',
        'X-Upload-Content-Length': '$total',
        'X-Upload-Content-Type': 'application/octet-stream',
      },
      body: jsonEncode(<String, String>{'name': name}),
    );
    if (resp.statusCode != 200 && resp.statusCode != 201) {
      throw HttpException('送信を開始できませんでした (HTTP ${resp.statusCode})');
    }
    final location = resp.headers['location'];
    if (location == null || location.isEmpty) {
      throw const HttpException('送信先のアドレスが返りませんでした');
    }
    return location;
  }

  /// サーバーが受け取り済みのバイト数を返す。完了済みなら null。
  Future<int?> _queryOffset(String sessionUri, int total) async {
    final resp = await _client.put(
      Uri.parse(sessionUri),
      headers: <String, String>{
        'Content-Length': '0',
        'Content-Range': 'bytes */$total',
      },
    );
    if (resp.statusCode == 200 || resp.statusCode == 201) return null;
    if (resp.statusCode == 308) {
      return _rangeEnd(resp.headers['range']) ?? 0;
    }
    throw HttpException('状態確認エラー (HTTP ${resp.statusCode})');
  }

  /// "bytes=0-12345" の末尾+1(=受信済みバイト数)を返す。
  int? _rangeEnd(String? range) {
    if (range == null) return null;
    final m = RegExp(r'bytes=0-(\d+)').firstMatch(range);
    if (m == null) return null;
    return (int.tryParse(m.group(1)!) ?? -1) + 1;
  }
}
