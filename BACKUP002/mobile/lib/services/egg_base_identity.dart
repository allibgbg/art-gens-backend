import 'dart:io';
import 'dart:math';
import 'dart:convert';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'api_client.dart';

/// Nombre de points remarquables stockés par carte d'identité.
const int kIdentityPointCount = 120;

/// Seuil Lowe ratio test pour le matching SIFT.
const double kLoweRatio = 0.75;

/// Score minimum pour considérer un œuf comme authentique.
const double kAuthThreshold = 0.9;

/// Nombre minimum de bons matches requis.
const int kMinMatches = 60;

// ---------------------------------------------------------------------------
// Data models
// ---------------------------------------------------------------------------

/// Un point remarquable de la base d'un œuf.
class IdentityPoint {
  final double x, y;
  final double scale;
  final double angle;
  final List<double> descriptor; // 128 floats SIFT
  final double depthMean;
  final double depthStddev;
  final double depthContrast;

  const IdentityPoint({
    required this.x,
    required this.y,
    required this.scale,
    required this.angle,
    required this.descriptor,
    required this.depthMean,
    required this.depthStddev,
    required this.depthContrast,
  });

  Map<String, dynamic> toJson() => {
        'x': x,
        'y': y,
        'scale': scale,
        'angle': angle,
        'descriptor': descriptor,
        'depth_mean': depthMean,
        'depth_stddev': depthStddev,
        'depth_contrast': depthContrast,
      };

  factory IdentityPoint.fromJson(Map<String, dynamic> j) => IdentityPoint(
        x: (j['x'] as num).toDouble(),
        y: (j['y'] as num).toDouble(),
        scale: (j['scale'] as num).toDouble(),
        angle: (j['angle'] as num).toDouble(),
        descriptor:
            (j['descriptor'] as List).map((e) => (e as num).toDouble()).toList(),
        depthMean: (j['depth_mean'] as num).toDouble(),
        depthStddev: (j['depth_stddev'] as num).toDouble(),
        depthContrast: (j['depth_contrast'] as num).toDouble(),
      );
}

/// Carte d'identité complète d'un œuf (base plane avec griffures).
class EggBaseIdentity {
  final int version;
  final int imageW, imageH;
  final double quality;
  final List<IdentityPoint> points;
  final String? series;
  final String? digitNumber;
  final String? notes;
  final String? facePhotoPath;
  final int createdAt;

  const EggBaseIdentity({
    required this.version,
    required this.imageW,
    required this.imageH,
    required this.quality,
    required this.points,
    this.series,
    this.digitNumber,
    this.notes,
    this.facePhotoPath,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'image_w': imageW,
        'image_h': imageH,
        'quality': quality,
        'points': points.map((p) => p.toJson()).toList(),
        'series': series,
        'digit_number': digitNumber,
        'notes': notes,
        'face_photo_path': facePhotoPath,
        'created_at': createdAt,
      };

  factory EggBaseIdentity.fromJson(Map<String, dynamic> j) => EggBaseIdentity(
        version: (j['version'] as num?)?.toInt() ?? 1,
        imageW: (j['image_w'] as num).toInt(),
        imageH: (j['image_h'] as num).toInt(),
        quality: (j['quality'] as num?)?.toDouble() ?? 0.0,
        points: (j['points'] as List)
            .map((e) => IdentityPoint.fromJson(e as Map<String, dynamic>))
            .toList(),
        series: j['series'] as String?,
        digitNumber: j['digit_number'] as String?,
        notes: j['notes'] as String?,
        facePhotoPath: j['face_photo_path'] as String?,
        createdAt: (j['created_at'] as num).toInt(),
      );

  // -- Persistence -----------------------------------------------------------

  static Future<String> get _dir async {
    final d = await getApplicationDocumentsDirectory();
    return d.path;
  }

  static Future<String> get _filePath async =>
      '${await _dir}/egg_base_identity.json';

  static Future<EggBaseIdentity?> load() async {
    try {
      final f = File(await _filePath);
      if (!await f.exists()) return null;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      return EggBaseIdentity.fromJson(j);
    } catch (_) {
      return null;
    }
  }

  static Future<void> save(EggBaseIdentity id) async {
    final f = File(await _filePath);
    await f.writeAsString(jsonEncode(id.toJson()));
  }

  static Future<bool> exists() async => File(await _filePath).exists();

  static Future<void> delete() async {
    final f = File(await _filePath);
    if (await f.exists()) await f.delete();
  }

  // -- Server sync -----------------------------------------------------------

  /// Upload l'identité au serveur backend.
  static Future<String?> uploadToServer(ApiClient api, EggBaseIdentity identity) async {
    try {
      // Lire la photo de face en base64
      String? faceBase64;
      if (identity.facePhotoPath != null) {
        final f = File(identity.facePhotoPath!);
        if (await f.exists()) {
          final bytes = await f.readAsBytes();
          faceBase64 = base64Encode(bytes);
        }
      }

      final result = await api.post('/egg-identity/', body: {
        'display_number': '${identity.series ?? "?"}-${identity.digitNumber ?? "0"}',
        'series_value': int.tryParse(identity.series ?? '0') ?? 0,
        'digit_number': identity.digitNumber,
        'notes': identity.notes,
        'face_photo': faceBase64,
        'identity_data': identity.toJson(),
      });
      return result['id'] as String?;
    } catch (_) {
      return null;
    }
  }

  /// Récupère toutes les identités du serveur.
  static Future<List<Map<String, dynamic>>> downloadFromServer(ApiClient api) async {
    try {
      final list = await api.getList('/egg-identity/');
      return list.cast<Map<String, dynamic>>();
    } catch (_) {
      return [];
    }
  }
}

// ---------------------------------------------------------------------------
// Feature extraction
// ---------------------------------------------------------------------------

/// Résultat SIFT brut pour une image.
class _SiftResult {
  final List<cv.KeyPoint> keyPoints;
  final cv.Mat descriptors;
  final cv.Mat gray;
  final int w, h;

