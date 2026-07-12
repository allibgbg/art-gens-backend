import 'dart:math';
import 'package:camera/camera.dart';

/// Représente une couleur dans l'espace CIELAB.
/// On ignore L volontairement — seuls (a,b) sont utilisés
/// pour l'invariance à l'illumination.
class LabColor {
  final double a, b;

  const LabColor(this.a, this.b);

  /// Distance euclidienne dans le plan (a,b)
  double distanceTo(LabColor other) {
    final da = a - other.a;
    final db = b - other.b;
    return sqrt(da * da + db * db);
  }

  /// Index de "bin" dans une grille 10×10 couvrant [-100..100]
  /// pour chaque axe. Retourne 0..99.
  int get binIndex {
    final ai = ((a.clamp(-100.0, 100.0) + 100) / 20).floor().clamp(0, 9);
    final bi = ((b.clamp(-100.0, 100.0) + 100) / 20).floor().clamp(0, 9);
    return ai * 10 + bi;
  }

  Map<String, dynamic> toJson() => {'a': a, 'b': b};

  factory LabColor.fromJson(Map<String, dynamic> json) =>
      LabColor((json['a'] as num).toDouble(), (json['b'] as num).toDouble());

  static LabColor fromRgb(int r, int g, int b) {
    double sr = r / 255.0, sg = g / 255.0, sb = b / 255.0;

    sr = (sr <= 0.04045) ? sr / 12.92 : pow((sr + 0.055) / 1.055, 2.4).toDouble();
    sg = (sg <= 0.04045) ? sg / 12.92 : pow((sg + 0.055) / 1.055, 2.4).toDouble();
    sb = (sb <= 0.04045) ? sb / 12.92 : pow((sb + 0.055) / 1.055, 2.4).toDouble();

    final xn = 0.95047, yn = 1.0, zn = 1.08883;
    double x = (sr * 0.4124564 + sg * 0.3575761 + sb * 0.1804375) / xn;
    double y = (sr * 0.2126729 + sg * 0.7151522 + sb * 0.0721750) / yn;
    double z = (sr * 0.0193339 + sg * 0.1191920 + sb * 0.9503041) / zn;

    x = (x > 0.008856) ? pow(x, 1 / 3).toDouble() : (7.787 * x + 16 / 116);
    y = (y > 0.008856) ? pow(y, 1 / 3).toDouble() : (7.787 * y + 16 / 116);
    z = (z > 0.008856) ? pow(z, 1 / 3).toDouble() : (7.787 * z + 16 / 116);

    final A = (500 * (x - y)).clamp(-128.0, 127.0);
    final B = (200 * (y - z)).clamp(-128.0, 127.0);

    return LabColor(A, B);
  }
}

/// Signature spatiale d'une seule frame.
/// Découpée en une grille [rows]×[cols] (défaut: 4×4).
/// Chaque zone contient les valeurs Lab moyennes des pixels de cette zone.
/// Utilisé uniquement comme filtre de pré-tri grossier.
class SpatialSignature {
  final int rows, cols;
  final List<List<List<LabColor>>> zones;
  final List<List<double>> lumSum;
  final List<List<int>> lumCount;

  SpatialSignature(this.rows, this.cols, this.zones, this.lumSum, this.lumCount);

  int get zoneCount => rows * cols;

  Map<String, dynamic> toJson() => {
        'rows': rows,
        'cols': cols,
        'zones': zones.map((row) =>
            row.map((zone) => zone.map((c) => c.toJson()).toList()).toList()).toList(),
      };

  factory SpatialSignature.fromJson(Map<String, dynamic> json) {
    final rows = json['rows'] as int;
    final cols = json['cols'] as int;
    final zones = (json['zones'] as List).map((row) =>
        (row as List).map((zone) =>
            (zone as List).map((c) => LabColor.fromJson(c as Map<String, dynamic>)).toList()
        ).toList()
    ).toList();
    final lumSum = List.generate(rows, (_) => List.filled(cols, 0.0));
    final lumCount = List.generate(rows, (_) => List.filled(cols, 0));
    return SpatialSignature(rows, cols, zones, lumSum, lumCount);
  }

  double meanL(int r, int c) =>
      lumCount[r][c] > 0 ? lumSum[r][c] / lumCount[r][c] : 0.0;

