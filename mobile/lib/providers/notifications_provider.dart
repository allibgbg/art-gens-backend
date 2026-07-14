import 'package:flutter/material.dart';
import '../models/app_notification.dart';
import '../services/api_client.dart';

class NotificationsProvider extends ChangeNotifier {
  final ApiClient _api;

  List<AppNotification> _notifications = [];
  int _unreadCount = 0;
  bool _isLoading = false;

  NotificationsProvider(this._api);

  List<AppNotification> get notifications => _notifications;
  int get unreadCount => _unreadCount;
  bool get isLoading => _isLoading;

  Future<void> loadNotifications() async {
    _isLoading = true;
    notifyListeners();
    try {
      final data = await _api.get('/notifications/');
      _notifications = (data['notifications'] as List)
          .map((j) => AppNotification.fromJson(j as Map<String, dynamic>))
          .toList();
      _unreadCount = data['unread_count'] as int? ?? 0;
    } catch (_) {}
    _isLoading = false;
    notifyListeners();
  }

  Future<void> markRead(String notificationId) async {
    try {
      await _api.patch('/notifications/$notificationId/read');
      final idx = _notifications.indexWhere((n) => n.id == notificationId);
      if (idx >= 0) {
        _notifications[idx] = AppNotification(
          id: _notifications[idx].id,
          type: _notifications[idx].type,
          eggOfferId: _notifications[idx].eggOfferId,
          content: _notifications[idx].content,
          isRead: true,
          createdAt: _notifications[idx].createdAt,
        );
        if (_unreadCount > 0) _unreadCount--;
        notifyListeners();
      }
    } catch (_) {}
  }

  Future<void> markAllRead() async {
    try {
      await _api.patch('/notifications/read-all');
      _notifications = _notifications.map((n) => AppNotification(
        id: n.id,
        type: n.type,
        eggOfferId: n.eggOfferId,
        content: n.content,
        isRead: true,
        createdAt: n.createdAt,
      )).toList();
      _unreadCount = 0;
      notifyListeners();
    } catch (_) {}
  }
}
