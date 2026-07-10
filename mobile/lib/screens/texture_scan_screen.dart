import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/texture_extraction.dart';
import '../services/api_client.dart';
import '../services/series_config.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';
import 'rotation_scan_screen.dart';

/// Phase 2 — texture du fond poncé.
/// Reçoit le chiffre déjà détecté en Phase 1 pour appliquer le bon preset
/// zoom/focus (voir series_config.dart), et crée la pièce en base en une
/// seule fois avec toutes les données collectées jusqu'ici.
class TextureScanScreen extends StatefulWidget {
  final String? digitGuess;
  final String? topImageBase64;
  const TextureScanScreen({super.key, this.digitGuess, this.topImageBase64});

  @override
  State<TextureScanScreen> createState() => _TextureScanScreenState();
}

class _TextureScanScreenState extends State<TextureScanScreen> {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _capturing = false;
  bool _saving = false;
  double _liveSharpness = 0.0;
  double _maxSharpness = 0.0;
  int _calibPct = 0;
  int _featureCount = 0;
  int _skippedBlurry = 0;
  double _presenceRatio = 0.0;
  late TextureExtractor _extractor;
  String? _error;
  int _sensorOrientation = 0;
  int _retryCount = 0;
  static const int _maxRetries = 3;
  Rect? _objectRect;
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _zoom = 1.0;
  double _circleFraction = 0.6;

  List<Map<String, double>>? _displayKps;
  int _lastImageW = 0;
  int _lastImageH = 0;
  int? _stableSinceMs;
  int _stableDurationMs = 0;
  TextureFrame? _capturedFrame;

  List<Map<String, double>> get _bestKps {
    final list = _displayKps;
    if (list == null || list.isEmpty) return [];
    final sorted = List<Map<String, double>>.from(list)
      ..sort((a, b) => (b['response'] ?? 0).compareTo(a['response'] ?? 0));
    return sorted.take(min(30, sorted.length)).toList();
  }

