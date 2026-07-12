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
    double maxArea = 0;
    cv.VecPoint? best;
    double totalArea = 0;
    int bigCount = 0;
    for (final c in contours) {
      final a = cv.contourArea(c);
      totalArea += a;
      if (a > maxArea) { maxArea = a; best = c; }
      if (a > imgArea * 0.005) bigCount++;
    }
    if (best == null || best.length < 10) {
      cleaned.dispose(); contours.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }
    // Un chiffre gravé sur un objet propre DOMINE la scène (peu d'autres
    // contours). Un fond chargé (décor, objets) a beaucoup de contours -> on
    // rejette pour éviter les faux positifs sur l'environnement.
    if (totalArea > 0 && maxArea / totalArea < 0.4) {
      cleaned.dispose(); contours.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }
    if (bigCount > 12) {
      cleaned.dispose(); contours.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }

    final rect = cv.boundingRect(best);
    contours.dispose();

    final areaRatio = maxArea / imgArea;
    if (areaRatio < 0.008 || areaRatio > 0.30) {
      cleaned.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }
    final aspect = rect.width / math.max(1, rect.height);
    if (aspect < 0.35 || aspect > 1.4) {
      cleaned.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }
    // Un chiffre gravé est un trait FIN (faible solidité). Un blob plein, une
    // ombre ou une tache de fond a une solidité élevée -> on rejette. C'est le
    // principal discriminant contre les faux positifs sur fond vide/bruité.
    final solidity = maxArea / (rect.width * rect.height);
    if (solidity < 0.08 || solidity > 0.55) {
      cleaned.dispose();
      return     const DigitDetectionResult(null, 0, null, null);
    }

    if (enforceCentering) {
      final cx = rect.x + rect.width / 2;
      final cy = rect.y + rect.height / 2;
      final dC = math.sqrt(
        (cx - gray.cols / 2) * (cx - gray.cols / 2) +
        (cy - gray.rows / 2) * (cy - gray.rows / 2),
      );
      if (dC > math.min(gray.cols, gray.rows) * 0.40) {
        cleaned.dispose();
        return     const DigitDetectionResult(null, 0, null, null);
      }
    }

    final roi = cleaned.region(rect);
    cleaned.dispose();

    // Moments de Hu sur le masque binaire du chiffre (dartcv4 n'exporte pas
    // HuMoments -> calcul manuel à partir des moments normalisés).
    final m = cv.moments(roi, binaryImage: true);
    roi.dispose();
    final nu20 = m.nu20, nu02 = m.nu02, nu11 = m.nu11;
    final nu30 = m.nu30, nu12 = m.nu12, nu21 = m.nu21, nu03 = m.nu03;
    m.dispose();

    double sq(double x) => x * x;
    final hu = <double>[
      nu20 + nu02,
      sq(nu20 - nu02) + 4 * sq(nu11),
      sq(nu30 - 3 * nu12) + sq(3 * nu21 - nu03),
      sq(nu30 + nu12) + sq(nu21 + nu03),
      (nu30 - 3 * nu12) * (nu30 + nu12) * (sq(nu30 + nu12) - 3 * sq(nu21 + nu03))
          + (3 * nu21 - nu03) * (nu21 + nu03) * (3 * sq(nu30 + nu12) - sq(nu21 + nu03)),
      (nu20 - nu02) * (sq(nu30 + nu12) - sq(nu21 + nu03))
          + 4 * nu11 * (nu30 + nu12) * (nu21 + nu03),
      (3 * nu21 - nu03) * (nu30 + nu12) * (sq(nu30 + nu12) - 3 * sq(nu21 + nu03))
          - (nu30 - 3 * nu12) * (nu21 + nu03) * (3 * sq(nu30 + nu12) - sq(nu21 + nu03)),
    ];
    final huLog = hu.map((v) => -v.sign * math.log(v.abs() + 1e-10)).toList();
    // Seules les 4 premières composantes de Hu sont stables sur de petits
    // chiffres gravés (limite connue des moments de Hu).
    final huLogUsed = huLog.sublist(0, 4);

    // Références calibrées sur vrais moules (séries 2 et 5 uniquement).
    const ref2 = [-0.91, -0.42, -1.62, -0.47, 0.0, 0.0, 0.0];
    const ref5 = [0.57, 1.99, 4.78, 5.38, 0.0, 0.0, 0.0];

    double huDist(List<double> a, List<double> b) {
      double s = 0;
      for (int i = 0; i < 4; i++) s += sq(a[i] - b[i]);
      return math.sqrt(s);
    }

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
      if (bestD > tol) {
        return const DigitDetectionResult(null, 0, null, null);
      }
      final c = (1.0 - bestD / tol).clamp(0.0, 1.0);
      return DigitDetectionResult(bestVal!, c, rect, huLogUsed);
    }

    // Sans template confirmé : proposition générique (l'utilisateur confirmera).
    // La 3e composante de Hu (hu2, index 2) est un discriminant quasi parfait
    // sur les échantillons réels (5 > 0, 2 < 0).
    String guess;
    double bestDist;
    if (huLogUsed[2] > 0) {
      guess = '5';
      bestDist = huDist(huLogUsed, ref5);
    } else if (huLogUsed[2] < 0) {
      guess = '2';
      bestDist = huDist(huLogUsed, ref2);
    } else {
      final d2 = huDist(huLogUsed, ref2);
      final d5 = huDist(huLogUsed, ref5);
      guess = d2 < d5 ? '2' : '5';
      bestDist = math.min(d2, d5);
    }
    final conf = (1.0 - bestDist / 10.0).clamp(0.0, 1.0);

    // Rejeter si pas assez confiant (évite les faux positifs sur le fond).
    if (conf < 0.75) return const DigitDetectionResult(null, 0, null, null);

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