  _SiftResult(this.keyPoints, this.descriptors, this.gray, this.w, this.h);

  void dispose() {
    descriptors.dispose();
    gray.dispose();
  }
}

/// Extrait SIFT d'une image grayscale (Mat CV_8UC1).
_SiftResult? _extractSift(cv.Mat gray, {int maxFeatures = 3000}) {
  if (gray.cols <= 0 || gray.rows <= 0) return null;
  final sift = cv.SIFT.create(nfeatures: maxFeatures);
  final (kps, desc) = sift.detectAndCompute(gray, cv.Mat.empty());
  sift.dispose();
  if (desc.rows == 0) {
    desc.dispose();
    gray.dispose();
    return null;
  }
  final kpList = List<cv.KeyPoint>.from(kps);
  return _SiftResult(kpList, desc, gray, gray.cols, gray.rows);
}

/// Charge une image JPEG depuis un chemin et retourne un Mat grayscale.
cv.Mat? _loadGray(String path) {
  try {
    final bytes = File(path).readAsBytesSync();
    return cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
  } catch (_) {
    return null;
  }
}

// ---------------------------------------------------------------------------
// Depth features (profondeur des griffures via intensité locale)
// ---------------------------------------------------------------------------

/// Calcule les features de profondeur (mean, stddev, contraste) dans un
/// patch 16x16 autour d'un keypoint.
Map<String, double> _computeDepth(cv.Mat gray, cv.KeyPoint kp) {
  const patchSize = 16;
  final cx = kp.x.toInt();
  final cy = kp.y.toInt();
  final half = patchSize ~/ 2;

  final x0 = (cx - half).clamp(0, gray.cols - 1);
  final y0 = (cy - half).clamp(0, gray.rows - 1);
  final x1 = (cx + half).clamp(0, gray.cols - 1);
  final y1 = (cy + half).clamp(0, gray.rows - 1);

  if (x1 <= x0 || y1 <= y0) {
    return {'mean': 0, 'stddev': 0, 'contrast': 0};
  }

  // Extraire le patch via ROI
  final roi = cv.Rect(x0, y0, x1 - x0, y1 - y0);
  final patch = gray.region(roi);

  final (mean, stddev) = cv.meanStdDev(patch);
  final meanVal = mean.val[0];
  final stdVal = stddev.val[0];

  patch.dispose();

  // Contraste = stddev / mean (texture des griffures)
  final contrast = meanVal > 0 ? stdVal / meanVal : 0.0;

  return {
    'mean': meanVal,
    'stddev': stdVal,
    'contrast': contrast,
  };
}

// ---------------------------------------------------------------------------
// Public: extraction depuis une image (pour enrollment et live)
// ---------------------------------------------------------------------------

/// Points SIFT extraits d'une image avec leurs depth features.
class ExtractedFeatures {
  final List<cv.KeyPoint> keyPoints;
  final cv.Mat descriptors;
  final List<Map<String, double>> depths;
  final int w, h;