  LabColor meanColor(int r, int c) {
    final list = zones[r][c];
    if (list.isEmpty) return const LabColor(0, 0);
    double sa = 0, sb = 0;
    for (final l in list) {
      sa += l.a;
      sb += l.b;
    }
    return LabColor(sa / list.length, sb / list.length);
  }

  /// Distance moyenne (plan Lab incluant L) entre cette vue et une autre.
  /// Sert à détecter un changement de point de vue (rotation de l'œuf) :
  /// pour un objet uniforme les (a,b) ne bougent pas, seule la luminance L
  /// évolue avec la rotation, d'où l'inclusion de L.
  double fieldDistance(SpatialSignature other) {
    if (rows != other.rows || cols != other.cols) return 0.0;
    double total = 0;
    int n = 0;
    for (int r = 0; r < rows; r++) {
      for (int c = 0; c < cols; c++) {
        if (lumCount[r][c] == 0 || other.lumCount[r][c] == 0) continue;
        final dl = meanL(r, c) - other.meanL(r, c);
        final da = meanColor(r, c).a - other.meanColor(r, c).a;
        final db = meanColor(r, c).b - other.meanColor(r, c).b;
        total += sqrt(dl * dl + da * da + db * db);
        n++;
      }
    }
    return n == 0 ? 0.0 : total / n;
  }

  static const int _gridRows = 4;
  static const int _gridCols = 4;
  static const int _stepDivisor = 32;

  /// Extrait une signature spatiale depuis une image caméra YUV420.
  /// [cropFraction] (0.0-1.0) : proportion du centre de l'image conservée.
  static SpatialSignature extract(CameraImage image, {double cropFraction = 0.6}) {
    final int width = image.width;
    final int height = image.height;
    final int step = max(1, width ~/ _stepDivisor);

    final int marginX = ((width * (1 - cropFraction)) / 2).round();
    final int marginY = ((height * (1 - cropFraction)) / 2).round();
    final int cropXStart = marginX;
    final int cropXEnd = width - marginX;
    final int cropYStart = marginY;
    final int cropYEnd = height - marginY;
    final int cropW = cropXEnd - cropXStart;
    final int cropH = cropYEnd - cropYStart;

    final zones = List.generate(
      _gridRows,
      (_) => List.generate(_gridCols, (_) => <LabColor>[]),
    );
    final lumSum = List.generate(
      _gridRows,
      (_) => List.filled(_gridCols, 0.0),
    );
    final lumCount = List.generate(
      _gridRows,
      (_) => List.filled(_gridCols, 0),
    );

    if (image.format.group == ImageFormatGroup.yuv420 || image.format.group == ImageFormatGroup.nv21) {
      final yPlane = image.planes[0];
      final bool hasThreePlanes = image.planes.length >= 3;

      for (int y = cropYStart; y < cropYEnd; y += step) {
        for (int x = cropXStart; x < cropXEnd; x += step) {
          final yIndex = y * yPlane.bytesPerRow + x;
          final yy = yPlane.bytes[yIndex];
          int uu, vv;
          if (hasThreePlanes) {
            final uPlane = image.planes[1];
            final vPlane = image.planes[2];
            final uvX = x ~/ 2;
            final uvY = y ~/ 2;
            uu = uPlane.bytes[uvY * uPlane.bytesPerRow + uvX];
            vv = vPlane.bytes[uvY * vPlane.bytesPerRow + uvX];
          } else {
            final uPlane = image.planes[1];
            final uvIndex = (y ~/ 2) * uPlane.bytesPerRow + (x ~/ 2) * 2;
            vv = uPlane.bytes[uvIndex];
            uu = uPlane.bytes[uvIndex + 1];
          }

          final r = (yy + 1.402 * (vv - 128)).round().clamp(0, 255);
          final g = (yy - 0.344 * (uu - 128) - 0.714 * (vv - 128)).round().clamp(0, 255);
          final b = (yy + 1.772 * (uu - 128)).round().clamp(0, 255);

          final lab = LabColor.fromRgb(r, g, b);

          final L = yy;
          if (L < 10 || L > 252) continue;

          final relX = x - cropXStart;
          final relY = y - cropYStart;
          final halfW = cropW / 2, halfH = cropH / 2;
          final radius = halfW < halfH ? halfW : halfH;
          final dx = relX - halfW, dy = relY - halfH;
          if (dx * dx + dy * dy > radius * radius) continue;
          final col = (relX ~/ (cropW ~/ _gridCols)).clamp(0, _gridCols - 1);
          final row = (relY ~/ (cropH ~/ _gridRows)).clamp(0, _gridRows - 1);
          zones[row][col].add(lab);
          lumSum[row][col] += L;
          lumCount[row][col] += 1;
        }
      }
    }

    return SpatialSignature(_gridRows, _gridCols, zones, lumSum, lumCount);
  }
}

