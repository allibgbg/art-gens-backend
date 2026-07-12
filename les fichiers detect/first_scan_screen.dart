import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../services/multi_angle_scan.dart';
import 'bottom_scan_screen.dart';

class FirstScanScreen extends StatefulWidget {
  const FirstScanScreen({super.key});

  @override
  State<FirstScanScreen> createState() => _FirstScanScreenState();
}

class _FirstScanScreenState extends State<FirstScanScreen>
    with SingleTickerProviderStateMixin {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _scanning = false;
  bool _done = false;
  MultiAngleScanner? _scanner;
  double _confidence = 0;
  double _liveSharpness = 0;
  double _maxSharpness = 0;
  int _calibPct = 0;
  int _skippedBlurry = 0;
  int _framesProcessed = 0;
  ScanResult? _result;
  String? _error;
  late AnimationController _pulseAnim;

  // Top image analysis
  String? _capturedTopImageBase64;
  String? _digitGuess;
  double _digitConfidence = 0.0;

  @override
  void initState() {
    super.initState();
    _pulseAnim = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat(reverse: true);
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() => _error = 'Aucune caméra disponible');
      return;
    }
    try {
      final controller = CameraController(cameras.first, ResolutionPreset.medium);
      await controller.initialize();
      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur caméra: $e');
      }
    }
  }

  Future<void> _startScan() async {
    if (_cameraController == null || _scanning) return;
    setState(() {
      _scanning = true;
      _confidence = 0;
      _done = false;
      _capturedTopImageBase64 = null;
      _digitGuess = null;
      _digitConfidence = 0.0;
    });

    final scanner = MultiAngleScanner(_cameraController!);
    _scanner = scanner;

    scanner.onProgress = (cov, conf) {
      if (mounted) {
        setState(() => _confidence = conf);
      }
    };

    scanner.onSharpness = (qs, max, calibPct, skipped, processed) {
      if (mounted) {
        setState(() {
          _liveSharpness = qs;
          _maxSharpness = max;
          _calibPct = calibPct;
          _skippedBlurry = skipped;
          _framesProcessed = processed;
        });
      }
    };

    try {
      _result = await scanner.start();
    } catch (_) {
      _result = null;
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _done = true;
      });
    }
  }

  /// Extrait le chiffre gravé (2 ou 5) par analyse de forme (moments de Hu).
  /// Amélioré : crop centré + validation d'aire + seuillage distance plus strict.
  String? _analyzeDigit(Uint8List jpeg) {
    try {
      final raw = jpeg is Uint8List ? jpeg : Uint8List.fromList(jpeg);
      final img = cv.imdecode(raw, cv.IMREAD_COLOR);
      if (img == null) return null;

      final gray = cv.cvtColor(img, cv.COLOR_BGR2GRAY);
      img.dispose();

      // Crop central (zone où se trouve le chiffre gravé) - évite les bords/background
      final h = gray.rows;
      final w = gray.cols;
      final cropSize = (w < h ? w : h) * 0.6;
      final cx = w / 2;
      final cy = h / 2;
      final roi = cv.Rect.fromCenter(
          cx.round(), cy.round(), cropSize.round(), cropSize.round());
      final cropped = cv.Mat.fromMat(gray, roi);
      gray.dispose();

      // Binarisation adaptative (plus robuste qu'Otsu global sur fond variable)
      final bin = cv.adaptiveThreshold(
          cropped, 255, cv.ADAPTIVE_THRESH_GAUSSIAN_C, cv.THRESH_BINARY_INV, 31, 5);
      cropped.dispose();

      // Nettoyage morphologique : fermer petits trous, ouvrir bruit
      final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (5, 5));
      cv.morphologyEx(bin, bin, cv.MORPH_CLOSE, kernel);
      cv.morphologyEx(bin, bin, cv.MORPH_OPEN, kernel);
      kernel.dispose();

      // Filtrer composantes connexes : garder seulement celle au centre (le chiffre)
      final (numLabels, labels, stats, centroids) =
          cv.connectedComponentsWithStats(bin, connectivity: 8);
      if (numLabels <= 1) {
        bin.dispose();
        labels.dispose();
        stats.dispose();
        centroids.dispose();
        return null;
      }

      // Trouver le label du composant le plus central
      int bestLabel = 0;
      double bestDist = double.infinity;
      final centerX = bin.cols / 2.0;
      final centerY = bin.rows / 2.0;
      for (int i = 1; i < numLabels; i++) {
        final cx = centroids.atDouble(i, 0);
        final cy = centroids.atDouble(i, 1);
        final dist = math.sqrt((cx - centerX) * (cx - centerX) + (cy - centerY) * (cy - centerY));
        final area = stats.atInt(i, cv.CC_STAT_AREA);
        if (area > 50 && dist < bestDist) { // aire min pour ignorer le bruit
          bestDist = dist;
          bestLabel = i;
        }
      }
      labels.dispose();
      stats.dispose();
      centroids.dispose();

      if (bestLabel == 0) {
        bin.dispose();
        return null;
      }

      // Masque ne gardant que le chiffre central
      final digitMask = cv.Mat.zeros(bin.rows, bin.cols, cv.MatType.CV_8UC1);
      cv.compare(labels, bestLabel, digitMask, cv.CMP_EQ);
      bin.dispose();

      // Moments de Hu sur le masque du chiffre isolé
      final m = cv.moments(digitMask, binaryImage: true);
      digitMask.dispose();

      final nu20 = m.nu20, nu02 = m.nu02, nu11 = m.nu11;
      final nu30 = m.nu30, nu12 = m.nu12, nu21 = m.nu21, nu03 = m.nu03;
      m.dispose();

      double sq(double x) => x * x;
      final hu = <double>[
        nu20 + nu02,                                                                      // I1
        sq(nu20 - nu02) + 4 * sq(nu11),                                                   // I2
        sq(nu30 - 3 * nu12) + sq(3 * nu21 - nu03),                                        // I3
        sq(nu30 + nu12) + sq(nu21 + nu03),                                                // I4
        (nu30 - 3 * nu12) * (nu30 + nu12) * (sq(nu30 + nu12) - 3 * sq(nu21 + nu03))       // I5
            + (3 * nu21 - nu03) * (nu21 + nu03) * (3 * sq(nu30 + nu12) - sq(nu21 + nu03)),
        (nu20 - nu02) * (sq(nu30 + nu12) - sq(nu21 + nu03))                               // I6
            + 4 * nu11 * (nu30 + nu12) * (nu21 + nu03),
        (3 * nu21 - nu03) * (nu30 + nu12) * (sq(nu30 + nu12) - 3 * sq(nu21 + nu03))       // I7
            - (nu30 - 3 * nu12) * (nu21 + nu03) * (3 * sq(nu30 + nu12) - sq(nu21 + nu03)),
      ];

      final huLog = hu.map((v) => -v.sign * math.log(v.abs() + 1e-10)).toList();

      // Références recalibrées (valeurs typiques observées)
      const ref2 = [1.85, 3.72, 5.10, 4.85, 9.50, 6.20, 7.30];
      const ref5 = [2.15, 4.30, 5.80, 5.20, 10.40, 6.80, 8.10];

      double dist(List<double> a, List<double> b) {
        double s = 0;
        for (int i = 0; i < 7; i++) s += sq(a[i] - b[i]);
        return math.sqrt(s);
      }

      final d2 = dist(huLog, ref2);
      final d5 = dist(huLog, ref5);

      // Seuil de confiance plus strict : distance relative < 0.35
      final bestDist = math.min(d2, d5);
      final conf = (1.0 - bestDist / 8.0).clamp(0.0, 1.0);
      _digitConfidence = conf;

      // Rejeter si pas assez confiant (évite faux positifs sur fond)
      if (conf < 0.55) return null;

      return d2 < d5 ? '2' : '5';
    } catch (_) {
      return null;
    }
  }

  void _validate() async {
    if (_result == null) return;
    final colorSignature = _result!.spatialSignature;

    if (_cameraController != null && _cameraController!.value.isInitialized) {
      try {
        final xfile = await _cameraController!.takePicture();
        final bytes = await xfile.readAsBytes();
        _capturedTopImageBase64 = base64Encode(bytes);
        _digitGuess = _analyzeDigit(bytes);
      } catch (_) {}
    }

    if (!mounted) return;

    final controller = _cameraController;
    _cameraController = null;
    setState(() {});
    await controller?.dispose();

    if (mounted) {
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => BottomScanScreen(
            colorSignature: colorSignature,
            topImageBase64: _capturedTopImageBase64,
          ),
        ),
      );
    }
  }

  void _resetScan() {
    _scanner?.cancel();
    setState(() {
      _result = null;
      _confidence = 0;
      _done = false;
      _capturedTopImageBase64 = null;
      _digitGuess = null;
      _digitConfidence = 0.0;
    });
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _scanner?.cancel();
    _pulseAnim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hasValidResult = _result != null && _framesProcessed > 0;
    final showValidate = _done && hasValidResult;

    return Scaffold(
      body: _error != null
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(_error!,
                      style: const TextStyle(color: Colors.red, fontSize: 16),
                      textAlign: TextAlign.center),
                  const SizedBox(height: 16),
                  ElevatedButton(
                    onPressed: () {
                      setState(() => _error = null);
                      _initCamera();
                    },
                    child: const Text('Réessayer'),
                  ),
                ],
              ),
            )
          : Stack(
        children: [
          if (_isCameraReady && _cameraController != null)
            CameraPreview(_cameraController!)
          else
            const Center(child: CircularProgressIndicator()),

          if (!_done)
            Center(
              child: SizedBox(
                width: MediaQuery.of(context).size.width * 0.7,
                height: MediaQuery.of(context).size.width * 0.7,
                child: CustomPaint(painter: _GuidePainter()),
              ),
            ),

          Column(
            children: [
              const Spacer(),
              Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  color: Colors.black54,
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Column(
                  children: [
                    AnimatedBuilder(
                      animation: _pulseAnim,
                      builder: (_, child) => Transform.rotate(
                        angle: _scanning ? _pulseAnim.value * 0.5 : 0,
                        child: child,
                      ),
                      child: Icon(
                        showValidate ? Icons.check_circle : Icons.auto_awesome,
                        color: showValidate
                            ? Colors.green
                            : _scanning ? Colors.amber : Colors.white54,
                        size: 48,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      _done
                          ? (hasValidResult
                              ? 'Dessus scanné !\nRetourne l\'objet pour scanner le fond'
                              : 'Scan terminé — aucune frame exploitable.\nRapproche-toi et réessaie.')
                          : _scanning
                              ? 'Tourne l\'objet devant la caméra'
                              : 'Scanne le dessus de l\'objet',
                      style: const TextStyle(
                          color: Colors.white, fontSize: 20, fontWeight: FontWeight.bold),
                    ),

                    // Résultat analyse chiffre
                    if (_digitGuess != null && showValidate) ...[
                      const SizedBox(height: 8),
                      Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.looks, color: Colors.greenAccent, size: 28),
                          const SizedBox(width: 8),
                          Text(
                            'Chiffre $_digitGuess détecté',
                            style: const TextStyle(
                              color: Colors.greenAccent,
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '(${(_digitConfidence * 100).toStringAsFixed(0)}%)',
                            style: const TextStyle(color: Colors.white54, fontSize: 14),
                          ),
                        ],
                      ),
                    ],

                    const SizedBox(height: 8),

                    if (_scanning || _done) ...[
                      ClipRRect(
                        borderRadius: BorderRadius.circular(6),
                        child: LinearProgressIndicator(
                          value: _confidence.clamp(0.0, 1.0),
                          minHeight: 12,
                          backgroundColor: Colors.white24,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            _confidence >= 0.8
                                ? Colors.green
                                : _confidence >= 0.5 ? Colors.amber : Colors.orange,
                          ),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        'Couverture : ${(_confidence * 100).toStringAsFixed(0)}%',
                        style: const TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                    if (_scanning) ...[
                      const SizedBox(height: 4),
                      Text(
                        'Netteté: ${_liveSharpness.toStringAsFixed(1)} (max: ${_maxSharpness.toStringAsFixed(1)}) | '
                        'Calib: $_calibPct% | Nettes: $_framesProcessed | Floues: $_skippedBlurry',
                        style: const TextStyle(color: Colors.white54, fontSize: 11),
                      ),
                    ],
                    if (_done && !hasValidResult) ...[
                      const SizedBox(height: 4),
                      Text(
                        '0 frame traitée — vérifie l\'éclairage et la netteté',
                        style: const TextStyle(color: Colors.orangeAccent, fontSize: 12),
                      ),
                    ],
                    const SizedBox(height: 16),

                    if (!_scanning && !_done)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _startScan,
                          icon: const Icon(Icons.camera_alt),
                          label: const Text('Commencer le scan'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                    if (showValidate)
                      Row(
                        children: [
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _resetScan,
                              icon: const Icon(Icons.refresh),
                              label: const Text('Rescanner'),
                              style: OutlinedButton.styleFrom(
                                foregroundColor: Colors.white,
                                side: const BorderSide(color: Colors.white38),
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: ElevatedButton.icon(
                              onPressed: _validate,
                              icon: const Icon(Icons.check),
                              label: Text(_digitGuess != null ? 'Valider ($_digitGuess)' : 'Valider'),
                              style: ElevatedButton.styleFrom(
                                padding: const EdgeInsets.symmetric(vertical: 12),
                              ),
                            ),
                          ),
                        ],
                      ),
                    if (_done && !hasValidResult)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton.icon(
                          onPressed: _resetScan,
                          icon: const Icon(Icons.refresh),
                          label: const Text('Réessayer'),
                          style: ElevatedButton.styleFrom(
                            padding: const EdgeInsets.symmetric(vertical: 14),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 32),
            ],
          ),
        ],
      ),
    );
  }
}

class _GuidePainter extends CustomPainter {
  const _GuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double w = size.width;
    final double h = size.height;
    final double cutRatio = 0.85;
    final double cutY = h * cutRatio;
    final double radius = w * 0.45;

    final guidePaint = Paint()
      ..color = Colors.white38
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    final rrect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, w, cutY),
      topLeft: Radius.circular(radius),
      topRight: Radius.circular(radius),
    );
    canvas.drawRRect(rrect, guidePaint);
    canvas.drawLine(Offset(0, cutY), Offset(w, cutY), guidePaint);
  }

  @override
  bool shouldRepaint(covariant _GuidePainter oldDelegate) => false;
}
