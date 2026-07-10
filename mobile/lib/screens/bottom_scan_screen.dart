import 'dart:async';
import 'dart:math';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/texture_extraction.dart';
import '../services/api_client.dart';
import '../providers/auth_provider.dart';
import '../providers/pieces_provider.dart';
import 'package:provider/provider.dart';

/// Phase 2 : scan du fond poncé pour extraction de texture.
/// Reçoit la signature couleur via [colorSignature] (optionnel, pré-tri).
class BottomScanScreen extends StatefulWidget {
  final Map<String, dynamic>? colorSignature;
  final String? topImageBase64;

  const BottomScanScreen({super.key, this.colorSignature, this.topImageBase64});

  @override
  State<BottomScanScreen> createState() => _BottomScanScreenState();
}

class _BottomScanScreenState extends State<BottomScanScreen> {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _capturing = false;
  bool _saving = false;
  double _liveSharpness = 0.0;
  double _maxSharpness = 0.0;
  int _calibPct = 0;
  int _featureCount = 0;
  int _skippedBlurry = 0;
  TextureFrame? _capturedFrame;
  late TextureExtractor _extractor;
  String? _error;
  int _sensorOrientation = 0;

  // Overlay keypoints from latest extraction
  List<Map<String, double>>? _displayKps;
  int _lastImageW = 0;
  int _lastImageH = 0;

  // Stability tracking for auto-validation
  int? _stableSinceMs;
  int _stableDurationMs = 0;

