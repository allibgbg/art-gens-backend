import 'package:flutter/material.dart';
import '../models/trade_session.dart';
import '../services/api_client.dart';

class TradeProvider extends ChangeNotifier {
  final ApiClient _api;

  TradeSession? _currentSession;
  bool _isLoading = false;
  String? _error;

  TradeProvider(this._api);

  TradeSession? get currentSession => _currentSession;
  bool get isLoading => _isLoading;
  String? get error => _error;

  Future<TradeSession?> createSession(String participantBId) async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _api.post('/trades/?participant_b_id=$participantBId');
      _currentSession = TradeSession.fromJson(data);
      _isLoading = false;
      notifyListeners();
      return _currentSession;
    } catch (e) {
      _error = e.toString();
      _isLoading = false;
      notifyListeners();
      return null;
    }
  }

  Future<TradeSession?> getSession(String sessionId) async {
    try {
      final data = await _api.get('/trades/$sessionId');
      _currentSession = TradeSession.fromJson(data);
      notifyListeners();
      return _currentSession;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<void> scanPiece(String sessionId, String pieceId,
      Map<String, dynamic> captureData, Map<String, dynamic> colorSignature) async {
    try {
      final data = await _api.post('/trades/$sessionId/scan', body: {
        'trade_session_id': sessionId,
        'piece_id': pieceId,
        'capture_data': captureData,
        'color_signature': colorSignature,
      });
      _currentSession = TradeSession.fromJson(data);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> updateDelta(String sessionId, int delta, String direction) async {
    try {
      final data = await _api.post('/trades/$sessionId/delta', body: {
        'trade_session_id': sessionId,
        'delta_pinceaux': delta,
        'delta_direction': direction,
      });
      _currentSession = TradeSession.fromJson(data);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<void> confirm(String sessionId) async {
    try {
      final data = await _api.post('/trades/$sessionId/confirm', body: {
        'trade_session_id': sessionId,
      });
      _currentSession = TradeSession.fromJson(data);
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }
}