  ExtractedFeatures(this.keyPoints, this.descriptors, this.depths, this.w, this.h);

  int get count => keyPoints.length;

  void dispose() {
    descriptors.dispose();
  }
}

/// Extrait les features SIFT + depth d'une image (chemin JPEG).
ExtractedFeatures? extractFromImage(String imagePath, {int maxFeatures = 3000}) {
  final gray = _loadGray(imagePath);
  if (gray == null) return null;
  final result = _extractSift(gray, maxFeatures: maxFeatures);
  if (result == null) return null;

  final depths = <Map<String, double>>[];
  for (final kp in result.keyPoints) {
    depths.add(_computeDepth(result.gray, kp));
  }

  return ExtractedFeatures(
    result.keyPoints,
    result.descriptors,
    depths,
    result.w,
    result.h,
  );
}

/// Extrait les features SIFT + depth depuis un Mat grayscale (live camera).
ExtractedFeatures? extractFromMat(cv.Mat gray, {int maxFeatures = 3000}) {
  if (gray.cols <= 0 || gray.rows <= 0) return null;
  final result = _extractSift(gray, maxFeatures: maxFeatures);
  if (result == null) return null;

  final depths = <Map<String, double>>[];
  for (final kp in result.keyPoints) {
    depths.add(_computeDepth(result.gray, kp));
  }

  return ExtractedFeatures(
    result.keyPoints,
    result.descriptors,
    depths,
    result.w,
    result.h,
  );
}

// ---------------------------------------------------------------------------
// Public: sélection des 12 points remarquables (enrollment)
// ---------------------------------------------------------------------------

/// Sélectionne les kIdentityPointCount points les plus distinctifs
/// à partir de features extraites de plusieurs images.
///
/// Critères de ranking :
/// 1. Réponse SIFT (qualité du keypoint)
/// 2. Diversité spatiale (grille 4x3)
/// 3. Stabilité inter-frames (détecté dans plusieurs images)
List<IdentityPoint> selectIdentityPoints(
  List<ExtractedFeatures> allFeatures, {
  int count = kIdentityPointCount,
}) {
  if (allFeatures.isEmpty) return [];

  // Collecter tous les keypoints avec leur source
  final all = <_CandidatePoint>[];
  for (int fi = 0; fi < allFeatures.length; fi++) {
    final f = allFeatures[fi];
    for (int ki = 0; ki < f.count; ki++) {
      all.add(_CandidatePoint(
        kp: f.keyPoints[ki],
        desc: f.descriptors,
        descIdx: ki,
        depth: f.depths[ki],
        sourceFrame: fi,
        imgW: f.w,
        imgH: f.h,
      ));
    }
  }

  if (all.isEmpty) return [];

  // Matching inter-frames pour mesurer la stabilité
  _computeStability(all, allFeatures);

  // Filtrer : ne garder que les points présents sur TOUTES les photos
  final numFrames = allFeatures.length;
  final stable = all.where((c) => c.stabilityCount >= numFrames).toList();

  // Grille 10x10 pour diversité spatiale
  const gridCols = 10;
  const gridRows = 10;
  final gridCounts = List.filled(gridCols * gridRows, 0);

  for (final c in stable) {
    final gx = ((c.kp.x / c.imgW) * gridCols).toInt().clamp(0, gridCols - 1);
    final gy = ((c.kp.y / c.imgH) * gridRows).toInt().clamp(0, gridRows - 1);
    c._gridCell = gy * gridCols + gx;
  }

  // Trier par score décroissant (stability × taille)
  stable.sort((a, b) => b.score.compareTo(a.score));

  // Sélection avec diversité spatiale
  final selected = <IdentityPoint>[];
  for (final c in stable) {
    if (selected.length >= count) break;
    // Vérifier qu'on n'a pas déjà 2 points dans la même cellule
    if (gridCounts[c._gridCell] >= 2) continue;
    gridCounts[c._gridCell]++;

    selected.add(IdentityPoint(
      x: c.kp.x,
      y: c.kp.y,
      scale: c.kp.size,
      angle: c.kp.angle,
      descriptor: _extractDescriptorRow(c.desc, c.descIdx),
      depthMean: c.depth['mean']!,
      depthStddev: c.depth['stddev']!,
      depthContrast: c.depth['contrast']!,
    ));
  }

  return selected;
}

class _CandidatePoint {
  final cv.KeyPoint kp;
  final cv.Mat desc;
  final int descIdx;
  final Map<String, double> depth;
  final int sourceFrame;
  final int imgW, imgH;
  int _gridCell = 0;
  int stabilityCount = 1; // détecté dans au moins 1 frame
  double score = 0;