  List<Map<String, double>> get _bestKps {
    final list = _displayKps;
    if (list == null || list.isEmpty) return [];
    if (list.length <= 7) return list;
    final sorted = List<Map<String, double>>.from(list)
      ..sort((a, b) => (b['response'] ?? 0).compareTo(a['response'] ?? 0));
    return sorted.take(7).toList();
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
    try {
      final controller = CameraController(cameras.first, ResolutionPreset.medium);
      await controller.initialize();
      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
          _error = null;
          _sensorOrientation = cameras.first.sensorOrientation;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur caméra: $e');
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

    // Copie les dimensions pour la couche de visualisation
    _lastImageW = image.width;
    _lastImageH = image.height;

    final frame = _extractor.extract(image, logErrors: true);

    if (frame == null) {
      if (mounted) {
        setState(() {
          _liveSharpness = rawQs;
          _maxSharpness = gate.maxSeen;
          _calibPct = gate.calibrationProgress;
          _skippedBlurry++;
        });
      }
      return;
    }

    // Copie les données des keypoints pour l'affichage (sécurité : dispose()
    // du frame libère la mémoire OpenCV, on garde une copie Dart)
    final kpDisplay = frame.keypoints.map((kp) => <String, double>{
      'x': kp.x, 'y': kp.y, 'response': kp.response,
    }).toList();

    setState(() {
      _liveSharpness = rawQs;
      _maxSharpness = gate.maxSeen;
      _calibPct = gate.calibrationProgress;
      _featureCount = frame.keypoints.length;
      _displayKps = kpDisplay;
    });

    if (frame.keypoints.length >= 7) {
      final now = DateTime.now().millisecondsSinceEpoch;
      if (_stableSinceMs == null) {
        // Première frame stable : on conserve ce frame pour l'envoi serveur
        _stableSinceMs = now;
        _capturedFrame?.dispose();
        _capturedFrame = frame;
      } else {
        // Mise à jour du frame capturé pour avoir les keypoints les plus récents
        _capturedFrame?.dispose();
        _capturedFrame = frame;
      }

      setState(() {
        _stableDurationMs = now - _stableSinceMs!;
      });

      if (_stableDurationMs >= 2000) {
        _autoValidate();
      }
    } else {
      _stableSinceMs = null;
      _stableDurationMs = 0;
      frame.dispose();
    }
  }

  void _autoValidate() {
    _capturing = false;
    try {
      _cameraController?.stopImageStream();
    } catch (_) {}
    _validate();
  }

  Future<void> _validate() async {
    if (_capturedFrame == null) return;
    setState(() => _saving = true);

    final api = context.read<ApiClient>();
    final user = context.read<AuthProvider>();

    try {
      final descMat = _capturedFrame!.descriptors;
      final descRows = descMat.rows;
      final descCols = descMat.cols;
      final descData = <List<int>>[];
      for (int i = 0; i < descRows; i++) {
        final row = <int>[];
        for (int j = 0; j < descCols; j++) {
          row.add(descMat.atU8(i, i1: j));
        }
        descData.add(row);
      }

      final kpData = _capturedFrame!.keypoints
          .map((kp) => {'x': kp.x, 'y': kp.y})
          .toList();

      final body = {
        'display_number': '${user.user?.pseudo.toUpperCase() ?? 'ART'}-${DateTime.now().millisecondsSinceEpoch}',
        'series_value': 1,
        'reference_pinceaux_value': 100,
        'color_primary': 'multicolore',
        'color_secondary': null,
        'color_signature': widget.colorSignature,
        'texture_signature': {
          'descriptors': descData,
          'keypoints': kpData,
          'keypoints_count': _capturedFrame!.keypoints.length,
          'sharpness': _capturedFrame!.sharpness,
        },
        'top_image': widget.topImageBase64,
        'material_notes': null,
        'artist_note': 'Scan complet (dessus + fond poncé)',
      };

      await api.post('/pieces/', body: body);
      await context.read<PiecesProvider>().loadMyPieces();

      if (mounted) {
        setState(() => _saving = false);
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
      }
    }
  }

  void _retake() {
    _capturedFrame?.dispose();
    setState(() {
      _capturedFrame = null;
      _featureCount = 0;
      _liveSharpness = 0.0;
      _displayKps = null;
      _stableSinceMs = null;
      _stableDurationMs = 0;
    });
    _startCapture();
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
          : LayoutBuilder(
              builder: (context, constraints) => Stack(
                children: [
                  if (_isCameraReady && _cameraController != null)
                    CameraPreview(_cameraController!),
                  if (!_isCameraReady && _error == null)
                    const Center(child: CircularProgressIndicator()),

                  // Overlay des keypoints en direct
                  if (_displayKps != null && _capturing)
                    CustomPaint(
                      size: Size(constraints.maxWidth, constraints.maxHeight),
                      painter: _KeypointPainter(
                        allKps: _displayKps!,
                        bestKps: _bestKps,
                        imageWidth: _lastImageW,
                        imageHeight: _lastImageH,
                        sensorOrientation: _sensorOrientation,
                      ),
                    ),

                  // Cercle guide (centré)
                  if (_capturing)
                    Center(
                      child: SizedBox(
                        width: MediaQuery.of(context).size.width * 0.7,
                        height: MediaQuery.of(context).size.width * 0.7,
                        child: CustomPaint(
                          painter: _CircleGuidePainter(),
                        ),
                      ),
                    ),

                  // Panneau du bas
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
                            Icon(
                              _saving ? Icons.hourglass_top : Icons.camera_alt,
                              color: _saving
                                  ? Colors.amber
                                  : _capturing
                                      ? Colors.amber
                                      : Colors.white54,
                              size: 48,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              _saving
                                  ? 'Enregistrement...'
                                  : _capturing
                                      ? 'Maintiens l\'objet immobile\nface à la caméra'
                                      : 'Scanne le fond poncé',
                              textAlign: TextAlign.center,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 20,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            const SizedBox(height: 8),
                            if (_capturing) ...[
                              _sharpnessIndicator(),
                              Text(
                                'Netteté: ${_liveSharpness.toStringAsFixed(1)} (max: ${_maxSharpness.toStringAsFixed(1)}) | Calib: $_calibPct% | Floues: $_skippedBlurry',
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'Points: $_featureCount détectés, ${_bestKps.length} suivis',
                                style: const TextStyle(color: Colors.white70, fontSize: 14),
                              ),
                              if (_stableSinceMs != null) ...[
                                const SizedBox(height: 6),
                                ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: LinearProgressIndicator(
                                    value: (_stableDurationMs / 2000).clamp(0.0, 1.0),
                                    minHeight: 6,
                                    backgroundColor: Colors.white24,
                                    valueColor: const AlwaysStoppedAnimation<Color>(Colors.green),
                                  ),
                                ),
                                Text(
                                  'Vérification... ${(_stableDurationMs / 20).toStringAsFixed(0)}%',
                                  style: const TextStyle(color: Colors.greenAccent, fontSize: 13),
                                ),
                              ],
                              if (_featureCount > 0 && _stableSinceMs == null)
                                Padding(
                                  padding: const EdgeInsets.only(top: 6),
                                  child: LinearProgressIndicator(
                                    value: (_featureCount / 30).clamp(0.0, 1.0),
                                    backgroundColor: Colors.white24,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      _featureCount >= 7 ? Colors.green : Colors.amber,
                                    ),
                                  ),
                                ),
                            ],
                            const SizedBox(height: 16),
                            if (!_capturing && !_saving)
                              SizedBox(
                                width: double.infinity,
                                child: ElevatedButton.icon(
                                  onPressed: _startCapture,
                                  icon: const Icon(Icons.camera_alt),
                                  label: const Text('Scanner le fond'),
                                  style: ElevatedButton.styleFrom(
                                    padding: const EdgeInsets.symmetric(vertical: 14),
                                  ),
                                ),
                              ),
                            if (_saving)
                              const SizedBox(
                                width: 24,
                                height: 24,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 32),
                    ],
                  ),
                ],
              ),
            ),
    );
  }

  Widget _sharpnessIndicator() {
    final gate = _extractor.sharpnessGate;
    final isSharp = gate.isSharp(_liveSharpness);
    // Même seuil effectif que le vrai gate : max(_maxSeen * ratio, absoluteMin)
    final effectiveThreshold = gate.maxSeen * gate.ratio > gate.absoluteMin
        ? gate.maxSeen * gate.ratio
        : gate.absoluteMin;
    final displayMax = effectiveThreshold > 0 ? effectiveThreshold * 1.8 : 10.0;
    final val = (_liveSharpness / displayMax).clamp(0.0, 1.0);
    return Column(
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: val,
            minHeight: 12,
            backgroundColor: Colors.white24,
            valueColor: AlwaysStoppedAnimation<Color>(
              isSharp ? Colors.green : Colors.red,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Netteté: ${_liveSharpness.toStringAsFixed(1)}',
          style: TextStyle(
            color: isSharp ? Colors.greenAccent : Colors.redAccent,
            fontSize: 14,
          ),
        ),
      ],
    );
  }
}

