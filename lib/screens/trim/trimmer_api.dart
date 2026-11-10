import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:fladder/providers/api_provider.dart';
import 'package:fladder/providers/user_provider.dart';

/// Client for the clip trimmer that runs next to Jellyfin (same host, port 8199 unless changed).
/// It signs in with the Jellyfin token this app already has.
class TrimmerApi {
  static const urlKey = 'trimmer_url';
  static const dataSaverKey = 'clip_data_saver';

  final String base;
  final String token;
  const TrimmerApi(this.base, this.token);

  Map<String, String> get headers => {'Authorization': 'MediaBrowser Token="$token"'};

  static Future<TrimmerApi?> of(WidgetRef ref) async {
    final cred = ref.read(userProvider)?.credentials;
    if (cred == null || cred.token.isEmpty) return null;
    final prefs = await SharedPreferences.getInstance();
    var base = prefs.getString(urlKey) ?? '';
    if (base.isEmpty) {
      final server = ref.read(serverUrlProvider) ?? cred.url;
      final host = Uri.tryParse(server)?.host ?? '';
      if (host.isEmpty) return null;
      base = 'http://$host:8199';
    }
    return TrimmerApi(base.replaceAll(RegExp(r'/+$'), ''), cred.token);
  }

  static Future<void> setBase(String value) async {
    final prefs = await SharedPreferences.getInstance();
    if (value.trim().isEmpty) {
      await prefs.remove(urlKey);
    } else {
      await prefs.setString(urlKey, value.trim());
    }
  }

  static Future<bool> dataSaver() async => (await SharedPreferences.getInstance()).getBool(dataSaverKey) ?? false;

  static Future<void> setDataSaver(bool value) async =>
      (await SharedPreferences.getInstance()).setBool(dataSaverKey, value);

  Uri _uri(String path, [Map<String, String>? query]) =>
      Uri.parse(base + path).replace(queryParameters: (query == null || query.isEmpty) ? null : query);

  Future<Map<String, dynamic>> get(String path, {Map<String, String>? query, int seconds = 15}) async {
    final res = await http.get(_uri(path, query), headers: headers).timeout(Duration(seconds: seconds));
    return _decode(res);
  }

  Future<Map<String, dynamic>> post(String path, Map<String, dynamic> body, {int seconds = 20}) async {
    final res = await http
        .post(_uri(path), headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body))
        .timeout(Duration(seconds: seconds));
    return _decode(res);
  }

  Map<String, dynamic> _decode(http.Response res) {
    if (res.statusCode == 401) throw 'The trimmer refused the login (an admin account is needed)';
    try {
      final data = jsonDecode(res.body);
      if (data is Map<String, dynamic>) return data;
    } catch (_) {}
    throw 'Unexpected answer from the trimmer (HTTP ${res.statusCode})';
  }

  /// Address of a clip for the editor. [lite] asks for the small data-saver copy when there is one.
  String videoUrl(String path, {bool lite = false, int? stamp}) => _uri('/api/video', {
        'p': path,
        if (lite) 'q': 'lite',
        'token': token,
        if (stamp != null) 't': '$stamp',
      }).toString();

  /// Address of the data-saver copy of a Jellyfin item (any signed-in user), or null when it isn't ready yet.
  /// Asking also tells the server to make the copy next.
  Future<String?> liteUrlFor(String itemId) async {
    try {
      final res = await http
          .get(_uri('/api/lite', {'id': itemId, 'probe': '1'}), headers: headers)
          .timeout(const Duration(seconds: 4));
      if (res.statusCode != 200) return null;
      final data = jsonDecode(res.body);
      if (data is Map && data['ready'] == true) {
        return _uri('/api/lite', {'id': itemId, 'token': token}).toString();
      }
    } catch (_) {}
    return null;
  }
}