/// Suivi de couverture multi-frame.
/// La couverture avance uniquement lorsque la VUE change entre deux frames
/// (l'œuf a tourné) : on accumule un « crédit de rotation » égal à la distance
/// Lab (incluant la luminance L) entre la frame courante et la dernière vue
/// acceptée, moins un plancher de bruit. Ainsi, tenir l'objet immobile ne fait
/// pas progresser la couverture ; il faut réellement le faire pivoter pour
/// explorer sa surface. Un filet de sécurité (beaucoup de frames sans crédit)
/// évite un scan éternel si la détection échoue.
class CoverageTracker {
  static const int _binsPerAxis = 10;
  static const int _totalBins = _binsPerAxis * _binsPerAxis;

  final int rows, cols;
  final List<List<Set<int>>> _zoneBins;
  final Set<int> _globalBins = {};
  int _framesSinceCredit = 0;
  int _totalFrames = 0;
  final double _targetCredit;
  final double _noiseFloor;
  double _credit = 0.0;
  SpatialSignature? _lastSig;

  CoverageTracker(this.rows, this.cols,
      {double targetCredit = 300.0, double noiseFloor = 2.0})
      : _targetCredit = targetCredit,
        _noiseFloor = noiseFloor,
        _zoneBins = List.generate(
          rows, (_) => List.generate(cols, (_) => <int>{}));

  double addFrame(SpatialSignature sig) {
    _totalFrames++;
    int newBins = 0;

    for (int r = 0; r < min(rows, sig.zones.length); r++) {
      for (int c = 0; c < min(cols, sig.zones[r].length); c++) {
        for (final lab in sig.zones[r][c]) {
          final bin = lab.binIndex;
          if (_zoneBins[r][c].add(bin)) newBins++;
          _globalBins.add(bin);
        }
      }
    }

    if (_lastSig != null) {
      final d = sig.fieldDistance(_lastSig!);
      if (d > _noiseFloor) {
        _credit += (d - _noiseFloor);
        _framesSinceCredit = 0;
      } else {
        _framesSinceCredit++;
      }
    } else {
      _framesSinceCredit = 0;
    }
    _lastSig = sig;

    return coverage;
  }

  // Couverture = crédit de rotation accumulé / cible. Proportionnel à l'angle
  // total parcouru autour de l'objet (≈ surface explorée), pas au temps.
  double get coverage => (_credit / _targetCredit).clamp(0.0, 1.0);

  // Stable = aucun changement de vue depuis plusieurs frames (utilisateur a
  // cessé de tourner l'objet).
  bool get isStable => _framesSinceCredit >= 6;

  double get confidence {
    if (_totalFrames < 3) return 0;
    final cov = coverage;
    final cap = min(1.0, cov / 0.8);
    return cap;
  }

  Map<String, dynamic> toSignatureJson() {
    final centroids = List.generate(
      rows,
      (r) => List.generate(cols, (c) {
        final bins = _zoneBins[r][c].toList();
        if (bins.isEmpty) return <LabColor>[];
        return bins.map((bin) {
          final ai = bin ~/ _binsPerAxis;
          final bi = bin % _binsPerAxis;
          return LabColor(ai * 20.0 - 100.0 + 10.0, bi * 20.0 - 100.0 + 10.0);
        }).toList();
      }),
    );
    final lumSum = List.generate(rows, (_) => List.filled(cols, 0.0));
    final lumCount = List.generate(rows, (_) => List.filled(cols, 0));
    return SpatialSignature(rows, cols, centroids, lumSum, lumCount).toJson();
  }

  void reset() {
    _globalBins.clear();
    _framesSinceCredit = 0;
    _totalFrames = 0;
    _credit = 0.0;
    _lastSig = null;
    for (final row in _zoneBins) {
      for (final set in row) {
        set.clear();
      }
    }
  }
}
