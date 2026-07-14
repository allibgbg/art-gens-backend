import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import '../models/piece.dart';
import '../services/api_client.dart';

class PiecesProvider extends ChangeNotifier {
  final ApiClient _api;

  List<Piece> _pieces = [];
  List<Piece> _myPieces = [];
  List<Piece> _eggPieces = [];
  Piece? _selectedPiece;
  bool _isLoading = false;
  String? _error;

  PiecesProvider(this._api);

  List<Piece> get pieces => _pieces;
  List<Piece> get myPieces => [..._eggPieces, ..._myPieces];
  List<Piece> get eggPieces => _eggPieces;
  Piece? get selectedPiece => _selectedPiece;
  bool get isLoading => _isLoading;
  String? get error => _error;

  // -- Egg identities (server only) -----------------------------------------

  String _serverIdToDisplay(Map<String, dynamic> m) {
    final series = m['series_value'] as int? ?? 0;
    final digit = m['digit_number'] as String? ?? '0';
    return '$series-${digit.padLeft(3, '0')}';
  }

  Piece _eggToPiece(Map<String, dynamic> m, {String? localPhotoPath}) {
    final id = m['id'] as String;
    return Piece(
      id: 'egg_$id',
      displayNumber: m['display_number'] as String? ?? _serverIdToDisplay(m),
      seriesValue: m['series_value'] as int? ?? 0,
      referencePinceauxValue: m['reference_pinceaux_value'] as int? ?? 0,
      colorPrimary: 'multicolore',
      materialNotes: m['notes'] as String?,
      creationDate: m['created_at'] != null
          ? DateTime.tryParse(m['created_at'] as String)
          : null,
      artistNote: 'Serveur (${m['points_count'] ?? '?'} points)',
      photoUrl: localPhotoPath,
    );
  }

  String _extractServerId(String pieceId) {
    if (pieceId.startsWith('egg_')) return pieceId.substring(4);
    return pieceId;
  }

  Future<void> loadEggIdentities() async {
    try {
      final data = await _api.getList('/egg-identity/');
      final dir = await getApplicationDocumentsDirectory();
      final cacheDir = '${dir.path}/egg_faces';
      await Directory(cacheDir).create(recursive: true);

      final List<Piece> loaded = [];
      for (final j in data) {
        final m = j as Map<String, dynamic>;
        final serverId = m['id'] as String;
        String? localPath;

        if (m['has_face_photo'] == true) {
          final cachedFile = '$cacheDir/$serverId.jpg';
          if (await File(cachedFile).exists()) {
            localPath = cachedFile;
          } else {
            try {
              final detail = await _api.get('/egg-identity/$serverId');
              final b64 = detail['face_photo'] as String?;
              if (b64 != null && b64.isNotEmpty) {
                await File(cachedFile).writeAsBytes(base64Decode(b64));
                localPath = cachedFile;
              }
            } catch (_) {}
          }
        }

        loaded.add(_eggToPiece(m, localPhotoPath: localPath));
      }
      _eggPieces = loaded;
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    notifyListeners();
  }

  Future<String?> addEggIdentity({
    required String displayNumber,
    required int seriesValue,
    int? pinceauxValue,
    String? digitNumber,
    String? notes,
    String? facePhoto,
    required Map<String, dynamic> identityData,
  }) async {
    try {
      final result = await _api.post('/egg-identity/', body: {
        'display_number': displayNumber,
        'series_value': seriesValue,
        'reference_pinceaux_value': pinceauxValue ?? 0,
        'digit_number': digitNumber,
        'notes': notes,
        'face_photo': facePhoto,
        'identity_data': identityData,
      });
      final serverId = result['id'] as String?;
      if (serverId != null) {
        _eggPieces.insert(0, _eggToPiece({
          'id': serverId,
          'display_number': displayNumber,
          'series_value': seriesValue,
          'reference_pinceaux_value': pinceauxValue ?? 0,
          'digit_number': digitNumber,
          'notes': notes,
          'points_count': (identityData['points'] as List?)?.length ?? 0,
          'created_at': DateTime.now().toIso8601String(),
        }));
        notifyListeners();
      }
      return serverId;
    } catch (_) {
      return null;
    }
  }

  Future<void> updateEggIdentity(String pieceId, {
    int? seriesValue,
    String? displayNumber,
    String? notes,
    int? pinceauxValue,
    String? facePhoto,
    String? localPhotoPath,
  }) async {
    final serverId = _extractServerId(pieceId);
    final body = <String, dynamic>{};
    if (seriesValue != null) body['series_value'] = seriesValue;
    if (displayNumber != null) body['display_number'] = displayNumber;
    if (notes != null) body['notes'] = notes;
    if (pinceauxValue != null) body['reference_pinceaux_value'] = pinceauxValue;
    if (facePhoto != null) body['face_photo'] = facePhoto;
    if (body.isEmpty) return;

    try {
      await _api.patch('/egg-identity/$serverId', body: body);
    } catch (_) {}

    // Update local cache
    final idx = _eggPieces.indexWhere((p) => p.id == pieceId);
    if (idx < 0) return;
    final old = _eggPieces[idx];
    _eggPieces[idx] = Piece(
      id: old.id,
      displayNumber: displayNumber ?? old.displayNumber,
      seriesValue: seriesValue ?? old.seriesValue,
      referencePinceauxValue: pinceauxValue ?? old.referencePinceauxValue,
      colorPrimary: old.colorPrimary,
      materialNotes: notes ?? old.materialNotes,
      creationDate: old.creationDate,
      artistNote: old.artistNote,
      photoUrl: localPhotoPath ?? old.photoUrl,
    );
    notifyListeners();
  }

  Future<void> removeEggIdentity(String pieceId) async {
    final serverId = _extractServerId(pieceId);
    try {
      await _api.delete('/egg-identity/$serverId');
    } catch (_) {}
    _eggPieces.removeWhere((p) => p.id == pieceId);
    notifyListeners();
  }

  // -- Server pieces (art pieces, not eggs) ---------------------------------

  Future<void> loadAllPieces({Map<String, String>? filters}) async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _api.getList('/pieces/', queryParams: filters);
      _pieces = data.map((j) => Piece.fromJson(j as Map<String, dynamic>)).toList();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<void> loadMyPieces() async {
    try {
      final data = await _api.getList('/users/me/pieces');
      _myPieces = data.map((j) => Piece.fromJson(j as Map<String, dynamic>)).toList();
      notifyListeners();
    } catch (e) {
      _error = e.toString();
      notifyListeners();
    }
  }

  Future<Piece?> loadPieceDetails(String pieceId) async {
    try {
      final data = await _api.get('/pieces/$pieceId');
      _selectedPiece = Piece.fromJson(data);
      notifyListeners();
      return _selectedPiece;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<List<Map<String, dynamic>>> loadProvenance(String pieceId) async {
    try {
      final data = await _api.getList('/pieces/$pieceId/provenance');
      return data.map((j) => j as Map<String, dynamic>).toList();
    } catch (e) {
      return [];
    }
  }
}