/// Peint les keypoints détectés superposés au flux caméra.
/// Les 7 meilleurs (par `response`, force du coin) sont mis en évidence.
class _KeypointPainter extends CustomPainter {
  final List<Map<String, double>> allKps;
  final List<Map<String, double>> bestKps;
  final int imageWidth;
  final int imageHeight;
  final int sensorOrientation;

  _KeypointPainter({
    required this.allKps,
    required this.bestKps,
    required this.imageWidth,
    required this.imageHeight,
    required this.sensorOrientation,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (allKps.isEmpty) return;

    // Détermine si l'image capturée doit être tournée pour correspondre à
    // l'affichage (sensorOrientation = rotation du capteur → portrait)
    final bool rotated = sensorOrientation == 90 || sensorOrientation == 270;

    // Échelle pour fitter l'image (potentiellement tournée) dans la preview
    final double scaleX = size.width / (rotated ? imageHeight : imageWidth);
    final double scaleY = size.height / (rotated ? imageWidth : imageHeight);
    final double scale = scaleX < scaleY ? scaleX : scaleY;

    final double dispW = (rotated ? imageHeight : imageWidth) * scale;
    final double dispH = (rotated ? imageWidth : imageHeight) * scale;
    final double offsetX = (size.width - dispW) / 2;
    final double offsetY = (size.height - dispH) / 2;

    // Ensemble des positions des best pour surlignage
    final bestSet = bestKps
        .map((b) => '${(b['x']! * 10).round()},${(b['y']! * 10).round()}')
        .toSet();

    for (final kp in allKps) {
      final double xRaw = kp['x']!;
      final double yRaw = kp['y']!;

      double px, py;
      if (sensorOrientation == 90) {
        // Capteur tourné de 90° : (x,y) → (y, H-x)
        px = yRaw * scale + offsetX;
        py = (imageWidth - xRaw) * scale + offsetY;
      } else if (sensorOrientation == 270) {
        px = (imageHeight - yRaw) * scale + offsetX;
        py = xRaw * scale + offsetY;
      } else if (sensorOrientation == 180) {
        px = (imageWidth - xRaw) * scale + offsetX;
        py = (imageHeight - yRaw) * scale + offsetY;
      } else {
        px = xRaw * scale + offsetX;
        py = yRaw * scale + offsetY;
      }

      final String key =
          '${(xRaw * 10).round()},${(yRaw * 10).round()}';
      final bool isBest = bestSet.contains(key);

      // Cercle de fond pour tous les points
      canvas.drawCircle(
        Offset(px, py),
        isBest ? 6.0 : 3.0,
        Paint()
          ..color = isBest ? Colors.red : Colors.white.withOpacity(0.5)
          ..style = PaintingStyle.fill,
      );

      // Cercle extérieur pour les meilleurs points
      if (isBest) {
        canvas.drawCircle(
          Offset(px, py),
          9.0,
          Paint()
            ..color = Colors.red.withOpacity(0.5)
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.5,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _KeypointPainter oldDelegate) => true;
}

class _CircleGuidePainter extends CustomPainter {
  const _CircleGuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final double cx = size.width / 2;
    final double cy = size.height / 2;
    final double radius = (cx < cy ? cx : cy) * 0.85;

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
      final dx = radius * cos(rad);
      final dy = radius * sin(rad);
      final inner = Offset(cx + dx * 0.9, cy + dy * 0.9);
      final outer = Offset(cx + dx * 1.1, cy + dy * 1.1);
      canvas.drawLine(inner, outer, tickPaint);
    }
  }

  @override
  bool shouldRepaint(covariant _CircleGuidePainter oldDelegate) => false;
}