  @override
  void initState() {
    super.initState();
    _extractor = TextureExtractor(nFeatures: 500);
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      setState(() => _error = 'Aucune caméra disponible');
      return;
    }
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
        _minZoom = await controller.getMinZoomLevel();
        _maxZoom = await controller.getMaxZoomLevel();
      } catch (_) {}
      // Preset zoom/cercle par série (déterminé par le chiffre détecté en Phase 1).
      final config = scanConfigForDigit(widget.digitGuess);
      _zoom = config.zoom.clamp(_minZoom, _maxZoom);
      _circleFraction = config.circleFraction;
      try {
        await controller.setFocusMode(FocusMode.auto);
        await controller.setFocusPoint(const Offset(0.5, 0.5));
        await controller.setZoomLevel(_zoom);
      } catch (_) {}
      // Laisse l'autofocus se stabiliser au centre, puis verrouille — la mise
      // au point ne bouge plus ensuite (approximation de "focus fixe" : l'API
      // caméra ne permet pas de fixer une distance absolue, seulement
      // verrouiller le résultat courant de l'autofocus).
      Future.delayed(const Duration(milliseconds: 1500), () async {
        try { await controller.setFocusMode(FocusMode.locked); } catch (_) {}
      });
      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
          _error = null;
          _sensorOrientation = cam.sensorOrientation;
        });
        _startCapture();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur caméra: $e');
        Future.delayed(const Duration(seconds: 2), () { if (mounted) { setState(() => _error = null); _initCamera(); } });
      }
    }
  }

  Future<void> _startCapture() async {
    if (_cameraController == null || _capturing) return;
    setState(() {
      _capturing = true;
      _capturedFrame?.dispose();
      _capturedFrame = null;
      _skippedBlurry = 0;
      _stableSinceMs = null;
      _stableDurationMs = 0;
      _displayKps = null;
    });
    _retryCount = 0;
    try {
      await _cameraController!.startImageStream(_onImage);
    } catch (e) {
      _error = 'Erreur démarrage flux: $e';
      _capturing = false;
    }
  }

  void _onImage(CameraImage image) {
    if (!_capturing) return;
    final rawQs = quickSharpness(image);
    final gate = _extractor.sharpnessGate;
    _lastImageW = image.width;
    _lastImageH = image.height;

    final ratio = sharpnessRatioInCircle(image, circleFraction: _circleFraction, threshold: 3.0);

    if (mounted) {
      setState(() {
        _liveSharpness = rawQs;
        _maxSharpness = gate.maxSeen;
        _calibPct = gate.calibrationProgress;
        _presenceRatio = ratio;
      });
    }

    if (ratio < 0.72) {
      _stableSinceMs = null;
      _stableDurationMs = 0;
      return;
    }

    final frame = _extractor.extract(image, forceProcess: true, zoneShrink: 0.4, logErrors: true);
    if (frame == null) {
      if (mounted) {
        setState(() {
          _skippedBlurry++;
        });
      }
      return;
    }
    final kpDisplay = frame.keypoints.map((kp) => <String, double>{
      'x': kp.x, 'y': kp.y, 'response': kp.response,
    }).toList();
    if (frame.keypoints.length >= 10) {
      double minX = double.infinity, minY = double.infinity;
      double maxX = 0, maxY = 0;
      for (final kp in frame.keypoints) {
        if (kp.x < minX) minX = kp.x; if (kp.x > maxX) maxX = kp.x;
        if (kp.y < minY) minY = kp.y; if (kp.y > maxY) maxY = kp.y;
      }
      final margin = 30.0;
      _objectRect = Rect.fromLTWH(
        (minX - margin).clamp(0, _lastImageW.toDouble()),
        (minY - margin).clamp(0, _lastImageH.toDouble()),
        (maxX - minX + 2 * margin).clamp(0, _lastImageW.toDouble()),
        (maxY - minY + 2 * margin).clamp(0, _lastImageH.toDouble()),
      );
    } else {
      _objectRect = null;
    }
    setState(() {
      _liveSharpness = rawQs;
      _maxSharpness = gate.maxSeen;
      _calibPct = gate.calibrationProgress;
      _featureCount = frame.keypoints.length;
      _displayKps = kpDisplay;
    });
    if (frame.keypoints.length >= 30) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_stableSinceMs == null) {
        _stableSinceMs = now;
        _capturedFrame?.dispose();
        _capturedFrame = frame;
      } else {
        _capturedFrame?.dispose();
        _capturedFrame = frame;
      }
      setState(() => _stableDurationMs = now - _stableSinceMs!);
      if (_stableDurationMs >= 2000) {
        _saveAndNext();
      }
    } else {
      _stableSinceMs = null;
      _stableDurationMs = 0;
      frame.dispose();
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
      await controller.setFocusMode(FocusMode.auto);
      await controller.setFocusPoint(point);
      await controller.setExposurePoint(point);
      await Future.delayed(const Duration(milliseconds: 800));
      await controller.setFocusMode(FocusMode.locked);
    } catch (_) {}
  }

  Future<void> _setZoom(double value) async {
    final controller = _cameraController;
    if (controller == null) return;
    final clamped = value.clamp(_minZoom, _maxZoom);
    setState(() => _zoom = clamped);
    try {
      await controller.setZoomLevel(clamped);
    } catch (_) {}
  }

  Future<void> _saveAndNext() async {
    if (_capturedFrame == null) return;
    _capturing = false;
    try { _cameraController?.stopImageStream(); } catch (_) {}
    setState(() => _saving = true);

    try {
      final descMat = _capturedFrame!.descriptors;
      final allKps = _capturedFrame!.keypoints;
      final indices = List<int>.generate(allKps.length, (i) => i)
        ..sort((a, b) => allKps[b].response.compareTo(allKps[a].response));
      final topN = indices.take(256).toList();
      final descData = <List<int>>[];
      for (final i in topN) {
        final row = <int>[];
        for (int j = 0; j < descMat.cols; j++) row.add(descMat.atU8(i, i1: j));
        descData.add(row);
      }
      final kpData = topN.map((i) => {
        'x': allKps[i].x, 'y': allKps[i].y, 'response': allKps[i].response,
      }).toList();
      final api = context.read<ApiClient>();

      final resp = await api.post('/pieces/draft', body: {
        'texture_signature': {
          'descriptors': descData,
          'keypoints': kpData,
          'keypoints_count': _capturedFrame!.keypoints.length,
          'sharpness': _capturedFrame!.sharpness,
        },
        'digit_guess': widget.digitGuess,
        'top_image': widget.topImageBase64,
      });
      final pieceId = resp['id'] as String;

      if (mounted) {
        final digitGuess = widget.digitGuess;
        final cam = _cameraController;
        _cameraController = null;
        _capturedFrame?.dispose();
        _capturedFrame = null;
        await cam?.dispose();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => RotationScanScreen(pieceId: pieceId, digitGuess: digitGuess)),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        _retryCount++;
        if (_retryCount >= _maxRetries) {
          setState(() => _error = 'Sauvegarde impossible après $_maxRetries tentatives: $e');
          return;
        }
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur sauvegarde ($_retryCount/$_maxRetries): $e')),
        );
        Future.delayed(const Duration(seconds: 2), () { if (mounted) _startCapture(); });
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    _capturedFrame?.dispose();
    _extractor.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 2 — Texture du fond')),
      body: _error != null
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, style: const TextStyle(color: Colors.red), textAlign: TextAlign.center),
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
              const SizedBox(height: 8),
              const Text('Nouvelle tentative...', style: TextStyle(color: Colors.white54)),
            ]))
          : LayoutBuilder(builder: (context, constraints) => Stack(children: [
              if (_isCameraReady && _cameraController != null)
                GestureDetector(
                  onTapUp: (d) => _onTapFocus(d, constraints),
                  child: CameraPreview(_cameraController!),
                ),
              if (!_isCameraReady && _error == null)
                const Center(child: CircularProgressIndicator()),
              if (_displayKps != null && _capturing) ...[
                CustomPaint(
                  size: Size(constraints.maxWidth, constraints.maxHeight),
                  painter: _KeypointPainter(
                    allKps: _displayKps!, bestKps: _bestKps,
                    imageWidth: _lastImageW, imageHeight: _lastImageH,
                    sensorOrientation: _sensorOrientation,
                  ),
                ),
                if (_objectRect != null)
                  CustomPaint(
                    size: Size(constraints.maxWidth, constraints.maxHeight),
                    painter: _ObjectSpotlight(
                      rect: _objectRect!,
                      imageWidth: _lastImageW,
                      imageHeight: _lastImageH,
                      sensorOrientation: _sensorOrientation,
                    ),
                  ),
              ],
              if (_capturing)
                Center(
                  child: SizedBox(
                    width: MediaQuery.of(context).size.width * _circleFraction,
                    height: MediaQuery.of(context).size.width * _circleFraction,
                    child: CustomPaint(painter: _CircleGuidePainter()),
                  ),
                ),
              if (_capturing && _maxZoom > _minZoom)
                Positioned(
                  right: 12,
                  top: 80,
                  bottom: 220,
                  child: RotatedBox(
                    quarterTurns: 3,
                    child: Slider(
                      value: _zoom,
                      min: _minZoom,
                      max: _maxZoom,
                      onChanged: _setZoom,
                      activeColor: Colors.amber,
                    ),
                  ),
                ),
              Column(children: [
                const Spacer(),
                Container(
                  margin: const EdgeInsets.all(24), padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
                  child: Column(children: [
                    // Gauge globale
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _saving ? 0.6 : (_stableSinceMs != null ? 0.6 * (_stableDurationMs / 2000).clamp(0.0, 1.0) : 0.0),
                        minHeight: 16, backgroundColor: Colors.white24,
                        valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _saving ? 'Sauvegarde... 60%' : 'Texture : ${(_stableSinceMs != null ? (_stableDurationMs / 20).toStringAsFixed(0) : '0')}%',
                      style: const TextStyle(color: Colors.greenAccent, fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Icon(_saving ? Icons.hourglass_top : Icons.camera_alt,
                      color: _capturing ? Colors.amber : Colors.white54, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      _saving ? 'Sauvegarde de la cartographie...'
                      : _capturing
                          ? (_presenceRatio < 0.72
                              ? 'Place l\'objet dans la zone\n(net: ${(_presenceRatio * 100).toStringAsFixed(0)}%)'
                              : 'Scanne le fond poncé\nMaintiens l\'objet immobile')
                          : 'Préparation...',
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (_capturing) ...[
                      const SizedBox(height: 6),
                      Text('Points: $_featureCount détectés, ${_bestKps.length} suivis',
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      if (_stableSinceMs != null) ...[
                        const SizedBox(height: 4),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(4),
                          child: LinearProgressIndicator(
                            value: (_stableDurationMs / 2000).clamp(0.0, 1.0),
                            minHeight: 6, backgroundColor: Colors.white24,
                            valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                          ),
                        ),
                        Text('Stabilisation... ${(_stableDurationMs / 20).toStringAsFixed(0)}%',
                          style: const TextStyle(color: Colors.greenAccent, fontSize: 12)),
                      ],
                      Text('Zoom: ${_zoom.toStringAsFixed(1)}x (${_minZoom.toStringAsFixed(1)}-${_maxZoom.toStringAsFixed(1)})',
                        style: const TextStyle(color: Colors.white54, fontSize: 11)),
                      Text('Netteté: ${_liveSharpness.toStringAsFixed(1)} | Calib: $_calibPct% | Floues: $_skippedBlurry',
                        style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    ],
                  ]),
                ),
                const SizedBox(height: 32),
              ]),
            ])),
    );
  }
}

