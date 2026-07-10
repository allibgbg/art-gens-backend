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

  AdaptiveSharpnessGate({
    this.calibrationDurationMs = 20000,
    this.ratio = 0.7,
    this.absoluteMin = 1.8,
  });

  bool isSharp(double qs) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _startMs ??= now;

    if (qs > _maxSeen) _maxSeen = qs;

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

  TextureFrame? extract(CameraImage image, {bool logErrors = false}) {
    final qs = quickSharpness(image);
    if (!_sharpnessGate.isSharp(qs)) return null;

    final grayMat = yPlaneToGrayMat(image, logErrors: logErrors);
    if (grayMat == null) return null;

    cv.Mat? enhanced;
    try {
      enhanced = _clahe.apply(grayMat);
      grayMat.dispose();

      final (keypoints, descriptors) = _orb.detectAndCompute(enhanced, _mask);
      enhanced.dispose();
      return TextureFrame(qs, descriptors, keypoints.toList());
    } catch (e) {
      if (logErrors) {
        // ignore: avoid_print
        print('[TextureExtractor] Erreur: $e');
      }
      grayMat.dispose();
      enhanced?.dispose();
      return null;
    }
  }

  void dispose() {
    _orb.dispose();
    _mask.dispose();
    _clahe.dispose();
  }
}

enum FeatureExtractor { orb }
