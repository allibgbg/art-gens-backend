import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'texture_scan_screen.dart';

/// Phase 1 — détection du chiffre gravé (dessus de l'objet).
/// Ne crée pas encore la pièce en base : le chiffre détecté + la photo
/// sont transmis à [TextureScanScreen], qui créera la pièce en une seule
/// fois avec toutes les données (chiffre, photo dessus, texture du fond),
/// et utilisera le chiffre pour appliquer le bon preset zoom/focus.
class DigitScanScreen extends StatefulWidget {
  const DigitScanScreen({super.key});

  @override
  State<DigitScanScreen> createState() => _DigitScanScreenState();
}

class _DigitScanScreenState extends State<DigitScanScreen> {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _done = false;
  String? _error;
  String? _digitGuess;
  double _digitConfidence = 0.0;
  int _scanAttempts = 0;
  bool _capturing = false;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) { setState(() => _error = 'Aucune caméra disponible'); return; }
    for (final c in cameras) {
      // ignore: avoid_print
      print('[Camera] name=${c.name} lens=${c.lensDirection} sensorOrientation=${c.sensorOrientation}');
    }
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    try {
      final controller = CameraController(cam, ResolutionPreset.medium);
      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setFocusPoint(const Offset(0.5, 0.5));
      } catch (_) {}
      if (mounted) {
        setState(() { _cameraController = controller; _isCameraReady = true; _error = null; });
        _startStream();
      }
    } catch (e) { if (mounted) setState(() => _error = 'Erreur caméra: $e'); }
  }

  Future<void> _onTapFocus(TapUpDetails details, BoxConstraints constraints) async {
    final controller = _cameraController;
    if (controller == null) return;
    final point = Offset(
      (details.localPosition.dx / constraints.maxWidth).clamp(0.0, 1.0),
      (details.localPosition.dy / constraints.maxHeight).clamp(0.0, 1.0),
    );
    try {
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
    } catch (_) {}
  }

  Future<void> _startStream() async {
    if (_cameraController == null || _capturing) return;
    _capturing = true;
    try {
      await _cameraController!.startImageStream(_onImage);
    } catch (e) {
      if (mounted) setState(() => _error = 'Erreur flux: $e');
    }
  }

  void _onImage(CameraImage image) {
    if (!_capturing || _digitGuess != null || _done) return;
    _scanAttempts++;
    if (mounted) setState(() {});
    try {
      final yPlane = image.planes[0];
      final w = image.width;
      final h = image.height;
      final yData = Uint8List(w * h);
      for (int y = 0; y < h; y++) {
        final src = y * yPlane.bytesPerRow;
        final dst = y * w;
        yData.setRange(dst, dst + w, yPlane.bytes, src);
      }
      final gray = cv.Mat.fromList(h, w, cv.MatType.CV_8UC1, yData.cast<num>().toList());
      _analyzeGray(gray);
      gray.dispose();
    } catch (_) {}
    if (_digitGuess != null && _cameraController != null) {
      _capturing = false;
      try { _cameraController?.stopImageStream(); } catch (_) {}
      _takePhotoAndContinue();
    }
  }

  int _stableHits = 0;
  static const int _neededStableHits = 20;
  String? _stableGuess;

  void _analyzeGray(cv.Mat gray) {
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
      for (final c in contours) {
        final a = cv.contourArea(c);
        if (a > maxArea) { maxArea = a; best = c; }
      }
      if (best == null || best.length < 10) { cleaned.dispose(); contours.dispose(); return; }

      final rect = cv.boundingRect(best);
      contours.dispose();

      final areaRatio = maxArea / imgArea;
      if (areaRatio < 0.005 || areaRatio > 0.60) { cleaned.dispose(); return; }
      final aspect = rect.width / math.max(1, rect.height);
      if (aspect < 0.2 || aspect > 5.0) { cleaned.dispose(); return; }
      final cx = rect.x + rect.width / 2;
      final cy = rect.y + rect.height / 2;
      if (math.sqrt((cx - gray.cols / 2) * (cx - gray.cols / 2) + (cy - gray.rows / 2) * (cy - gray.rows / 2)) > math.min(gray.cols, gray.rows) * 0.40) {
        cleaned.dispose(); return;
      }

      final roi = cleaned.region(rect);
      cleaned.dispose();
      final normalized = cv.resize(roi, (64, 64));
      roi.dispose();

      int tl = 0, tr = 0, bl = 0, br = 0;
      for (int r = 0; r < 64; r++) {
        for (int c = 0; c < 64; c++) {
          if (normalized.atU8(r, i1: c) > 0) {
            if (r < 32) { if (c < 32) tl++; else tr++; }
            else { if (c < 32) bl++; else br++; }
          }
        }
      }
      normalized.dispose();

      final total = tl + tr + bl + br;
      if (total < 10) return;

      String guess;
      if (br > bl * 1.3 && tl > tr * 1.2) {
        guess = '2';
      } else if (tl + tr > bl + br && tl + tr > total * 0.52) {
        guess = '5';
      } else if (br > bl * 1.2) {
        guess = '2';
      } else {
        guess = '5';
      }

      if (guess == _stableGuess) {
        _stableHits++;
        if (_stableHits >= _neededStableHits) {
          _digitGuess = guess;
          _digitConfidence = 0.7;
        }
      } else {
        _stableGuess = guess;
        _stableHits = 1;
      }
    } catch (_) {}
  }

  Future<void> _takePhotoAndContinue() async {
    if (_cameraController == null) return;
    try {
      final xfile = await _cameraController!.takePicture();
      final bytes = await xfile.readAsBytes();
      if (mounted) setState(() => _done = true);
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      final cam = _cameraController;
      _cameraController = null;
      await cam?.dispose();
      Navigator.pushReplacement(
        context,
        MaterialPageRoute(
          builder: (_) => TextureScanScreen(
            digitGuess: _digitGuess,
            topImageBase64: base64Encode(bytes),
          ),
        ),
      );
    } catch (e) {
      if (mounted) setState(() => _error = 'Erreur photo: $e');
    }
  }

  @override
  void dispose() { _cameraController?.dispose(); super.dispose(); }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 1 — Chiffre')),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
          : LayoutBuilder(builder: (_, constraints) => Stack(children: [
              if (_isCameraReady && _cameraController != null)
                GestureDetector(
                  onTapUp: (d) => _onTapFocus(d, constraints),
                  child: CameraPreview(_cameraController!),
                ),
              if (!_isCameraReady) const Center(child: CircularProgressIndicator()),
              Column(children: [
                const Spacer(),
                Container(
                  margin: const EdgeInsets.all(24), padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
                  child: Column(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _done ? 0.3 : 0.15,
                        minHeight: 16, backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.amber),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _done ? 'Chiffre $_digitGuess détecté' : 'Détection du chiffre...',
                      style: const TextStyle(color: Colors.amberAccent, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Icon(_done ? Icons.looks : Icons.camera_alt,
                      color: _done ? Colors.green : Colors.amber, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      _done
                          ? 'Chiffre $_digitGuess détecté (${(_digitConfidence * 100).toStringAsFixed(0)}%)'
                          : 'Montre le dessus de l\'objet (chiffre visible)\nTouche l\'écran pour ajuster la mise au point\n(Tentative $_scanAttempts)',
                      textAlign: TextAlign.center,
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                  ]),
                ),
                const SizedBox(height: 32),
              ]),
            ])),
    );
  }
}