class _KeypointPainter extends CustomPainter {
  final List<Map<String, double>> allKps;
  final List<Map<String, double>> bestKps;
  final int imageWidth, imageHeight, sensorOrientation;
  _KeypointPainter({required this.allKps, required this.bestKps, required this.imageWidth, required this.imageHeight, required this.sensorOrientation});

  @override
  void paint(Canvas canvas, Size size) {
    if (allKps.isEmpty) return;
    final bool rotated = sensorOrientation == 90 || sensorOrientation == 270;
    final double scaleX = size.width / (rotated ? imageHeight : imageWidth);
    final double scaleY = size.height / (rotated ? imageWidth : imageHeight);
    final double scale = scaleX < scaleY ? scaleX : scaleY;
    final double dispW = (rotated ? imageHeight : imageWidth) * scale;
    final double dispH = (rotated ? imageWidth : imageHeight) * scale;
    final double offsetX = (size.width - dispW) / 2;
    final double offsetY = (size.height - dispH) / 2;
    final bestSet = bestKps.map((b) => '${(b['x']! * 10).round()},${(b['y']! * 10).round()}').toSet();

    for (final kp in allKps) {
      double px, py;
      if (sensorOrientation == 90) { px = kp['y']! * scale + offsetX; py = (imageWidth - kp['x']!) * scale + offsetY; }
      else if (sensorOrientation == 270) { px = (imageHeight - kp['y']!) * scale + offsetX; py = kp['x']! * scale + offsetY; }
      else if (sensorOrientation == 180) { px = (imageWidth - kp['x']!) * scale + offsetX; py = (imageHeight - kp['y']!) * scale + offsetY; }
      else { px = kp['x']! * scale + offsetX; py = kp['y']! * scale + offsetY; }
      final isBest = bestSet.contains('${(kp['x']! * 10).round()},${(kp['y']! * 10).round()}');
      canvas.drawCircle(Offset(px, py), isBest ? 6.0 : 3.0, Paint()..color = isBest ? Colors.red : Colors.white.withOpacity(0.5)..style = PaintingStyle.fill);
      if (isBest) canvas.drawCircle(Offset(px, py), 9.0, Paint()..color = Colors.red.withOpacity(0.5)..style = PaintingStyle.stroke..strokeWidth = 2.5);
    }
  }
  @override bool shouldRepaint(covariant _KeypointPainter oldDelegate) => true;
}

