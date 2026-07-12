import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/texture_extraction.dart';
import '../services/color_extraction.dart';
import '../services/digit_detection.dart';
import '../services/api_client.dart';
import 'package:provider/provider.dart';
import 'finalize_piece_screen.dart';

/// Scan unifié (remplace les anciens scans 1/2/3) :
/// - détecte le chiffre en relief (2/5) sur chaque frame (repère de rotation),
/// - capture la base (fond poncé) quand elle remplit la zone centrale,
/// - accumule la signature couleur / rotation du corps de l'objet,
/// - crée le draft de pièce (chiffre + texture de base) puis, à la fin,
///   patch la signature couleur et lance la finalisation.
class RotationScanScreen extends StatefulWidget {
  const RotationScanScreen({super.key});

  @override
  State<RotationScanScreen> createState() => _RotationScanScreenState();
}

class _RotationScanScreenState extends State<RotationScanScreen> {
  CameraController? _cameraController;
  int _sensorOrientation = 0;
  bool _isCameraReady = false;
  bool _scanning = false;
  bool _done = false;
  bool _saving = false;
  bool _creatingDraft = false;
  String? _error;
  String? _digitValue; // chiffre CONFIRMÉ (arme la base + rotation)
  String? _pendingDigit; // chiffre détecté stable, en attente de confirmation
  bool _confirming = false; // appel serveur de vérification en cours
  List<double>? _lastDetHu; // signature Hu du dernier chiffre détecté
  String _digitDebug = ''; // métriques de la dernière tentative de détection
  String? _pieceId;

  // Stabilité du chiffre : on n'accepte un chiffre détecté qu'après N
  // détections cohérentes sur les dernières frames. Évite les faux positifs
  // sur le fond (qui clignotent d'une frame à l'autre).
  final List<String?> _digitBuf = [];
  static const int _digitBufLen = 8;
  static const int _digitMinCount = 5;

  double _screenWidth = 0.0;
  double _screenHeight = 0.0;

  int _framesProcessed = 0;
  double _liveSharpness = 0;
  int _calibPct = 0;
  int _skippedBlurry = 0;

  // Base (fond poncé)
  final TextureExtractor _baseExtractor = TextureExtractor(nFeatures: 500);
  bool _baseCaptured = false;
  TextureFrame? _baseFrame;
  int? _baseStableSince;
  int _baseCheckCounter = 0;
  double _lastFillRatio = 0.0;

