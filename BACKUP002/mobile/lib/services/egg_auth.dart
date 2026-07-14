import 'dart:math';
import 'color_extraction.dart';
import 'egg_vault.dart';

/// Distance de Hu (invariante échelle/rotation) entre deux signatures.
double huDistance(List<double> a, List<double> b) {
  if (a.length != b.length) return double.infinity;
  double s = 0.0;
  for (int i = 0; i < a.length; i++) {
    final sa = a[i].sign * log(a[i].abs() + 1e-9);
    final sb = b[i].sign * log(b[i].abs() + 1e-9);
    s += (sa - sb) * (sa - sb);
  }
  return sqrt(s);
}

int _popcount(int x) {
  int c = 0;
  x &= 0xFF;
  while (x > 0) {
    c += x & 1;
    x >>= 1;
  }
  return c;
}

int _hamming(List<int> a, List<int> b) {
  int d = 0;
  for (int i = 0; i < a.length; i++) {
    d += _popcount(a[i] ^ b[i]);
  }
  return d;
}

/// Distance moyenne (plan Lab a,b) entre deux signatures de couleur.
double colorDistance(Map<String, dynamic> candJson, Map<String, dynamic> refJson) {
  final a = SpatialSignature.fromJson(candJson);
  final b = SpatialSignature.fromJson(refJson);
  if (a.rows != b.rows || a.cols != b.cols) return double.infinity;
  double total = 0.0;
  int n = 0;
  for (int r = 0; r < a.rows; r++) {
    for (int c = 0; c < a.cols; c++) {
      final za = a.zones[r][c];
      final zb = b.zones[r][c];
      if (za.isEmpty || zb.isEmpty) continue;
      final la = a.meanColor(r, c);
      final lb = b.meanColor(r, c);
      total += la.distanceTo(lb);
      n++;
    }
  }
  return n == 0 ? double.infinity : total / n;
}

/// Résultat d'identification 100% on-device (aucun serveur).
class EggAuthResult {
  final String digit;
  final String decision; // 'reference' | 'authentique' | 'douteux' | 'contrefacon' | 'inconnu'
  final double score;
  final double digitScore;
  final double baseScore;
  final double colorScore;
  final double digitHuDist;
  final String message;
  final EggReference? matched;

  const EggAuthResult({
    required this.digit,
    required this.decision,
    required this.score,
    required this.digitScore,
    required this.baseScore,
    required this.colorScore,
    required this.digitHuDist,
    required this.message,
    this.matched,
  });

  factory EggAuthResult.reference(String digit) => EggAuthResult(
        digit: digit,
        decision: 'reference',
        score: 1.0,
        digitScore: 1.0,
        baseScore: 1.0,
        colorScore: 1.0,
        digitHuDist: 0.0,
        message: 'Référence de l\'œuf #$digit enregistrée sur cet appareil.\n'
            'Scanne le même œuf une 2e fois pour voir sa fiche.',
      );
}

/// Compare un scan candidat à la référence officielle stockée localement.
class EggAuth {
  static EggAuthResult compare({
    required String digit,
    required List<double> candidateHu,
    required EggBaseSample candidateBase,
    required Map<String, dynamic> candidateColor,
    required EggReference reference,
  }) {
    final dHu = huDistance(candidateHu, reference.hu);
    final digitScore = (1.0 - dHu / 2.0).clamp(0.0, 1.0);

    int good = 0;
    for (final c in candidateBase.descriptors) {
      int best = 1 << 30;
      for (final r in reference.base.descriptors) {
        final d = _hamming(c, r);
        if (d < best) best = d;
      }
      if (best <= 32) good++;
    }
    final baseScore = candidateBase.descriptors.isEmpty
        ? 0.0
        : (good / candidateBase.descriptors.length).clamp(0.0, 1.0);

    final dColor = colorDistance(candidateColor, reference.colorSignature);
    final colorScore =
        dColor == double.infinity ? 0.0 : (1.0 - dColor / 30.0).clamp(0.0, 1.0);

    if (dHu > 4.0) {
      return EggAuthResult(
        digit: digit,
        decision: 'contrefacon',
        score: 0.0,
        digitScore: digitScore,
        baseScore: baseScore,
        colorScore: colorScore,
        digitHuDist: dHu,
        message: 'Chiffre gravé NON conforme au moule enregistré '
            '(distance Hu ${dHu.toStringAsFixed(2)}).',
        matched: reference,
      );
    }

    final score =
        (0.50 * baseScore + 0.35 * colorScore + 0.15 * digitScore).clamp(0.0, 1.0);

    String decision;
    String message;
    if (score >= 0.65) {
      decision = 'authentique';
      message = 'Œuf #$digit — fiche conforme (moule + texture + couleur).';
    } else if (score >= 0.45) {
      decision = 'douteux';
      message = 'Œuf #$digit — fiche partiellement conforme.';
    } else {
      decision = 'contrefacon';
      message = 'Œuf #$digit — ne correspond pas à la référence enregistrée.';
    }

    return EggAuthResult(
      digit: digit,
      decision: decision,
      score: score,
      digitScore: digitScore,
      baseScore: baseScore,
      colorScore: colorScore,
      digitHuDist: dHu,
      message: message,
      matched: reference,
    );
  }

  /// Recherche la meilleure référence locale pour un scan.
  static EggAuthResult identify({
    required String digit,
    required List<double> candidateHu,
    required EggBaseSample candidateBase,
    required Map<String, dynamic> candidateColor,
    required List<EggReference> references,
  }) {
    EggReference? best;
    EggAuthResult? bestRes;
    double bestScore = -1;
    for (final ref in references) {
      final res = compare(
        digit: digit,
        candidateHu: candidateHu,
        candidateBase: candidateBase,
        candidateColor: candidateColor,
        reference: ref,
      );
      final s = res.score;
      if (s > bestScore) {
        bestScore = s;
        best = ref;
        bestRes = res;
      }
    }
    if (best == null || bestRes == null) {
      return EggAuthResult(
        digit: digit,
        decision: 'inconnu',
        score: 0.0,
        digitScore: 0.0,
        baseScore: 0.0,
        colorScore: 0.0,
        digitHuDist: 0.0,
        message: 'Aucune référence enregistrée pour l\'œuf #$digit sur cet appareil.',
      );
    }
    return bestRes;
  }
}
