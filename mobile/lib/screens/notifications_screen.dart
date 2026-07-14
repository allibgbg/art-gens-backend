import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/app_notification.dart';
import '../providers/notifications_provider.dart';
import '../providers/egg_offers_provider.dart';

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});

  @override
  State<NotificationsScreen> createState() => _NotificationsScreenState();
}

class _NotificationsScreenState extends State<NotificationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationsProvider>().loadNotifications();
    });
  }

  IconData _iconForType(String type) {
    switch (type) {
      case 'egg_offer_received': return Icons.swap_horiz;
      case 'egg_offer_accepted': return Icons.check_circle;
      case 'egg_offer_declined': return Icons.cancel;
      case 'message_received': return Icons.message;
      default: return Icons.notifications;
    }
  }

  Color _colorForType(String type) {
    switch (type) {
      case 'egg_offer_received': return Colors.amber;
      case 'egg_offer_accepted': return Colors.green;
      case 'egg_offer_declined': return Colors.red;
      case 'message_received': return Colors.blue;
      default: return Colors.grey;
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notifications'),
        actions: [
          TextButton(
            onPressed: () => context.read<NotificationsProvider>().markAllRead(),
            child: const Text('Tout lire'),
          ),
        ],
      ),
      body: Consumer<NotificationsProvider>(
        builder: (_, provider, __) {
          if (provider.isLoading) {
            return const Center(child: CircularProgressIndicator());
          }
          if (provider.notifications.isEmpty) {
            return const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.notifications_none, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Aucune notification'),
                ],
              ),
            );
          }
          return ListView.builder(
            itemCount: provider.notifications.length,
            itemBuilder: (_, i) {
              final notif = provider.notifications[i];
              return _NotificationTile(
                notification: notif,
                icon: _iconForType(notif.type),
                color: _colorForType(notif.type),
                onTap: () => _handleTap(context, notif),
              );
            },
          );
        },
      ),
    );
  }

  void _handleTap(BuildContext context, AppNotification notif) {
    context.read<NotificationsProvider>().markRead(notif.id);

    if (notif.type == 'message_received' && notif.eggOfferId != null) {
      _openMessages(context, notif.eggOfferId!);
    } else if (notif.eggOfferId != null) {
      _openOffer(context, notif.eggOfferId!);
    }
  }

  void _openMessages(BuildContext context, String offerId) async {
    final offers = context.read<EggOffersProvider>();
    final offer = await offers.loadOffer(offerId);
    if (offer != null && context.mounted) {
      Navigator.pushNamed(context, '/messages', arguments: {
        'offerId': offerId,
        'offerTitle': 'Échange avec ${offer.fromUserId == offer.toUserId ? 'vous-même' : (offer.fromUserPseudo ?? offer.toUserPseudo ?? 'inconnu')}',
      });
    }
  }

  void _openOffer(BuildContext context, String offerId) async {
    final offers = context.read<EggOffersProvider>();
    final offer = await offers.loadOffer(offerId);
    if (offer != null && context.mounted) {
      showDialog(
        context: context,
        builder: (_) => _OfferDetailDialog(offer: offer),
      );
    }
  }
}

class _NotificationTile extends StatelessWidget {
  final AppNotification notification;
  final IconData icon;
  final Color color;
  final VoidCallback onTap;

  const _NotificationTile({
    required this.notification,
    required this.icon,
    required this.color,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final timeAgo = notification.createdAt != null
        ? _formatTimeAgo(notification.createdAt!)
        : '';

    return ListTile(
      leading: CircleAvatar(
        backgroundColor: color.withOpacity(0.2),
        child: Icon(icon, color: color, size: 20),
      ),
      title: Text(
        notification.content ?? '',
        style: TextStyle(
          fontWeight: notification.isRead ? FontWeight.normal : FontWeight.bold,
        ),
      ),
      subtitle: Text(timeAgo, style: const TextStyle(fontSize: 12)),
      trailing: notification.isRead
          ? null
          : Container(
              width: 8,
              height: 8,
              decoration: const BoxDecoration(
                color: Colors.blue,
                shape: BoxShape.circle,
              ),
            ),
      onTap: onTap,
    );
  }

  String _formatTimeAgo(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return 'à l\'instant';
    if (diff.inMinutes < 60) return 'il y a ${diff.inMinutes} min';
    if (diff.inHours < 24) return 'il y a ${diff.inHours}h';
    if (diff.inDays < 7) return 'il y a ${diff.inDays}j';
    return '${dt.day}/${dt.month}/${dt.year}';
  }
}

class _OfferDetailDialog extends StatelessWidget {
  final dynamic offer;
  const _OfferDetailDialog({required this.offer});

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(offer.status == 'pending' ? 'Offre en attente' : 'Offre ${offer.status}'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('De : ${offer.fromUserPseudo ?? "?"}'),
          Text('Cible : ${offer.targetEggDisplay ?? "?"}'),
          Text('Offre : ${offer.offeredEggDisplay ?? "?"}'),
          Text('Pinceaux : ${offer.offeredPinceaux} 🖌'),
        ],
      ),
      actions: [
        if (offer.status == 'pending') ...[
          TextButton(
            onPressed: () async {
              await context.read<EggOffersProvider>().respondToOffer(offer.id, 'decline');
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Refuser', style: TextStyle(color: Colors.red)),
          ),
          FilledButton(
            onPressed: () async {
              await context.read<EggOffersProvider>().respondToOffer(offer.id, 'accept');
              if (context.mounted) Navigator.pop(context);
            },
            child: const Text('Accepter'),
          ),
        ] else
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Fermer'),
          ),
      ],
    );
  }
}
