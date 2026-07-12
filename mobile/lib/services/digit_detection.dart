import 'dart:math' as math;
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'texture_extraction.dart';

/// Résultat de la détection du chiffre gravé.
/// [value] vaut '2' ou '5' (null si non détecté/peu confiant),
/// [confidence] ∈ [0,1], [box] = boîte englobante dans l'image grayscale
/// (coordonnées en pixels de la matrice h×w, utile pour suivre le déplacement
/// du chiffre en rotation).
class DigitDetectionResult {
  final String? value;
  final double confidence;
  final cv.Rect? box;
  final List<double>? hu;
  const DigitDetectionResult(this.value, this.confidence, this.box, this.hu);
}

/// Références de template : signature Hu EXACTE du chiffre moulé, capturée
/// lors de la confirmation de l'utilisateur. Tous les moules d'une série ont
/// la même forme, donc on exige une correspondance TRÈS serrée avec ce template
/// (et pas avec "n'importe quel 5"). Clef = '2' ou '5'.
Map<String, List<double>> _customRefs = {};

/// Enregistre le template du chiffre moulé (signé par l'utilisateur).
void setDigitReference(String value, List<double> hu) {
  _customRefs[value] = List<double>.from(hu);
}

/// Dernière info de debug (métriques du meilleur contour / raison de rejet).
/// Utile pour diagnostiquer pourquoi un chiffre n'est pas détecté.
String digitDebug = '';

/// Oublie les templates (nouvelle session de scan).
void clearDigitReferences() {
  _customRefs.clear();
}

