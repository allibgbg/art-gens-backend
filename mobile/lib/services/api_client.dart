import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:http/http.dart' as http;
import '../providers/backend_status.dart';

typedef AuthErrorCallback = void Function();

class ApiClient {
  final String baseUrl;
  final http.Client _client = http.Client();
  String? _token;
  final BackendStatus? _backendStatus;
  AuthErrorCallback? onAuthError;

  ApiClient({required this.baseUrl, BackendStatus? backendStatus})
      : _backendStatus = backendStatus;

  void setToken(String? token) {
    _token = token;
  }

  Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        if (_token != null) 'Authorization': 'Bearer $_token',
      };

  Future<Map<String, dynamic>> get(String path,
      {Map<String, String>? queryParams}) async {
    final uri =
        Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
    return _retryOnSleep(() async {
      final response = await _client.get(uri, headers: _headers);
      return _handleResponse(response);
    });
  }

  Future<List<dynamic>> getList(String path,
      {Map<String, String>? queryParams}) async {
    final uri =
        Uri.parse('$baseUrl$path').replace(queryParameters: queryParams);
    return _retryOnSleep(() async {
      final response = await _client.get(uri, headers: _headers);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as List<dynamic>;
      }
      if (response.statusCode == 401 || (response.statusCode == 404 && response.body.contains('introuvable'))) {
        onAuthError?.call();
      }
      throw ApiException(response.statusCode, response.body);
    });
  }

  Future<Map<String, dynamic>> post(String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$baseUrl$path');
    return _retryOnSleep(() async {
      final response = await _client.post(
        uri,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      );
      return _handleResponse(response);
    });
  }

  Future<Map<String, dynamic>> patch(String path,
      {Map<String, dynamic>? body}) async {
    final uri = Uri.parse('$baseUrl$path');
    return _retryOnSleep(() async {
      final response = await _client.patch(
        uri,
        headers: _headers,
        body: body != null ? jsonEncode(body) : null,
      );
      return _handleResponse(response);
    });
  }

  Future<Map<String, dynamic>> reconstruct3D(List<String> imagePaths,
      {bool dense = true}) async {
    final uri = Uri.parse('$baseUrl/scan3d/reconstruct');
    final req = http.MultipartRequest('POST', uri);
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    for (final p in imagePaths) {
      req.files.add(await http.MultipartFile.fromPath('files', p));
    }
    req.fields['dense'] = dense.toString();
    final res = await _sendMultipart(req);
    Map<String, dynamic> info = {};
    final reconHeader = res['headers']['x-recon'];
    if (reconHeader != null) {
      try {
        info = jsonDecode(reconHeader) as Map<String, dynamic>;
      } catch (_) {}
    }
    return {'info': info, 'meshBytes': res['bytes'] as List<int>};
  }

  Future<Map<String, dynamic>> compare3D(String refPath, String candPath,
      {double threshold = 0.02}) async {
    final uri = Uri.parse('$baseUrl/scan3d/compare');
    final req = http.MultipartRequest('POST', uri);
    if (_token != null) req.headers['Authorization'] = 'Bearer $_token';
    req.files.add(await http.MultipartFile.fromPath('reference', refPath));
    req.files.add(await http.MultipartFile.fromPath('candidate', candPath));
    req.fields['threshold'] = threshold.toString();
    final res = await _sendMultipart(req);
    return jsonDecode(res['body'] as String) as Map<String, dynamic>;
  }

  Future<Map<String, dynamic>> _sendMultipart(http.MultipartRequest req) async {
    while (true) {
      try {
        final streamed = await req.send();
        final response = await http.Response.fromStream(streamed);
        if (response.statusCode == 501) {
          throw ApiException(501, response.body);
        }
        if (response.statusCode >= 200 && response.statusCode < 300) {
          return {
            'status': response.statusCode,
            'body': response.body,
            'bytes': response.bodyBytes,
            'headers': response.headers,
          };
        }
        throw ApiException(response.statusCode, response.body);
      } catch (e) {
        if (_isSleepError(e)) {
          _backendStatus?.markSleeping();
          await Future.delayed(const Duration(seconds: 3));
        } else {
          rethrow;
        }
      }
    }
  }

  Map<String, dynamic> _handleResponse(http.Response response) {
    if (response.statusCode >= 200 && response.statusCode < 300) {
      if (response.body.isEmpty) return {};
      return jsonDecode(response.body) as Map<String, dynamic>;
    }
    if (response.statusCode == 401 || (response.statusCode == 404 && response.body.contains('introuvable'))) {
      onAuthError?.call();
    }
    throw ApiException(response.statusCode, response.body);
  }

  bool _isSleepError(dynamic e) {
    if (e is ApiException) {
      return e.statusCode == 502 || e.statusCode == 503;
    }
    if (e is SocketException || e is TimeoutException) return true;
    if (e is HttpException) return true;
    return false;
  }

  Future<T> _retryOnSleep<T>(Future<T> Function() fn,
      {Duration delay = const Duration(seconds: 3)}) async {
    while (true) {
      try {
        final result = await fn();
        _backendStatus?.markAwake();
        return result;
      } catch (e) {
        if (_isSleepError(e)) {
          _backendStatus?.markSleeping();
          await Future.delayed(delay);
        } else {
          _backendStatus?.markAwake();
          rethrow;
        }
      }
    }
  }

  void dispose() {
    _client.close();
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String body;
  ApiException(this.statusCode, this.body);

  @override
  String toString() => 'ApiException($statusCode): $body';
}
