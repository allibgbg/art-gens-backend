class Offer {
  final String id;
  final String fromUserId;
  final String toUserId;
  final String targetPieceId;
  final String offeredPieceId;
  final int offeredPinceaux;
  final String status;
  final DateTime createdAt;

  Offer({
    required this.id,
    required this.fromUserId,
    required this.toUserId,
    required this.targetPieceId,
    required this.offeredPieceId,
    this.offeredPinceaux = 0,
    this.status = 'pending',
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory Offer.fromJson(Map<String, dynamic> json) {
    return Offer(
      id: json['id'] as String,
      fromUserId: json['from_user_id'] as String,
      toUserId: json['to_user_id'] as String,
      targetPieceId: json['target_piece_id'] as String,
      offeredPieceId: json['offered_piece_id'] as String,
      offeredPinceaux: (json['offered_pinceaux'] as int?) ?? 0,
      status: (json['status'] as String?) ?? 'pending',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }
}
