import 'package:flutter/material.dart';
import '../models/user.dart';
import '../services/api_client.dart';
import '../services/auth_service.dart';


class AuthProvider extends ChangeNotifier {
  final AuthService _authService;

  User? _user;
  bool _isLoading = false;
  bool _isLoggedIn = false;
  String? _error;

  AuthProvider(this._authService, ApiClient apiClient);

  User? get user => _user;
  bool get isLoading => _isLoading;
  bool get isLoggedIn => _isLoggedIn;
  String? get error => _error;
  bool get needsOnboarding => _isLoggedIn && (_user?.onboardingCompleted == false);

  Future<void> tryRestoreSession() async {
    await _authService.restoreSession();
    final token = await _authService.getSavedToken();
    if (token != null) {
      try {
        final data = await _authService.getProfile();
        _user = User.fromJson(data);
        _isLoggedIn = true;
      } catch (_) {
        await _authService.logout();
      }
    }
    notifyListeners();
  }

  Future<bool> loginWithFacebook(String accessToken, String userId) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _authService.loginWithFacebook(accessToken, userId);
      final data = await _authService.getProfile();
      _user = User.fromJson(data);
      _isLoggedIn = true;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return false;
    }
  }

  Future<bool> loginWithGoogle(String idToken) async {
    _isLoading = true;
    _error = null;
    notifyListeners();

    try {
      await _authService.loginWithGoogle(idToken);
      final data = await _authService.getProfile();
      _user = User.fromJson(data);
      _isLoggedIn = true;
      _isLoading = false;
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      try {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          try {
            // Log to debug console if available
          } catch (_) {}
        });
      } catch (_) {}
      return false;
    }
  }

  Future<bool> setPseudo(String pseudo) async {
    try {
      final data = await _authService.updatePseudo(pseudo);
      _user = User.fromJson(data);
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<void> completeOnboarding() async {
    await _authService.completeOnboarding();
    if (_user != null) {
      _user = User(
        id: _user!.id,
        pseudo: _user!.pseudo,
        email: _user!.email,
        avatarUrl: _user!.avatarUrl,
        pinceauxBalance: _user!.pinceauxBalance,
        reputationScore: _user!.reputationScore,
        onboardingCompleted: true,
        createdAt: _user!.createdAt,
      );
    }
    notifyListeners();
  }

  Future<void> refreshProfile() async {
    try {
      final data = await _authService.getProfile();
      _user = User.fromJson(data);
      notifyListeners();
    } catch (_) {}
  }

  Future<void> logout() async {
    await _authService.logout();
    _user = null;
    _isLoggedIn = false;
    notifyListeners();
  }
}
