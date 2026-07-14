class TradeMessageModel {
  final String id;
  final String senderId;
  final String content;
  final DateTime? createdAt;

  TradeMessageModel({
    required this.id,
    required this.senderId,
    required this.content,
    this.createdAt,
  });

  factory TradeMessageModel.fromJson(Map<String, dynamic> json) {
    return TradeMessageModel(
      id: json['id'] as String,
      senderId: json['sender_id'] as String,
      content: json['content'] as String,
      createdAt: json['created_at'] != null
          ? DateTime.tryParse(json['created_at'] as String)
          : null,
    );
  }
}
