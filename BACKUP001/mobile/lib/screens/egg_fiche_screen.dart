import 'package:flutter/material.dart';
import '../services/egg_auth.dart';
import '../services/egg_vault.dart';

/// Affiche la FICHE de l'œuf reconnu (vue « utilisateur à qui on a donné l'œuf »).
/// Aucun verdict passe/échec : on présente la pièce et sa conformité.
/// 100% on-device : aucune connexion au backend.
class EggFicheScreen extends StatelessWidget {
  final EggAuthResult result;
  final String? digitValue;
  final Map<String, dynamic>? enrollData;

  const EggFicheScreen({
    super.key,
    required this.result,
    required this.digitValue,
    this.enrollData,
  });

  String _formatDate(int? ms) {
    if (ms == null) return '—';
    final d = DateTime.fromMillisecondsSinceEpoch(ms).toLocal();
    return '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
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

  Future<void> _enroll(BuildContext context) async {
    if (enrollData == null || digitValue == null) return;
    final ref = EggReference(
      digit: digitValue!,
      hu: (enrollData!['hu'] as List).map((e) => (e as num).toDouble()).toList(),
      base: EggBaseSample.fromJson(enrollData!['base'] as Map<String, dynamic>),
      colorSignature: enrollData!['color'] as Map<String, dynamic>,
      createdAt: DateTime.now().millisecondsSinceEpoch,
    );
    await EggVault.save(ref);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Référence de l\'œuf #$digitValue enregistrée.')),
      );
      Navigator.popUntil(context, (r) => r.isFirst);
    }
  }

  @override
  Widget build(BuildContext context) {
    final matched = result.matched;
    final isFiche = result.decision == 'authentique' ||
        result.decision == 'douteux';
    final canEnroll = result.decision == 'inconnu';

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
                isFiche ? Icons.verified_user : Icons.egg,
                size: 64,
                color: isFiche ? Colors.greenAccent : Colors.amber,
              ),
              const SizedBox(height: 12),
              Text(
                isFiche
                    ? 'Œuf n°${digitValue ?? matched?.digit ?? ''}'
                    : 'Œuf #$digitValue',
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                isFiche
                    ? 'Série ${digitValue ?? matched?.digit} — collection Art-gens'
                    : (canEnroll
                        ? 'Aucune fiche enregistrée pour cette série sur cet appareil.'
                        : 'Ne correspond pas à la référence enregistrée sur cet appareil.'),
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 14),
              ),
              const SizedBox(height: 20),
              if (isFiche && matched != null)
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
                        _row('Série', '${digitValue ?? matched.digit}'),
                        _row('Créé le', _formatDate(matched.createdAt)),
                        const Divider(color: Colors.white24, height: 20),
                        _row('Moule officiel', 'oui'),
                        _row('Conformité générale', _pct(result.score)),
                        _row('  • texture (base)', _pct(result.baseScore)),
                        _row('  • couleur', _pct(result.colorScore)),
                        _row('  • chiffre gravé', _pct(result.digitScore)),
                      ],
                    ),
                  ),
                ),
              if (!isFiche)
                Card(
                  color: Colors.white10,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Text(
                      canEnroll
                          ? 'Aucune référence enregistrée pour cet œuf sur cet '
                              'appareil. Tu peux l\'enregistrer ci-dessous pour créer '
                              'sa fiche de référence.'
                          : 'Cet œuf ne correspond pas à la référence enregistrée '
                              'sur cet appareil (texture/couleur différentes).',
                      style: const TextStyle(color: Colors.white70, fontSize: 14),
                    ),
                  ),
                ),
              const SizedBox(height: 24),
              if (enrollData != null)
                ElevatedButton(
                  onPressed: () => _enroll(context),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.green,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                  child:
                      Text('Enregistrer comme référence de l\'œuf #$digitValue'),
                ),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () {
                  Navigator.popUntil(context, (r) => r.isFirst);
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.grey,
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
