import 'dart:math' as math;
import 'dart:typed_data';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;

/// Mesure rapide de netteté directement sur les bytes Y bruts, sans OpenCV.
double quickSharpness(CameraImage image) {
  try {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    final stride = plane.bytesPerRow;
    const step = 4;

    int sum = 0;
    int count = 0;

    for (int r = 0; r < h; r += step) {
      final rowStart = r * stride;
      for (int c = 0; c < w - 1; c += step) {
        final diff = (bytes[rowStart + c] - bytes[rowStart + c + 1]).abs();
        sum += diff;
        count++;
      }
    }

    if (count == 0) return 0.0;
    return sum / count;
  } catch (_) {
    return 0.0;
  }
}

/// Mesure rapide de netteté sur une Mat grayscale (Laplacien variance).
double quickSharpnessMat(cv.Mat gray) {
  try {
    final lap = cv.laplacian(gray, 6); // CV_64F = 6
    final (_, stddev) = cv.meanStdDev(lap);
    final variance = stddev.val[0] * stddev.val[0];
    lap.dispose();
    return variance;
  } catch (_) {
    return 0.0;
  }
}

/// Filtre de netteté adaptatif :
/// 1. Période d'observation minimum (20s) avant d'accepter la 1re frame
/// 2. Seuil minimum absolu bas (1.0) — le maxSeen monte à 7+ en lumière vive
/// Le max continue d'être mis à jour même après calibration.
class AdaptiveSharpnessGate {
  double _maxSeen = 0.0;
  int? _startMs;
  final int calibrationDurationMs;
  final double ratio;
  final double absoluteMin;
  final double decay;

  AdaptiveSharpnessGate({
    this.calibrationDurationMs = 20000,
    this.ratio = 0.7,
    this.absoluteMin = 1.8,
    this.decay = 0.99,
  });

  bool isSharp(double qs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _startMs ??= now;

    if (qs > _maxSeen) {
      _maxSeen = qs;
    } else {
      // Décroissance lente du max mémorisé : sans cela, le seuil relatif
      // (_maxSeen * ratio) reste bloqué sur la frame la plus nette vue au
      // début du scan, et finit par rejeter toutes les frames suivantes
      // (objet qui tourne, éclairage changeant) -> scan bloqué.
      _maxSeen *= decay;
    }

    final elapsed = now - _startMs!;
    if (elapsed < calibrationDurationMs) return qs >= absoluteMin;

    return qs >= _maxSeen * ratio && qs >= absoluteMin;
  }

  double get maxSeen => _maxSeen;
  int get calibrationProgress {
    if (_startMs == null) return 0;
    final elapsed = DateTime.now().millisecondsSinceEpoch - _startMs!;
    return (elapsed * 100 ~/ calibrationDurationMs).clamp(0, 100);
  }

  bool get isCalibrated {
    if (_startMs == null) return false;
    return DateTime.now().millisecondsSinceEpoch - _startMs! >= calibrationDurationMs;
  }

  void reset() {
    _maxSeen = 0.0;
    _startMs = null;
  }
}

/// Convertit le plan Y (luma) d'une image caméra en Mat CV_8UC1,
/// en gérant correctement le stride (bytesPerRow) si différent de width.
cv.Mat? yPlaneToGrayMat(CameraImage image, {bool logErrors = false}) {
  try {
    final plane = image.planes[0];
    final h = image.height;
    final w = image.width;
    final stride = plane.bytesPerRow;

    if (stride == w) {
      return cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, plane.bytes);
    }

    final packed = Uint8List(h * w);
    for (int row = 0; row < h; row++) {
      final srcStart = row * stride;
      final dstStart = row * w;
      for (int col = 0; col < w; col++) {
        packed[dstStart + col] = plane.bytes[srcStart + col];
      }
    }
    return cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, packed);
  } catch (e) {
    if (logErrors) {
      // ignore: avoid_print
      print('[yPlaneToGrayMat] Erreur: $e');
    }
    return null;
  }
}

class TextureFrame {
  final double sharpness;
  final cv.Mat descriptors;
  final List<cv.KeyPoint> keypoints;

  TextureFrame(this.sharpness, this.descriptors, this.keypoints);

  void dispose() {
    descriptors.dispose();
  }
}

/// Région circulaire dans l'image caméra (coordonnées pixels image brute).
class CameraCircleRegion {
  final double cx;      // centre X en pixels image
  final double cy;      // centre Y en pixels image
  final double radius;  // rayon en pixels image

  const CameraCircleRegion({required this.cx, required this.cy, required this.radius});
}