/// Détecte le chiffre gravé (2 ou 5) depuis une matrice grayscale CV_8UC1.
/// [enforceCentering] : si true, rejette le chiffre s'il n'est pas proche du
/// centre (utilisé par le scan 1 où l'on cadre le dessus). false pour le scan 3
/// où le chiffre se déplace librement dans l'image et sert de repère de rotation.
DigitDetectionResult detectDigit(cv.Mat gray, {bool enforceCentering = false}) {
  try {
    final imgArea = gray.rows * gray.cols;
    final clahe = cv.CLAHE(2.0, (8, 8));
    final enhanced = clahe.apply(gray);
    clahe.dispose();

    final blurred = cv.gaussianBlur(enhanced, (5, 5), 0);
    enhanced.dispose();

    final bin = cv.adaptiveThreshold(
      blurred, 255.0, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY_INV, 31, 5.0,
    );
    blurred.dispose();

    final kernel = cv.getStructuringElement(cv.MORPH_RECT, (3, 3));
    final cleaned = cv.morphologyEx(bin, cv.MORPH_OPEN, kernel);
    bin.dispose();
    kernel.dispose();

    final (contours, _) = cv.findContours(cleaned, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);

    // Références calibrées sur vrais moules (séries 2 et 5 uniquement).
    const ref2 = [-0.91, -0.42, -1.62, -0.47];
    const ref5 = [0.57, 1.99, 4.78, 5.38];
    double sq(double x) => x * x;
    double huDist(List<double> a, List<double> b) {
      double s = 0;
      for (int i = 0; i < 4; i++) s += sq(a[i] - b[i]);
      return math.sqrt(s);
    }

    // On cherche le chiffre parmi TOUS les contours (pas seulement le plus
    // grand) : le chiffre moulé en relief n'est pas forcément le plus gros
    // contour de l'image (l'œuf en béton mat occupe beaucoup plus de pixels).
    // On garde le contour dont la forme ressemble le plus à un chiffre moulé
    // (distance Hu minimale).
    double bestDist = double.infinity;
    cv.VecPoint? best;
    cv.Rect? bestRect;
    List<double>? bestHu;
    String bestGuess = '5';
    double bestArea = 0, bestAspect = 0, bestSol = 0;

    for (final c in contours) {
      final a = cv.contourArea(c);
      if (a < imgArea * 0.0015) continue; // bruit
      if (a > imgArea * 0.4) continue; // trop grand = pas un chiffre
      final r = cv.boundingRect(c);
      final aspect = r.width / math.max(1, r.height);
      if (aspect < 0.15 || aspect > 3.0) continue;
      final solidity = a / (r.width * r.height);
      if (solidity < 0.02 || solidity > 0.98) continue;
      final roi = cleaned.region(r);
      final m = cv.moments(roi, binaryImage: true);
      roi.dispose();
      final nu20 = m.nu20, nu02 = m.nu02, nu11 = m.nu11;
      final nu30 = m.nu30, nu12 = m.nu12, nu21 = m.nu21, nu03 = m.nu03;
      m.dispose();
      final hu = <double>[
        nu20 + nu02,
        sq(nu20 - nu02) + 4 * sq(nu11),
        sq(nu30 - 3 * nu12) + sq(3 * nu21 - nu03),
        sq(nu30 + nu12) + sq(nu21 + nu03),
      ];
      final huLog = hu.map((v) => -v.sign * math.log(v.abs() + 1e-10)).toList();
      final huLogUsed = huLog.sublist(0, 4);
      double d;
      String guess;
      if (huLogUsed[2] > 0) {
        guess = '5';
        d = huDist(huLogUsed, ref5);
      } else if (huLogUsed[2] < 0) {
        guess = '2';
        d = huDist(huLogUsed, ref2);
      } else {
        final d2 = huDist(huLogUsed, ref2);
        final d5 = huDist(huLogUsed, ref5);
        guess = d2 < d5 ? '2' : '5';
        d = math.min(d2, d5);
      }
      if (d < bestDist) {
        bestDist = d;
        best = c;
        bestRect = r;
        bestHu = huLogUsed;
        bestGuess = guess;
        bestArea = a;
        bestAspect = aspect;
        bestSol = solidity;
      }
      if (bestDist < 0.3) break; // match quasi parfait, on arrête
    }
    contours.dispose();

    if (best == null) {
      digitDebug = 'aucun contour plausible';
      cleaned.dispose();
      return const DigitDetectionResult(null, 0, null, null);
    }
    final rect = bestRect!;
    final areaRatio = bestArea / imgArea;
    final huLogUsed = bestHu!;
    cleaned.dispose();

    // Mode authentification : si un template du chiffre moulé a été confirmé,
    // on exige une correspondance TRÈS serrée avec CE template précis. Un
    // autre "5" (imprimé, d'un autre moule) est rejeté -> scan d'authentification.
    if (_customRefs.isNotEmpty) {
      String? bestVal;
      double bestD = double.infinity;
      _customRefs.forEach((val, ref) {
        final d = huDist(huLogUsed, ref);
        if (d < bestD) {
          bestD = d;
          bestVal = val;
        }
      });
      const tol = 1.2;
      digitDebug = 'auth d=$bestD tol=$tol';
      if (bestD > tol) {
        return const DigitDetectionResult(null, 0, null, null);
      }
      final c = (1.0 - bestD / tol).clamp(0.0, 1.0);
      return DigitDetectionResult(bestVal!, c, rect, huLogUsed);
    }

    // Sans template confirmé : proposition générique (l'utilisateur confirmera).
    // La 3e composante de Hu (hu2, index 2) est un discriminant quasi parfait
    // sur les échantillons réels (5 > 0, 2 < 0).
    final guess = bestGuess;
    final conf = (1.0 - bestDist / 10.0).clamp(0.0, 1.0);
    digitDebug =
        'prop $guess conf=${conf.toStringAsFixed(3)} area=$areaRatio aspect=${bestAspect.toStringAsFixed(2)} sol=${bestSol.toStringAsFixed(2)}';

    // Rejeter si pas assez confiant (évite les faux positifs sur le fond).
    if (conf < 0.6) return const DigitDetectionResult(null, 0, null, null);

    return DigitDetectionResult(guess, conf, rect, huLogUsed);
  } catch (_) {
    return     const DigitDetectionResult(null, 0, null, null);
  }
}

/// Détecte le chiffre gravé depuis une [CameraImage] (convertit le plan Y
/// en grayscale en gérant le stride, via [yPlaneToGrayMat]).
DigitDetectionResult detectDigitFromImage(CameraImage image, {bool enforceCentering = false}) {
  final gray = yPlaneToGrayMat(image);
  if (gray == null) return     const DigitDetectionResult(null, 0, null, null);
  final result = detectDigit(gray, enforceCentering: enforceCentering);
  gray.dispose();
  return result;
}
