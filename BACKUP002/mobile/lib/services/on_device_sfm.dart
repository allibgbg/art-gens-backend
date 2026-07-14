/// Reconstruction 3D photogrammétrique ON-DEVICE (opencv_dart).
///
/// Pipeline "turntable" simplifié pour un œuf tourné à la main devant le
/// téléphone :
///   1. SIFT detect+compute sur chaque vue (croppée, pleine def).
///   2. Appariement BFMatcher + ratio test entre vues consécutives.
///   3. recoverPose (E + RANSAC) -> pose relative R,t de chaque paire.
///   4. Chaînage des poses caméras (cumul).
///   5. triangulatePoints par paire -> nuage 3D (métrique relative).
///   6. Export PLY ascii (objet à comparer via /scan3d/compare).
///
/// 100 % sur le téléphone (CPU/RAM largement suffisants sur un Samsung M54 5G).
/// Aucune dépendance COLMAP ni serveur pour la reconstruction : le backend ne
/// fait que comparer des nuages de points (services/mesh_compare.py, numpy).
library;

import 'dart:io';
import 'package:opencv_dart/opencv_dart.dart' as cv;

class _View {
  final cv.Mat gray;
  final cv.Mat desc;
  final List<cv.KeyPoint> kps;
  _View(this.gray, this.desc, this.kps);
}

/// Reconstruit un nuage de points depuis une liste de fichiers images et
/// l'écrit dans [outPlyPath] (ascii PLY). Renvoie quelques stats.
Map<String, dynamic> reconstructToPly(
  List<String> imagePaths, {
  required String outPlyPath,
  int maxFeatures = 3000,
  double ratioThresh = 0.75,
  double focalFactor = 1.2,
}) {
  if (imagePaths.length < 3) {
    throw ArgumentError("Au moins 3 vues requises (reçu ${imagePaths.length}).");
  }

  final views = <_View>[];
  try {
    final sift = cv.SIFT.create(nfeatures: maxFeatures);
    for (final p in imagePaths) {
      final b = File(p).readAsBytesSync();
      final img = cv.imdecode(b, cv.IMREAD_GRAYSCALE);
      if (img.cols <= 0 || img.rows <= 0) {
        img.dispose();
        continue;
      }
      final (kps, desc) = sift.detectAndCompute(img, cv.Mat.empty());
      views.add(_View(img, desc, List<cv.KeyPoint>.from(kps)));
    }
    sift.dispose();
    if (views.length < 3) {
      throw StateError("Vues exploitables insuffisantes (lues ${views.length}).");
    }

    final h = views.first.gray.rows;
    final w = views.first.gray.cols;
    final focal = (w > h ? w : h) * focalFactor;
    final cx = w / 2.0;
    final cy = h / 2.0;
    final K = <List<double>>[
      [focal, 0, cx],
      [0, focal, cy],
      [0, 0, 1],
    ];

    // Poses caméras cumulées (R 3x3, t 3x1), cam0 = [I|0]
    var rCur = _eye3();
    var tCur = <double>[0, 0, 0];
    final poses = <List<List<double>>>[]; // 3x4 chacun
    poses.add(_rtTo34(rCur, tCur));

    final allPts = <List<double>>[]; // [x,y,z]
    final matcher = cv.BFMatcher.create(type: cv.NORM_L2, crossCheck: false);
    int nPairsAttempted = 0;
    int nPairsOk = 0;
    String lastError = '';

    for (int i = 1; i < views.length; i++) {
      final a = views[i - 1];
      final b = views[i];

      try {
        nPairsAttempted++;
        // knnMatch k=2 pour ratio test
        final knn = matcher.knnMatch(b.desc, a.desc, 2);
        final g1 = <double>[];
        final g2 = <double>[];
        for (int k = 0; k < knn.length; k++) {
          final m = knn[k];
          if (m.length < 2) continue;
          final first = m[0];
          final second = m[1];
          if (first.distance < ratioThresh * second.distance) {
            final pB = b.kps[first.queryIdx];
            final pA = a.kps[first.trainIdx];
            g1.add(pA.x);
            g1.add(pA.y);
            g2.add(pB.x);
            g2.add(pB.y);
          }
        }
        if (g1.length < 16) {
          lastError = "pas assez de match (${g1.length ~/ 2} < 8)";
          continue;
        }

        final nPts = g1.length ~/ 2;
        // Points Nx1 CV_32FC2 pour findEssentialMat/recoverPose (Point2f)
        final pts1f =
            cv.Mat.fromList(nPts, 1, cv.MatType.CV_32FC2, g1);
        final pts2f =
            cv.Mat.fromList(nPts, 1, cv.MatType.CV_32FC2, g2);

        // Pose relative entre vues consécutives
        final E = cv.findEssentialMat(pts1f, pts2f,
            focal: focal,
            pp: cv.Point2d(cx, cy),
            method: cv.RANSAC,
            prob: 0.999,
            threshold: 1.0,
            maxIters: 1000);

        // Vérifier que E n'est pas vide
        if (E.rows < 3 || E.cols < 3) {
          lastError = "findEssentialMat: E vide (${E.rows}x${E.cols})";
          E.dispose();
          pts1f.dispose();
          pts2f.dispose();
          continue;
        }

        final rec = cv.recoverPose(E, pts1f, pts2f,
            focal: focal, pp: cv.Point2d(cx, cy));
        final rMat = rec.$2; // R 3x3
        final tMat = rec.$3; // t 3x1

        // Vérifier dimensions R et t
        if (rMat.rows < 3 || rMat.cols < 3) {
          lastError = "recoverPose: R vide (${rMat.rows}x${rMat.cols})";
          rMat.dispose();
          tMat.dispose();
          E.dispose();
          pts1f.dispose();
          pts2f.dispose();
          continue;
        }
        if (tMat.rows < 3 || tMat.cols < 1) {
          lastError = "recoverPose: t vide (${tMat.rows}x${tMat.cols})";
          rMat.dispose();
          tMat.dispose();
          E.dispose();
          pts1f.dispose();
          pts2f.dispose();
          continue;
        }

        final rRel = _matToList3x3(rMat);
        final trel = _vec3(tMat);

        // Composition caméra : R_j = rRel @ R_{j-1} ; t_j = rRel @ t_{j-1} + trel
        rCur = _matMul3x3(rRel, rCur);
        final rtRel = [
          rRel[0][0] * tCur[0] +
              rRel[0][1] * tCur[1] +
              rRel[0][2] * tCur[2] +
              trel[0],
          rRel[1][0] * tCur[0] +
              rRel[1][1] * tCur[1] +
              rRel[1][2] * tCur[2] +
              trel[1],
          rRel[2][0] * tCur[0] +
              rRel[2][1] * tCur[1] +
              rRel[2][2] * tCur[2] +
              trel[2],
        ];
        tCur = rtRel;
        poses.add(_rtTo34(rCur, tCur));

        // Triangulation entre pose i-1 et pose i
        final p0 = _proj44(K, poses[i - 1]);
        final p1 = _proj44(K, poses[i]);
        final tri = cv.triangulatePoints(p0, p1, pts1f, pts2f);
        p0.dispose();
        p1.dispose();

        final triRows = tri.rows;
        final triCols = tri.cols;
        if (triRows >= 4 && triCols >= 1) {
          final data = tri.toList();
          for (int j = 0; j < triCols; j++) {
            final X = data[0][j];
            final Y = data[1][j];
            final Z = data[2][j];
            final W = data[3][j];
            if (W.abs() < 1e-9) continue;
            final x = X / W, y = Y / W, z = Z / W;
            if (x.isNaN || y.isNaN || z.isNaN) continue;
            if (x.abs() > 1e4 || y.abs() > 1e4 || z.abs() > 1e4) continue;
            allPts.add([x, y, z]);
          }
        }
        nPairsOk++;
        tri.dispose();
        pts1f.dispose();
        pts2f.dispose();
        E.dispose();
        rMat.dispose();
        tMat.dispose();
      } catch (e) {
        lastError = e.toString();
        continue;
      }
    }
    matcher.dispose();

    if (allPts.isEmpty) {
      throw StateError(
          "Aucun point 3D. $nPairsAttempted paires tentées, $nPairsOk OK. Dernière erreur: $lastError");
    }

    // Dedup léger (grille) pour limiter les doublons de triangulation
    final seen = <String>{};
    final uniq = <List<double>>[];
    for (final p in allPts) {
      final key =
          "${(p[0] * 200).round()}~${(p[1] * 200).round()}~${(p[2] * 200).round()}";
      if (seen.add(key)) uniq.add(p);
    }

    _writePlyAscii(outPlyPath, uniq);
    return {
      "n_views": views.length,
      "n_points": uniq.length,
      "n_raw_points": allPts.length,
      "ply": outPlyPath,
    };
  } finally {
    for (final v in views) {
      v.gray.dispose();
      v.desc.dispose();
    }
  }
}

