import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api_client.dart';

class AuthService {
  final ApiClient _api;
  final FlutterSecureStorage _storage = const FlutterSecureStorage();
  static const _tokenKey = 'auth_token';
  static const _userIdKey = 'user_id';

  AuthService(this._api);

  Future<String?> getSavedToken() => _storage.read(key: _tokenKey);
  Future<String?> getSavedUserId() => _storage.read(key: _userIdKey);

  Future<void> _saveToken(String token, String userId) async {
    await _storage.write(key: _tokenKey, value: token);
    await _storage.write(key: _userIdKey, value: userId);
    _api.setToken(token);
  }

  Future<void> logout() async {
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _userIdKey);
    _api.setToken(null);
  }

  Future<Map<String, dynamic>> loginWithGoogle(String idToken) async {
    final result = await _api.post('/auth/google', body: {
      'id_token': idToken,
    });
    await _saveToken(result['access_token'], result['user_id']);
    return result;
  }

  Future<Map<String, dynamic>> loginWithFacebook(
      String accessToken, String userId) async {
    final result = await _api.post('/auth/facebook', body: {
      'access_token': accessToken,
      'user_id': userId,
    });
    await _saveToken(result['access_token'], result['user_id']);
    return result;
  }

  Future<Map<String, dynamic>> getProfile() async {
    return await _api.get('/users/me');
  }

  Future<Map<String, dynamic>> updatePseudo(String pseudo) async {
    return await _api.patch('/users/me/pseudo', body: {'pseudo': pseudo});
  }

  Future<void> completeOnboarding() async {
    await _api.patch('/users/me/onboarding');
  }

  Future<void> restoreSession() async {
    final token = await _storage.read(key: _tokenKey);
    if (token != null) {
      _api.setToken(token);
    }
  }
}