  _CandidatePoint({
    required this.kp,
    required this.desc,
    required this.descIdx,
    required this.depth,
    required this.sourceFrame,
    required this.imgW,
    required this.imgH,
  });
}

void _computeStability(
  List<_CandidatePoint> all,
  List<ExtractedFeatures> features,
) {
  final numFrames = features.length;

  if (numFrames < 2) {
    for (final c in all) {
      c.score = c.kp.size * 10.0;
    }
    return;
  }

  // Pour chaque paire de frames, matcher les descriptors
  final matcher = cv.BFMatcher.create(type: cv.NORM_L2, crossCheck: false);

  for (int fi = 0; fi < numFrames; fi++) {
    for (int fj = fi + 1; fj < numFrames; fj++) {
      try {
        final knn = matcher.knnMatch(
          features[fi].descriptors,
          features[fj].descriptors,
          2,
        );
        for (int k = 0; k < knn.length; k++) {
          final m = knn[k];
          if (m.length < 2) continue;
          final first = m[0];
          final second = m[1];
          if (first.distance < kLoweRatio * second.distance) {
            for (final c in all) {
              if (c.sourceFrame == fi && c.descIdx == first.queryIdx) {
                c.stabilityCount++;
              }
              if (c.sourceFrame == fj && c.descIdx == first.trainIdx) {
                c.stabilityCount++;
              }
            }
          }
        }
      } catch (_) {}
    }
  }

  matcher.dispose();

  // Score : stability (doit être présent sur TOUTES les frames) × taille
  for (final c in all) {
    c.score = c.stabilityCount.toDouble() * c.kp.size;
  }
}

List<double> _extractDescriptorRow(cv.Mat desc, int row) {
  final data = desc.toList();
  return List<double>.from(data[row]);
}

// ---------------------------------------------------------------------------
// Public: matching (vérification live)
// ---------------------------------------------------------------------------

/// Résultat du matching d'une frame contre la carte d'identité.
class MatchResult {
  final double score; // 0..1
  final int matchCount;
  final int totalIdentityPoints;

  const MatchResult({
    required this.score,
    required this.matchCount,
    required this.totalIdentityPoints,
  });

  bool get isAuthentic =>
      score >= kAuthThreshold && matchCount >= kMinMatches;
}

/// Compare les features SIFT d'une image (ou frame live) contre la carte
/// d'identité. Score = nombre de points identité trouvés dans la frame / total.
MatchResult matchAgainstIdentity(
  ExtractedFeatures frame,
  EggBaseIdentity identity,
) {
  if (identity.points.isEmpty || frame.count == 0) {
    return const MatchResult(
      score: 0,
      matchCount: 0,
      totalIdentityPoints: 0,
    );
  }

  // Construire un Mat à partir des descripteurs de la carte d'identité
  final idDescData = <double>[];
  for (final p in identity.points) {
    idDescData.addAll(p.descriptor);
  }
  final idDesc = cv.Mat.fromList(
    identity.points.length,
    128,
    cv.MatType.CV_32FC1,
    idDescData,
  );

  final matcher = cv.BFMatcher.create(type: cv.NORM_L2, crossCheck: false);

  int goodMatches = 0;
  try {
    // Direction inverse : pour chaque point identité, chercher dans la frame
    // "combien de mes 120 points sont présents dans cette frame?"
    final knn = matcher.knnMatch(idDesc, frame.descriptors, 2);

    for (int k = 0; k < knn.length; k++) {
      final m = knn[k];
      if (m.length < 2) continue;
      final first = m[0];
      final second = m[1];
      if (first.distance < kLoweRatio * second.distance) {
        goodMatches++;
      }
    }
  } catch (_) {}

  matcher.dispose();
  idDesc.dispose();

  final score = goodMatches / identity.points.length;
  return MatchResult(
    score: score.clamp(0.0, 1.0),
    matchCount: goodMatches,
    totalIdentityPoints: identity.points.length,
  );
}