class _ObjectSpotlight extends CustomPainter {
  final Rect rect;
  final int imageWidth, imageHeight, sensorOrientation;
  _ObjectSpotlight({required this.rect, required this.imageWidth, required this.imageHeight, required this.sensorOrientation});

  @override
  void paint(Canvas canvas, Size size) {
    final bool rotated = sensorOrientation == 90 || sensorOrientation == 270;
    final double scaleX = size.width / (rotated ? imageHeight : imageWidth);
    final double scaleY = size.height / (rotated ? imageWidth : imageHeight);
    final double scale = scaleX < scaleY ? scaleX : scaleY;
    final double dispW = (rotated ? imageHeight : imageWidth) * scale;
    final double dispH = (rotated ? imageWidth : imageHeight) * scale;
    final double offsetX = (size.width - dispW) / 2;
    final double offsetY = (size.height - dispH) / 2;

    double rx, ry, rw, rh;
    if (sensorOrientation == 90) {
      rx = rect.top * scale + offsetX; ry = (imageWidth - rect.right) * scale + offsetY;
      rw = rect.height * scale; rh = rect.width * scale;
    } else if (sensorOrientation == 270) {
      rx = (imageHeight - rect.bottom) * scale + offsetX; ry = rect.left * scale + offsetY;
      rw = rect.height * scale; rh = rect.width * scale;
    } else if (sensorOrientation == 180) {
      rx = (imageWidth - rect.right) * scale + offsetX; ry = (imageHeight - rect.bottom) * scale + offsetY;
      rw = rect.width * scale; rh = rect.height * scale;
    } else {
      rx = rect.left * scale + offsetX; ry = rect.top * scale + offsetY;
      rw = rect.width * scale; rh = rect.height * scale;
    }

    final dimPaint = Paint()..color = Colors.black.withOpacity(0.45);
    final borderPaint = Paint()..color = Colors.greenAccent.withOpacity(0.6)..style = PaintingStyle.stroke..strokeWidth = 2;

    // 4 rectangles autour de la zone objet
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, ry), dimPaint); // top
    canvas.drawRect(Rect.fromLTWH(0, ry + rh, size.width, size.height - ry - rh), dimPaint); // bottom
    canvas.drawRect(Rect.fromLTWH(0, ry, rx, rh), dimPaint); // left
    canvas.drawRect(Rect.fromLTWH(rx + rw, ry, size.width - rx - rw, rh), dimPaint); // right
    canvas.drawRect(Rect.fromLTWH(rx, ry, rw, rh), borderPaint);
  }
  @override bool shouldRepaint(covariant _ObjectSpotlight oldDelegate) => true;
}

class _CircleGuidePainter extends CustomPainter {
  const _CircleGuidePainter();
  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2, cy = size.height / 2, radius = (cx < cy ? cx : cy);
    final paint = Paint()..color = Colors.white38..style = PaintingStyle.stroke..strokeWidth = 2.5;
    canvas.drawCircle(Offset(cx, cy), radius, paint);
    final tickPaint = Paint()..color = Colors.white24..style = PaintingStyle.stroke..strokeWidth = 1;
    for (final angle in [0.0, 90.0, 180.0, 270.0]) {
      final rad = angle * (3.14159 / 180.0);
      final dx = radius * cos(rad), dy = radius * sin(rad);
      canvas.drawLine(Offset(cx + dx * 0.9, cy + dy * 0.9), Offset(cx + dx * 1.1, cy + dy * 1.1), tickPaint);
    }
  }
  @override bool shouldRepaint(covariant _CircleGuidePainter oldDelegate) => false;
}
