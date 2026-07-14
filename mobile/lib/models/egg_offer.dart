class EggOffer {
  final String id;
  final String fromUserId;
  final String? fromUserPseudo;
  final String toUserId;
  final String? toUserPseudo;
  final String targetEggId;
  final String? targetEggDisplay;
  final String offeredEggId;
  final String? offeredEggDisplay;
  final int offeredPinceaux;
  final String status;
  final DateTime? createdAt;

  EggOffer({
    required this.id,
    required this.fromUserId,
    this.fromUserPseudo,
    required this.toUserId,
    this.toUserPseudo,
    required this.targetEggId,
    this.targetEggDisplay,
    required this.offeredEggId,
    this.offeredEggDisplay,
    this.offeredPinceaux = 0,
    this.status = 'pending',
    this.createdAt,
  });

  factory EggOffer.fromJson(Map<String, dynamic> json) {
    return EggOffer(
      id: json['id'] as String,
      fromUserId: json['from_user_id'] as String,
      fromUserPseudo: json['from_user_pseudo'] as String?,
      toUserId: json['to_user_id'] as String,
      toUserPseudo: json['to_user_pseudo'] as String?,
      targetEggId: json['target_egg_id'] as String,
      targetEggDisplay: json['target_egg_display'] as String?,
      offeredEggId: json['offered_egg_id'] as String,
      offeredEggDisplay: json['offered_egg_display'] as String?,
      offeredPinceaux: json['offered_pinceaux'] as int? ?? 0,
      status: json['status'] as String? ?? 'pending',
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }
}
