class User {
  final String id;
  final String pseudo;
  final String? email;
  final String? avatarUrl;
  final int pinceauxBalance;
  final double reputationScore;
  final bool onboardingCompleted;
  final DateTime createdAt;

  User({
    required this.id,
    required this.pseudo,
    this.email,
    this.avatarUrl,
    this.pinceauxBalance = 0,
    this.reputationScore = 1.0,
    this.onboardingCompleted = false,
    DateTime? createdAt,
  }) : createdAt = createdAt ?? DateTime.now();

  factory User.fromJson(Map<String, dynamic> json) {
    return User(
      id: json['id'] as String,
      pseudo: json['pseudo'] as String,
      email: json['email'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      pinceauxBalance: (json['pinceaux_balance'] as int?) ?? 0,
      reputationScore: (json['reputation_score'] as num?)?.toDouble() ?? 1.0,
      onboardingCompleted: (json['onboarding_completed'] as bool?) ?? false,
      createdAt: json['created_at'] != null
          ? DateTime.parse(json['created_at'] as String)
          : DateTime.now(),
    );
  }
}
