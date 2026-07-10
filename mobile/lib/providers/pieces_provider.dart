import 'package:flutter/material.dart';
import '../models/piece.dart';
import '../services/api_client.dart';

class PiecesProvider extends ChangeNotifier {
  final ApiClient _api;

  List<Piece> _pieces = [];
  List<Piece> _myPieces = [];
  Piece? _selectedPiece;
  bool _isLoading = false;
  String? _error;

  PiecesProvider(this._api);

  List<Piece> get pieces => _pieces;
  List<Piece> get myPieces => _myPieces;
  Piece? get selectedPiece => _selectedPiece;
  bool get isLoading => _isLoading;
  String? get error => _error;

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