List<double> _vec3(cv.Mat m) {
  final l = m.toList(); // 3x1
  return [l[0][0].toDouble(), l[1][0].toDouble(), l[2][0].toDouble()];
}

List<List<double>> _matToList3x3(cv.Mat m) {
  final l = m.toList(); // 3x3
  return [
    [l[0][0].toDouble(), l[0][1].toDouble(), l[0][2].toDouble()],
    [l[1][0].toDouble(), l[1][1].toDouble(), l[1][2].toDouble()],
    [l[2][0].toDouble(), l[2][1].toDouble(), l[2][2].toDouble()],
  ];
}

List<List<double>> _eye3() => [
      [1, 0, 0],
      [0, 1, 0],
      [0, 0, 1],
    ];

List<List<double>> _matMul3x3(List<List<double>> A, List<List<double>> B) {
  return List.generate(
      3,
      (i) => List.generate(3, (j) {
            return A[i][0] * B[0][j] +
                A[i][1] * B[1][j] +
                A[i][2] * B[2][j];
          }));
}

List<List<double>> _rtTo34(List<List<double>> R, List<double> t) {
  return [
    [R[0][0], R[0][1], R[0][2], t[0]],
    [R[1][0], R[1][1], R[1][2], t[1]],
    [R[2][0], R[2][1], R[2][2], t[2]],
  ];
}

cv.Mat _proj44(List<List<double>> K, List<List<double>> rt) {
  // P = K @ rt  -> 3x4
  final flat = List<double>.filled(12, 0);
  for (int i = 0; i < 3; i++) {
    for (int j = 0; j < 4; j++) {
      double s = 0;
      for (int k = 0; k < 3; k++) {
        s += K[i][k] * rt[k][j];
      }
      flat[i * 4 + j] = s;
    }
  }
  return cv.Mat.fromList(3, 4, cv.MatType.CV_64FC1, flat);
}

void _writePlyAscii(String path, List<List<double>> pts) {
  final buf = StringBuffer();
  buf.writeln("ply");
  buf.writeln("format ascii 1.0");
  buf.writeln("element vertex ${pts.length}");
  buf.writeln("property float x");
  buf.writeln("property float y");
  buf.writeln("property float z");
  buf.writeln("end_header");
  for (final p in pts) {
    buf.write(p[0].toStringAsFixed(6));
    buf.write(" ");
    buf.write(p[1].toStringAsFixed(6));
    buf.write(" ");
    buf.writeln(p[2].toStringAsFixed(6));
  }
  File(path).writeAsStringSync(buf.toString());
}