/// Calcule la région circulaire dans l'image caméra qui correspond
/// à un cercle FIXE de 400px de diamètre (200px rayon) au centre de l'écran.
/// Ignore circleFraction, BoxFit.cover, sensorOrientation.
CameraCircleRegion? computeFixedCenterCircleRegion({
  required double imgW,
  required double imgH,
  required int sensorOrientation,
  required double screenWidth,
  required double screenHeight,
}) {

  // Cercle écran : centre exact, diamètre 400px (rayon 200px)
  const double screenCircleRadius = 200.0;
  final double screenCx = screenWidth / 2;
  final double screenCy = screenHeight / 2;

  // CameraPreview avec BoxFit.cover : l'image remplit l'écran, rognée symétriquement.
  // Calculer l'échelle cover et l'offset.
  final double scaleX = screenWidth / imgW;
  final double scaleY = screenHeight / imgH;
  final double coverScale = scaleX > scaleY ? scaleX : scaleY;

  final double scaledW = imgW * coverScale;
  final double scaledH = imgH * coverScale;
  final double offsetX = (scaledW - screenWidth) / 2;
  final double offsetY = (scaledH - screenHeight) / 2;

  // Centre du cercle écran -> coordonnées image redimensionnée (scaled)
  final double scaledCx = screenCx + offsetX;
  final double scaledCy = screenCy + offsetY;

  // Redimensionnée -> image brute (avant rotation capteur)
  final double rawCx = scaledCx / coverScale;
  final double rawCy = scaledCy / coverScale;
  final double rawRadius = screenCircleRadius / coverScale;

  // Appliquer la rotation du capteur (sensorOrientation degrés CW pour aller au portrait)
  // L'image brute est tournée de -sensorOrientation par rapport à l'affichage portrait.
  // Pour mapper centre écran -> image brute, on inverse la rotation.
  double finalCx, finalCy;
  final int steps = (sensorOrientation ~/ 90) % 4;
  if (steps == 0) {
    finalCx = rawCx;
    finalCy = rawCy;
  } else if (steps == 1) { // 90° CW
    finalCx = rawCy;
    finalCy = imgH - rawCx;
  } else if (steps == 2) { // 180°
    finalCx = imgW - rawCx;
    finalCy = imgH - rawCy;
  } else { // 270°
    finalCx = imgW - rawCy;
    finalCy = rawCx;
  }

  // Clamp dans l'image
  final double clampedCx = finalCx.clamp(0.0, imgW - 1.0);
  final double clampedCy = finalCy.clamp(0.0, imgH - 1.0);
  final double maxRadius = (imgW < imgH ? imgW : imgH) / 2.0;
  final double clampedRadius = rawRadius.clamp(1.0, maxRadius);

  return CameraCircleRegion(cx: clampedCx, cy: clampedCy, radius: clampedRadius);
}

/// Région carrée (englobant le cercle) à recadrer dans une photo DÉJÀ
/// orientée (ex: sortie de takePicture), centrée, de côté = diamètre du
/// cercle fixe de 400px projeté dans l'image. Pas de rotation capteur ici
/// car la photo est déjà à l'endroit.
CameraCircleRegion centerCropRegion({
  required double imgW,
  required double imgH,
  required double screenWidth,
  required double screenHeight,
  double circleRadiusDp = 200.0,
}) {
  final scaleX = screenWidth / imgW;
  final scaleY = screenHeight / imgH;
  final coverScale = scaleX > scaleY ? scaleX : scaleY;
  final radiusImg = circleRadiusDp / coverScale;
  final maxSide = (imgW < imgH ? imgW : imgH);
  final sideImg = (radiusImg * 2).clamp(1.0, maxSide);
  return CameraCircleRegion(
    cx: imgW / 2,
    cy: imgH / 2,
    radius: sideImg / 2,
  );
}

/// Retourne la netteté (moyenne du gradient horizontal absolu) dans le cercle FIXE
/// de 400px de diamètre au centre de l'écran. Contrairement à l'ancienne version
/// qui comptait les pixels à fort gradient (et plafonnait ~25-30% sur un socle lisse
/// même net), ceci est une mesure de focus réelle : flou => gradient faible, net => fort.
double sharpnessRatioInFixedCircle(CameraImage image, {
  required double screenWidth,
  required double screenHeight,
  required int sensorOrientation,
}) {
  final region = computeFixedCenterCircleRegion(
    imgW: image.width.toDouble(),
    imgH: image.height.toDouble(),
    sensorOrientation: sensorOrientation,
    screenWidth: screenWidth,
    screenHeight: screenHeight,
  );
  if (region == null) return 0.0;

  try {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    final stride = plane.bytesPerRow;

    final cx = region.cx;
    final cy = region.cy;
    final radius = region.radius;
    final radiusSq = radius * radius;

    int total = 0;
    int sum = 0;
    const step = 2;

    final yStart = (cy - radius).ceil().clamp(0, h - 1);
    final yEnd = (cy + radius).floor().clamp(0, h - 1);

    for (int y = yStart; y <= yEnd; y += step) {
      final dy = y - cy;
      final dySq = dy * dy;
      final rowStart = y * stride;

      final dxMax = (radiusSq - dySq);
      if (dxMax <= 0) continue;
      final dxLimit = math.sqrt(dxMax);
      final xStart = (cx - dxLimit).ceil().clamp(0, w - 1);
      final xEnd = (cx + dxLimit).floor().clamp(0, w - 1);

      for (int x = xStart; x <= xEnd; x += step) {
        total++;
        final idx = rowStart + x;
        if (idx + 1 < bytes.length) {
          sum += (bytes[idx] - bytes[idx + 1]).abs();
        }
      }
    }
    return total == 0 ? 0.0 : sum / total;
  } catch (_) {
    return 0.0;
  }
}

