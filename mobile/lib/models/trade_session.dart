class TradeSession {
  final String id;
  final String participantAId;
  final String participantBId;
  final String? pieceAId;
  final String? pieceBId;
  final int deltaPinceaux;
  final String deltaDirection;
  final String status;
  final DateTime createdAt;
  final DateTime? completedAt;

  TradeSession({
    required this.id,
    required this.participantAId,
    required this.participantBId,
    this.pieceAId,
    this.pieceBId,
    this.deltaPinceaux = 0,
    this.deltaDirection = 'none',
    this.status = 'pending',
    DateTime? createdAt,
    this.completedAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory TradeSession.fromJson(Map<String, dynamic> json) {
    return TradeSession(
      id: json['id'] as String,
      participantAId: json['participant_a_id'] as String,
      participantBId: json['participant_b_id'] as String,
      pieceAId: json['piece_a_id'] as String?,
      pieceBId: json['piece_b_id'] as String?,
      deltaPinceaux: (json['delta_pinceaux'] as int?) ?? 0,
      deltaDirection: (json['delta_direction'] as String?) ?? 'none',
      status: (json['status'] as String?) ?? 'pending',
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
      completedAt: json['completed_at'] != null
          ? DateTime.parse(json['completed_at'] as String)
          : null,
    );
  }
}
