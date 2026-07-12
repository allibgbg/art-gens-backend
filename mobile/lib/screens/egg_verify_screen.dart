import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../services/texture_extraction.dart';
import '../services/color_extraction.dart';
import '../services/digit_detection.dart';
import '../services/egg_vault.dart';
import '../services/egg_auth.dart';
import 'egg_fiche_screen.dart';

/// Écran « Vérifier un œuf » : scan on-device (chiffre + base + couleur) puis
/// interrogation du backend qui renvoie la FICHE de l'œuf reconnu (pas de
/// verdict passe/échec).
class EggVerifyScreen extends StatefulWidget {
  const EggVerifyScreen({super.key});

  @override
  State<EggVerifyScreen> createState() => _EggVerifyScreenState();
}

class _EggVerifyScreenState extends State<EggVerifyScreen> {
  CameraController? _cameraController;
  int _sensorOrientation = 0;
  bool _isCameraReady = false;
  bool _scanning = false;
  bool _done = false;
  bool _saving = false;
  String? _error;
  String? _digitValue;
  String? _pendingDigit;
  bool _confirming = false;
  List<double>? _lastDetHu;
  int _digitBufLen = 8;
  final List<String?> _digitBuf = [];

  double _screenWidth = 0.0;
  double _screenHeight = 0.0;
  int _framesProcessed = 0;
  double _liveSharpness = 0;
  int _calibPct = 0;
  int _skippedBlurry = 0;

  final TextureExtractor _baseExtractor = TextureExtractor(nFeatures: 500);
  bool _baseCaptured = false;
  TextureFrame? _baseFrame;
  int? _baseStableSince;
  int _baseCheckCounter = 0;
  double _lastFillRatio = 0.0;

  CoverageTracker _tracker = CoverageTracker(4, 4);
  final AdaptiveSharpnessGate _sharpnessGate = AdaptiveSharpnessGate();

