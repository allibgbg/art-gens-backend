class Piece {
  final String id;
  final String displayNumber;
  final int seriesValue;
  final int referencePinceauxValue;
  final String colorPrimary;
  final String? colorSecondary;
  final Map<String, dynamic>? colorSignature;
  final String? materialNotes;
  final DateTime creationDate;
  final String? artistNote;
  final String? currentOwnerId;
  final String status;
  final String? photoUrl;

  Piece({
    required this.id,
    required this.displayNumber,
    required this.seriesValue,
    required this.referencePinceauxValue,
    required this.colorPrimary,
    this.colorSecondary,
    this.colorSignature,
    this.materialNotes,
    DateTime? creationDate,
    this.artistNote,
    this.currentOwnerId,
    this.status = 'non_distribue',
    this.photoUrl,
  }) : creationDate = creationDate ?? DateTime.now();

  factory Piece.fromJson(Map<String, dynamic> json) {
    return Piece(
      id: json['id'] as String,
      displayNumber: json['display_number'] as String,
      seriesValue: json['series_value'] as int,
      referencePinceauxValue: json['reference_pinceaux_value'] as int,
      colorPrimary: json['color_primary'] as String,
      colorSecondary: json['color_secondary'] as String?,
      colorSignature: json['color_signature'] as Map<String, dynamic>?,
      materialNotes: json['material_notes'] as String?,
      creationDate: json['creation_date'] != null
          ? DateTime.parse(json['creation_date'] as String)
          : DateTime.now(),
      artistNote: json['artist_note'] as String?,
      currentOwnerId: json['current_owner_id'] as String?,
      status: (json['status'] as String?) ?? 'non_distribue',
      photoUrl: json['photo_url'] as String?,
    );
  }
}