/// Calcule le ratio de netteté dans une zone circulaire centrale (legacy, inchangé).
double sharpnessRatioInCircle(CameraImage image, {
  required double circleFraction,
  required double threshold,
}) {
  try {
    final plane = image.planes[0];
    final bytes = plane.bytes;
    final w = image.width;
    final h = image.height;
    final stride = plane.bytesPerRow;

    final cx = w / 2;
    final cy = h / 2;
    final radius = (w < h ? w : h) / 2 * circleFraction;
    final radiusSq = radius * radius;

    int total = 0;
    int sharp = 0;
    const step = 2;

    for (int y = 0; y < h; y += step) {
      final dy = y - cy;
      final dySq = dy * dy;
      final rowStart = y * stride;
      for (int x = 0; x < w; x += step) {
        final dx = x - cx;
        if (dx * dx + dySq > radiusSq) continue;
        total++;
        final idx = rowStart + x;
        if (idx + 1 < bytes.length) {
          final diff = (bytes[idx] - bytes[idx + 1]).abs();
          if (diff > threshold) sharp++;
        }
      }
    }
    return total == 0 ? 0.0 : sharp / total;
  } catch (_) {
    return 0.0;
  }
}

enum FeatureExtractor { orb }

/// Extracteur de features avec ORB réutilisable.
/// La netteté est vérifiée en continu via [AdaptiveSharpnessGate].
class TextureExtractor {
  final cv.ORB _orb;
  final cv.Mat _mask = cv.Mat.empty();
  final cv.CLAHE _clahe;
  final AdaptiveSharpnessGate _sharpnessGate;

  TextureExtractor({int nFeatures = 500})
      : _orb = cv.ORB.create(
          nFeatures: nFeatures,
          scaleFactor: 1.2,
          nLevels: 8,
          edgeThreshold: 31,
          firstLevel: 0,
          WTA_K: 2,
          scoreType: cv.ORBScoreType.FAST_SCORE,
          patchSize: 31,
          fastThreshold: 20,
        ),
        _clahe = cv.CLAHE.create(2.0, (8, 8)),
        _sharpnessGate = AdaptiveSharpnessGate();

  AdaptiveSharpnessGate get sharpnessGate => _sharpnessGate;

  /// Extrait les features dans la région circulaire [region] (pixels image brute).
  /// Si [region] est null, traite l'image entière (fallback).
  TextureFrame? extract(CameraImage image, {
    bool logErrors = false,
    CameraCircleRegion? region,
  }) {
    final qs = quickSharpness(image);
    if (!_sharpnessGate.isSharp(qs)) return null;

    final grayMat = yPlaneToGrayMat(image, logErrors: logErrors);
    if (grayMat == null) return null;

    cv.Mat? enhanced;
    cv.Mat? mask;
    try {
      enhanced = _clahe.apply(grayMat);
      grayMat.dispose();

// Créer un masque circulaire si région fournie
      if (region != null) {
        mask = cv.Mat.zeros(enhanced.rows, enhanced.cols, cv.MatType.CV_8UC1);
        cv.circle(
          mask,
          cv.Point(region.cx.round(), region.cy.round()),
          region.radius.round(),
          cv.Scalar.all(255),
          thickness: cv.FILLED,
        );
      }

      final (keypoints, descriptors) = _orb.detectAndCompute(enhanced, mask ?? _mask);
      mask?.dispose();
      enhanced.dispose();
      return TextureFrame(qs, descriptors, keypoints.toList());
    } catch (e) {
      if (logErrors) {
        // ignore: avoid_print
        print('[TextureExtractor] Erreur: $e');
      }
      grayMat.dispose();
      enhanced?.dispose();
      mask?.dispose();
      return null;
    }
  }

  void dispose() {
    _orb.dispose();
    _mask.dispose();
    _clahe.dispose();
  }
}