  // Signature de base sérialisée pour l'identification.
  Map<String, dynamic>? _candidateBase;
  bool _identifying = false;
  Map<String, dynamic>? _enrollData;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _error = 'Aucune caméra disponible');
      return;
    }
    final cam = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _sensorOrientation = cam.sensorOrientation;
    try {
      final controller = CameraController(cam, ResolutionPreset.medium);
      await controller.initialize();
      try {
        await controller.setFocusMode(FocusMode.auto);
        final minZ = await controller.getMinZoomLevel();
        final maxZ = await controller.getMaxZoomLevel();
        await controller.setZoomLevel(1.4.clamp(minZ, maxZ));
        await controller.setFocusPoint(const Offset(0.5, 0.5));
      } catch (_) {}
      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
          _error = null;
        });
        _startScan();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur caméra: $e');
      }
    }
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

  Future<void> _startScan() async {
    if (_cameraController == null || _scanning) return;
    setState(() {
      _scanning = true;
      _done = false;
      _error = null;
    });
    _tracker = CoverageTracker(4, 4);
    _sharpnessGate.reset();
    try {
      await _cameraController!.startImageStream(_onImage);
    } catch (e) {
      if (mounted) setState(() => _error = 'Erreur flux: $e');
    }
  }

  void _onImage(CameraImage image) {
    if (!_scanning || _done) return;
    final qs = quickSharpness(image);
    if (!_sharpnessGate.isSharp(qs)) {
      _skippedBlurry++;
      if (mounted) setState(() {});
      return;
    }
    _framesProcessed++;

    final region = computeFixedCenterCircleRegion(
      image: image,
      sensorOrientation: _sensorOrientation,
      screenWidth: _screenWidth,
      screenHeight: _screenHeight,
    );

    final det = detectDigitFromImage(image, enforceCentering: false);
    if (det.value != null) {
      _digitBuf.add(det.value);
      if (_digitBuf.length > _digitBufLen) _digitBuf.removeAt(0);
      final counts = <String, int>{};
      for (final v in _digitBuf) {
        if (v != null) counts[v] = (counts[v] ?? 0) + 1;
      }
      String? stable;
      counts.forEach((k, c) {
        if (c >= 5) stable ??= k;
      });
      if (stable != null && stable != _pendingDigit && stable != _digitValue) {
        _pendingDigit = stable;
        if (mounted) setState(() {});
      }
    }
    if (det.hu != null) _lastDetHu = det.hu;

    _tracker.addDigit(det, _digitValue, image.width);

    _baseCheckCounter++;
    if (!_baseCaptured && region != null && _baseCheckCounter % 5 == 0) {
      _checkAndCaptureBase(image, region);
    }

    if (region != null && _digitValue != null) {
      final sig = SpatialSignature.extract(image);
      _tracker.addFrame(sig);
    }

    if (_canFinish() && !_done) {
      _finishScan();
    }

    if (mounted) {
      setState(() {
        _liveSharpness = qs;
        _calibPct = _sharpnessGate.calibrationProgress;
        _fillRatioDisplay = _lastFillRatio;
      });
    }
  }

  double _displayCoverage() {
    final rot = _tracker.coverage;
    return _baseCaptured ? (0.5 + 0.5 * rot).clamp(0.0, 1.0) : rot;
  }

  bool _canFinish() =>
      _baseCaptured &&
      _candidateBase != null &&
      ((_tracker.isStable && _displayCoverage() >= 0.9) || _framesProcessed >= 1200);

  void _checkAndCaptureBase(CameraImage image, CameraCircleRegion region) {
    if (_digitValue == null) return;
    final frame = _baseExtractor.extract(image, region: region, logErrors: false);
    if (frame == null) {
      _lastFillRatio = 0.0;
      return;
    }
    double minX = double.infinity, minY = double.infinity, maxX = 0, maxY = 0;
    for (final kp in frame.keypoints) {
      if (kp.x < minX) minX = kp.x;
      if (kp.x > maxX) maxX = kp.x;
      if (kp.y < minY) minY = kp.y;
      if (kp.y > maxY) maxY = kp.y;
    }
    final kpArea = (maxX - minX) * (maxY - minY);
    final circleArea = math.pi * region.radius * region.radius;
    final fill = circleArea > 0 ? (kpArea / circleArea).clamp(0.0, 1.0) : 0.0;
    _lastFillRatio = fill;

    if (fill < 0.70 || frame.keypoints.length < 30) {
      _baseStableSince = null;
      frame.dispose();
      return;
    }
    final now = DateTime.now().millisecondsSinceEpoch;
    _baseStableSince ??= now;
    frame.dispose();
    if (now - _baseStableSince! >= 1500) {
      final cap = _baseExtractor.extract(image, region: region, logErrors: true);
      if (cap != null && cap.keypoints.length >= 30) {
        _serializeBase(cap);
        _baseFrame?.dispose();
        _baseFrame = cap;
        _baseCaptured = true;
        if (mounted) setState(() {});
      }
    }
  }

  void _serializeBase(TextureFrame frame) {
    final descMat = frame.descriptors;
    final allKps = frame.keypoints;
    final indices = List<int>.generate(allKps.length, (i) => i)
      ..sort((a, b) => allKps[b].response.compareTo(allKps[a].response));
    final topN = indices.take(256).toList();
    final descData = <List<int>>[];
    for (final i in topN) {
      final row = <int>[];
      for (int j = 0; j < descMat.cols; j++) row.add(descMat.atU8(i, i1: j));
      descData.add(row);
    }
    final kpData = topN
        .map((i) => {
              'x': allKps[i].x,
              'y': allKps[i].y,
              'response': allKps[i].response,
            })
        .toList();
    _candidateBase = {
      'descriptors': descData,
      'keypoints': kpData,
      'keypoints_count': allKps.length,
      'sharpness': frame.sharpness,
    };
  }

  Future<void> _confirmDigit() async {
    if (_pendingDigit == null || _lastDetHu == null || _confirming) return;
    setState(() => _confirming = true);
    await Future.delayed(const Duration(milliseconds: 150));
    if (mounted) {
      setState(() {
        _digitValue = _pendingDigit;
        _pendingDigit = null;
        _confirming = false;
      });
    }
  }

  Future<void> _finishScan() async {
    if (_done || _identifying) return;
    setState(() {
      _done = true;
      _saving = true;
      _identifying = true;
    });
    try {
      final refs = await EggVault.loadAll();
      final result = EggAuth.identify(
        digit: _digitValue!,
        candidateHu: _lastDetHu ?? [],
        candidateBase: EggBaseSample.fromJson(_candidateBase!),
        candidateColor: _tracker.toSignatureJson(),
        references: refs,
      );
      // Données pour enregistrer une référence si aucune ne correspond.
      Map<String, dynamic>? enroll;
      if (result.decision == 'inconnu') {
        enroll = {
          'hu': _lastDetHu ?? [],
          'base': _candidateBase!,
          'color': _tracker.toSignatureJson(),
        };
      }
      if (mounted) {
        final cam = _cameraController;
        _cameraController = null;
        await cam?.stopImageStream();
        await cam?.dispose();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => EggFicheScreen(
              result: result,
              digitValue: _digitValue,
              enrollData: enroll,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _done = false;
          _identifying = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur identification: $e')));
      }
    }
  }

  double _fillRatioDisplay = 0.0;

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _baseFrame?.dispose();
    _baseExtractor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vérifier un œuf')),
      body: _error != null
          ? Center(child: Text(_error!, style: const TextStyle(color: Colors.red)))
          : LayoutBuilder(
              builder: (_, constraints) {
                if (_screenWidth != constraints.maxWidth ||
                    _screenHeight != constraints.maxHeight) {
                  _screenWidth = constraints.maxWidth;
                  _screenHeight = constraints.maxHeight;
                }
                return Stack(children: [
                  if (_isCameraReady && _cameraController != null)
                    GestureDetector(
                      onTapUp: (d) => _onTapFocus(d, constraints),
                      child: CameraPreview(_cameraController!),
                    ),
                  if (!_isCameraReady) const Center(child: CircularProgressIndicator()),
                  CustomPaint(
                    painter: _CenterCircleGuide(),
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                  ),
                  Column(children: [
                    const Spacer(),
                    Container(
                      margin: const EdgeInsets.all(24),
                      padding: const EdgeInsets.all(20),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(16),
                      ),
                      child: Column(children: [
                        if (_digitValue != null)
                          Container(
                            margin: const EdgeInsets.only(bottom: 8),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 12, vertical: 4),
                            decoration: BoxDecoration(
                              color: Colors.green.withOpacity(0.25),
                              borderRadius: BorderRadius.circular(8),
                            ),
                            child: Text(
                              'Chiffre : $_digitValue',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        else if (_pendingDigit != null)
                          Column(children: [
                            Text(
                              'Chiffre détecté : $_pendingDigit ?',
                              style: const TextStyle(
                                color: Colors.amber,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            ElevatedButton(
                              onPressed: _confirming ? null : _confirmDigit,
                              style: ElevatedButton.styleFrom(
                                backgroundColor: Colors.green,
                                foregroundColor: Colors.white,
                              ),
                              child: _confirming
                                  ? const SizedBox(
                                      width: 16,
                                      height: 16,
                                      child: CircularProgressIndicator(
                                        strokeWidth: 2,
                                        color: Colors.white,
                                      ),
                                    )
                                  : const Text('Confirmer le chiffre'),
                            ),
                          ]),
                        const SizedBox(height: 8),
                        Text(
                          _saving
                              ? 'Identification en cours...'
                              : _baseCaptured
                                  ? 'Base capturée ✓ — tourne l\'œuf pour la rotation'
                                  : _digitValue != null
                                      ? 'Montre la base (fond poncé) dans la zone verte'
                                      : _pendingDigit != null
                                          ? 'Confirme le chiffre détecté'
                                          : 'Cadre l\'œuf : détecte le chiffre gravé (2/5)',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.center,
                        ),
                        const SizedBox(height: 12),
                        Icon(
                          _saving
                              ? Icons.hourglass_top
                              : (_done
                                  ? Icons.check_circle
                                  : Icons.threesixty),
                          color: _done || _saving ? Colors.green : Colors.amber,
                          size: 48,
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _saving
                              ? '100%'
                              : 'Scan : ${(_displayCoverage() * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          'Base: ${_baseCaptured ? "capturée" : "en attente"} | Remplissage: ${(_fillRatioDisplay * 100).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        Text(
                          'Couverture: ${(_displayCoverage() * 100).toStringAsFixed(0)}% | Frames: $_framesProcessed',
                          style: const TextStyle(color: Colors.white70, fontSize: 13),
                        ),
                        Text(
                          'Netteté: ${_liveSharpness.toStringAsFixed(1)} | Calib: $_calibPct% | Floues: $_skippedBlurry',
                          style: const TextStyle(color: Colors.white54, fontSize: 11),
                        ),
                      ]),
                    ),
                    const SizedBox(height: 32),
                  ]),
                ]);
              },
            ),
    );
  }
}

class _CenterCircleGuide extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    const double radius = 200.0;
    final paint = Paint()
      ..color = Colors.white38
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(Offset(cx, cy), radius, paint);
    final tickPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    for (final angle in [0.0, 90.0, 180.0, 270.0]) {
      final rad = angle * (3.14159 / 180.0);
      final dx = radius * math.cos(rad), dy = radius * math.sin(rad);
      canvas.drawLine(
        Offset(cx + dx * 0.9, cy + dy * 0.9),
        Offset(cx + dx * 1.1, cy + dy * 1.1),
        tickPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _CenterCircleGuide oldDelegate) => false;
}
