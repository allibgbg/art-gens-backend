import 'package:flutter/material.dart';

/// Affiche la FICHE de l'œuf reconnu (vue « utilisateur à qui on a donné l'œuf »).
/// Pas de verdict passe/échec : on présente la pièce et sa conformité.
class EggFicheScreen extends StatelessWidget {
  final Map<String, dynamic> result;
  final String? digitValue;

  const EggFicheScreen({
    super.key,
    required this.result,
    required this.digitValue,
  });

  String _formatDate(String? iso) {
    if (iso == null) return '—';
    try {
      final d = DateTime.parse(iso).toLocal();
      return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
    } catch (_) {
      return iso;
    }
  }

  String _pct(dynamic v) {
    if (v == null) return '—';
    final n = (v as num).toDouble();
    return '${(n * 100).toStringAsFixed(0)}%';
  }

  Widget _row(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(label,
                style: const TextStyle(color: Colors.white54, fontSize: 14)),
          ),
          Expanded(
            child: Text(value,
                style: const TextStyle(color: Colors.white, fontSize: 15)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final identified = result['identified'] == true;
    final piece = identified ? result['piece'] as Map<String, dynamic>? : null;
    final mold = result['mold_official'];

    return Scaffold(
      appBar: AppBar(title: const Text('Fiche de l\'œuf')),
      body: Container(
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Icon(
                identified ? Icons.verified_user : Icons.egg,
                size: 64,
                color: identified ? Colors.greenAccent : Colors.amber,
              ),
              const SizedBox(height: 12),
              Text(
                identified
                    ? (piece != null
                        ? 'Œuf n°${piece['display_number']}'
                        : 'Œuf reconnu')
                    : 'Œuf non répertorié',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                identified
                    ? 'Série ${digitValue ?? piece?['series_value'] ?? '?'} — collection Art-gens'
                    : 'Ce scan ne correspond à aucune pièce enregistrée.',
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              if (identified && piece != null)
                Card(
                  color: Colors.white10,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _row('Série', '${piece['series_value']}'),
                        _row('Référence pinceaux', '${piece['reference_pinceaux_value']}'),
                        _row('Couleur', '${piece['color_primary']}'),
                        _row('Créé le', _formatDate(piece['creation_date'])),
                        if (piece['artist_note'] != null &&
                            '${piece['artist_note']}'.isNotEmpty)
                          _row('Note de l\'artiste',
                              '${piece['artist_note']}'),
                        const Divider(color: Colors.white24, height: 20),
                        _row('Moule officiel',
                            mold == null ? 'non défini' : (mold ? 'oui' : 'non')),
                        _row('Conformité générale', _pct(result['similarity'])),
                        _row('  • texture (base)', _pct(result['texture_similarity'])),
                        _row('  • couleur', _pct(result['color_similarity'])),
                        _row('  • chiffre gravé', _pct(result['digit_similarity'])),
                      ],
                    ),
                  ),
                ),
              if (!identified)
                Card(
                  color: Colors.white10,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Aucune fiche ne correspond à ce scan. L\'œuf n\'est pas '
                      'enregistré dans la collection, ou la capture était '
                      'trop floue / incomplète. Réessaie un scan plus net.',
                      style: TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              ElevatedButton(
                onPressed: () {
                  Navigator.popUntil(context, (r) => r.isFirst);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.green,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(vertical: 14),
                ),
                child: const Text('Fermer'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
