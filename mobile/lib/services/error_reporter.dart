import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;

/// Signale une erreur rencontrée côté app au backend (endpoint /logs).
/// Best-effort : ne bloque jamais l'UI et ignore les échecs réseau.
String? _baseUrl;

void initErrorReporter(String baseUrl) {
  _baseUrl = baseUrl.endsWith('/') ? baseUrl.substring(0, baseUrl.length - 1) : baseUrl;
}

String? _lastKey;
int _lastTs = 0;

Future<void> reportError({
  required String message,
  String? source,
  String? stack,
  String level = 'error',
  Map<String, dynamic>? extra,
}) async {
  if (_baseUrl == null) return;
  // Anti-spam : ne renvoie pas la même erreur à < 5 s d'intervalle.
  final key = '$source|$message';
  final now = DateTime.now().millisecondsSinceEpoch;
  if (key == _lastKey && now - _lastTs < 5000) return;
  _lastKey = key;
  _lastTs = now;

  final payload = <String, dynamic>{
    'level': level,
    'source': source ?? 'app',
    'message': message,
    'stack': stack,
    'ts': DateTime.now().toUtc().toIso8601String(),
    'device': {
      'os': Platform.operatingSystem,
      'osVersion': Platform.operatingSystemVersion,
      'dart': Platform.version,
    },
    if (extra != null) ...extra,
  };

  try {
    await http
        .post(
          Uri.parse('$_baseUrl/logs'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode(payload),
        )
        .timeout(const Duration(seconds: 10));
  } catch (_) {
    // Volontairement ignoré : le reporting d'erreur ne doit jamais planter l'app.
  }
}
