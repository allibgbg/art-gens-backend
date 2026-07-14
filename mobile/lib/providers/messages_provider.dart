import 'package:flutter/material.dart';
import '../models/trade_message.dart';
import '../services/api_client.dart';

class MessagesProvider extends ChangeNotifier {
  final ApiClient _api;

  List<TradeMessageModel> _messages = [];
  bool _isLoading = false;

  MessagesProvider(this._api);

  List<TradeMessageModel> get messages => _messages;
  bool get isLoading => _isLoading;

  Future<void> loadMessages(String offerId) async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _api.getList('/egg-offers/$offerId/messages');
      _messages = data.map((j) => TradeMessageModel.fromJson(j as Map<String, dynamic>)).toList();
    } catch (_) {}
    _isLoading = false;
    notifyListeners();
  }

  Future<bool> sendMessage(String offerId, String content) async {
    try {
      final data = await _api.post('/egg-offers/$offerId/messages', body: {
        'content': content,
      });
      _messages.add(TradeMessageModel.fromJson(data));
      notifyListeners();
      return true;
    } catch (e) {
      return false;
    }
  }
}
