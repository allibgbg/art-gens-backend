import 'package:flutter/material.dart';
import '../models/egg_offer.dart';
import '../services/api_client.dart';

class EggOffersProvider extends ChangeNotifier {
  final ApiClient _api;

  List<EggOffer> _myOffers = [];
  bool _isLoading = false;
  String? _error;

  EggOffersProvider(this._api);

  List<EggOffer> get myOffers => _myOffers;
  bool get isLoading => _isLoading;
  String? get error => _error;

  List<EggOffer> get pendingReceived => _myOffers
      .where((o) => o.status == 'pending')
      .toList();

  Future<void> loadMyOffers() async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _api.getList('/egg-offers/me');
      _myOffers = data.map((j) => EggOffer.fromJson(j as Map<String, dynamic>)).toList();
      _error = null;
    } catch (e) {
      _error = e.toString();
    }
    _isLoading = false;
    notifyListeners();
  }

  Future<EggOffer?> createOffer({
    required String targetEggId,
    required String offeredEggId,
    int offeredPinceaux = 0,
  }) async {
    try {
      final result = await _api.post('/egg-offers/', body: {
        'target_egg_id': targetEggId,
        'offered_egg_id': offeredEggId,
        'offered_pinceaux': offeredPinceaux,
      });
      final offer = EggOffer.fromJson(result);
      _myOffers.insert(0, offer);
      notifyListeners();
      return offer;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }

  Future<bool> respondToOffer(String offerId, String action) async {
    try {
      final result = await _api.post('/egg-offers/$offerId/respond', body: {
        'action': action,
      });
      final idx = _myOffers.indexWhere((o) => o.id == offerId);
      if (idx >= 0) {
        _myOffers[idx] = EggOffer(
          id: _myOffers[idx].id,
          fromUserId: _myOffers[idx].fromUserId,
          fromUserPseudo: _myOffers[idx].fromUserPseudo,
          toUserId: _myOffers[idx].toUserId,
          toUserPseudo: _myOffers[idx].toUserPseudo,
          targetEggId: _myOffers[idx].targetEggId,
          targetEggDisplay: _myOffers[idx].targetEggDisplay,
          offeredEggId: _myOffers[idx].offeredEggId,
          offeredEggDisplay: _myOffers[idx].offeredEggDisplay,
          offeredPinceaux: _myOffers[idx].offeredPinceaux,
          status: result['status'] as String? ?? action,
          createdAt: _myOffers[idx].createdAt,
        );
      }
      notifyListeners();
      return true;
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return false;
    }
  }

  Future<EggOffer?> loadOffer(String offerId) async {
    try {
      final data = await _api.get('/egg-offers/$offerId');
      return EggOffer.fromJson(data);
    } catch (e) {
      _error = e.toString();
      notifyListeners();
      return null;
    }
  }
}