  CoverageTracker _tracker = CoverageTracker(4, 4);
  final AdaptiveSharpnessGate _sharpnessGate = AdaptiveSharpnessGate();

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
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted) {
            setState(() => _error = null);
            _initCamera();
          }
        });
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
    clearDigitReferences(); // nouveau scan -> nouveau template d'auth

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

    // 1) Chiffre en relief : repère de rotation, affiché à l'écran.
    // On n'accepte un chiffre qu'après détections cohérentes (stabilité temp.)
    // pour éliminer les faux positifs sur le fond qui clignotent.
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
        if (c >= _digitMinCount) stable ??= k;
      });
      // On propose le chiffre à l'utilisateur ; seul un chiffre CONFIRMÉ
      // (via le bouton) arme la base/rotation. Évite tout faux positif de fond.
      if (stable != null && stable != _pendingDigit && stable != _digitValue) {
        _pendingDigit = stable;
        if (mounted) setState(() {});
      }
    }
    if (det.hu != null) _lastDetHu = det.hu;
    _digitDebug = digitDebug;
    _tracker.addDigit(det, _digitValue, image.width);

    // 2) Base (fond poncé) : détection throttlée, capture une seule fois.
    _baseCheckCounter++;
    if (!_baseCaptured && region != null && _baseCheckCounter % 5 == 0) {
      _checkAndCaptureBase(image, region);
    }

    // 3) Accumulation rotation / couleur (corps de l'objet).
    // Armée seulement une fois le chiffre détecté : évite d'accumuler le fond.
    if (region != null && _digitValue != null) {
      final sig = SpatialSignature.extract(image);
      _tracker.addFrame(sig);
    }

    // 4) Création du draft dès qu'on a chiffre + base.
    if (_digitValue != null && _baseCaptured && _pieceId == null && !_creatingDraft) {
      _createDraft();
    }

    // 5) Finalisation.
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
    // La base mapée compte pour 50% de l'objet ; le reste vient de la rotation.
    return _baseCaptured ? (0.5 + 0.5 * rot).clamp(0.0, 1.0) : rot;
  }

  bool _canFinish() =>
      _baseCaptured &&
      _pieceId != null &&
      ((_tracker.isStable && _displayCoverage() >= 0.9) ||
       _framesProcessed >= 1200);

  void _checkAndCaptureBase(CameraImage image, CameraCircleRegion region) {
    // La base appartient au même objet que le chiffre gravé : on n'arme la
    // capture de la base QUE si un chiffre a déjà été détecté de façon stable.
    // Sur un fond vide le chiffre ne se stabilise jamais -> pas de faux positif.
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
        _baseFrame?.dispose();
        _baseFrame = cap;
        _baseCaptured = true;
        if (mounted) setState(() {});
      }
    }
  }

  Future<void> _createDraft() async {
    if (_baseFrame == null || _digitValue == null) return;
    _creatingDraft = true;
    try {
      final descMat = _baseFrame!.descriptors;
      final allKps = _baseFrame!.keypoints;
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

      final api = context.read<ApiClient>();
      final resp = await api.post('/pieces/draft', body: {
        'texture_signature': {
          'descriptors': descData,
          'keypoints': kpData,
          'keypoints_count': allKps.length,
          'sharpness': _baseFrame!.sharpness,
        },
        'digit_guess': _digitValue,
        'top_image': null,
      });
      _pieceId = resp['id'] as String;
      _baseFrame?.dispose();
      _baseFrame = null;
    } catch (e) {
      _creatingDraft = false;
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur draft: $e')));
      }
    }
  }

  Future<void> _finishScan() async {
    if (_done) return;
    setState(() {
      _done = true;
      _saving = true;
    });
    try {
      final api = context.read<ApiClient>();
      await api.patch('/pieces/$_pieceId', body: {
        'color_signature': _tracker.toSignatureJson(),
      });
      if (mounted) {
        final cam = _cameraController;
        _cameraController = null;
        await cam?.stopImageStream();
        await cam?.dispose();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => FinalizePieceScreen(
              pieceId: _pieceId!,
              digitGuess: _digitValue,
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _saving = false;
          _done = false;
        });
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Erreur: $e')));
      }
    }
  }

  double _fillRatioDisplay = 0.0;

  Future<void> _confirmDigit() async {
    if (_pendingDigit == null || _lastDetHu == null || _confirming) return;
    setState(() => _confirming = true);
    try {
      final api = context.read<ApiClient>();
      // Vérification CÔTÉ SERVEUR : le chiffre doit correspondre au moule
      // officiel (auth). Le client n'est pas de confiance.
      final resp = await api.post('/digits/verify', body: {
        'value': _pendingDigit,
        'hu': _lastDetHu,
      });
      if (resp['authentic'] == true) {
        // OK : correspond au moule officiel.
      } else if (resp['reason'] == 'reference_non_definie') {
        // Bootstrap : premier calibrage. Un artiste de confiance enregistre la
        // signature EXACTE de ce moule comme référence officielle (côté
        // serveur). Les scans suivants seront vérifiés strictement contre elle.
        await api.post('/digits/reference', body: {
          'value': _pendingDigit,
          'hu': _lastDetHu,
        });
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Chiffre NON authentique : ce n\'est pas un moule officiel '
              '(distance ${resp['distance']})',
            ),
          ));
          setState(() {
            _pendingDigit = null;
            _confirming = false;
          });
        }
        return;
      }
      // Enregistre la signature EXACTE du chiffre moulé comme template local
      // (repère de rotation) : seul CE "5" (même moule) sera reconnu ensuite.
      if (_lastDetHu != null) setDigitReference(_pendingDigit!, _lastDetHu!);
      if (mounted) {
        setState(() {
          _digitValue = _pendingDigit;
          _pendingDigit = null;
          _confirming = false;
        });
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur de vérification : $e')),
        );
        setState(() => _confirming = false);
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.stopImageStream();
    _cameraController?.dispose();
    _baseFrame?.dispose();
    _baseExtractor.dispose();
    super.dispose();
  }

  double get _gaugeValue => _saving
      ? 1.0
      : (_done ? 1.0 : 0.8 + _displayCoverage() * 0.2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Scan complet de l\'objet')),
      body: _error != null
          ? Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(_error!, style: const TextStyle(color: Colors.red)),
                const SizedBox(height: 16),
                const CircularProgressIndicator(),
                const Text('Accumulation des pixels en cours...',
                    style: TextStyle(color: Colors.white54)),
              ]),
            )
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
                              'Chiffre confirmé : $_digitValue ✓',
                              style: const TextStyle(
                                color: Colors.greenAccent,
                                fontSize: 16,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          )
                        else if (_pendingDigit != null)
                          Column(children: [
                            Container(
                              margin: const EdgeInsets.only(bottom: 8),
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 4),
                              decoration: BoxDecoration(
                                color: Colors.amber.withOpacity(0.25),
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                'Chiffre détecté : $_pendingDigit ?',
                                style: const TextStyle(
                                  color: Colors.amber,
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ),
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
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: _gaugeValue,
                            minHeight: 16,
                            backgroundColor: Colors.white24,
                            valueColor: AlwaysStoppedAnimation<Color>(
                              _done || _saving ? Colors.green : Colors.amber,
                            ),
                          ),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          _saving
                              ? 'Finalisation... 100%'
                              : _done
                                  ? '100% — Scan terminé !'
                                  : 'Scan : ${(_displayCoverage() * 100).toStringAsFixed(0)}%',
                          style: TextStyle(
                            color: _done || _saving
                                ? Colors.greenAccent
                                : Colors.white70,
                            fontSize: 16,
                            fontWeight: FontWeight.bold,
                          ),
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
                                ? 'Sauvegarde des motifs...'
                                : _baseCaptured
                                    ? 'Base capturée ✓ — tourne l\'objet pour la rotation'
                                    : _digitValue != null
                                        ? 'Montre la base (fond poncé) dans la zone verte'
                                        : _pendingDigit != null
                                            ? 'Confirme le chiffre détecté'
                                            : 'Cadre l\'objet : détecte le chiffre gravé (2/5)',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                        if (_scanning) ...[
                          const SizedBox(height: 6),
                          Text(
                            'Base: ${_baseCaptured ? "capturée" : "en attente"} | Remplissage: ${(_fillRatioDisplay * 100).toStringAsFixed(0)}%',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Couverture: ${(_displayCoverage() * 100).toStringAsFixed(0)}% | Frames: $_framesProcessed',
                            style: const TextStyle(
                              color: Colors.white70,
                              fontSize: 13,
                            ),
                          ),
                          Text(
                            'Netteté: ${_liveSharpness.toStringAsFixed(1)} | Calib: $_calibPct% | Floues: $_skippedBlurry',
                            style: const TextStyle(
                              color: Colors.white54,
                              fontSize: 11,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'debug chiffre: ${_digitDebug.isEmpty ? "-" : _digitDebug}',
                            style: const TextStyle(
                              color: Colors.white38,
                              fontSize: 10,
                            ),
                          ),
                        ],
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
