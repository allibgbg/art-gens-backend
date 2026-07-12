import 'dart:async';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import '../services/multi_angle_scan.dart';
import '../services/api_client.dart';
import 'package:provider/provider.dart';
import 'finalize_piece_screen.dart';

class RotationScanScreen extends StatefulWidget {
  final String pieceId;
  final String? digitGuess;
  const RotationScanScreen({super.key, required this.pieceId, this.digitGuess});

  @override
  State<RotationScanScreen> createState() => _RotationScanScreenState();
}

class _RotationScanScreenState extends State<RotationScanScreen> {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _scanning = false;
  bool _done = false;
  bool _saving = false;
  double _coverage = 0;
  double _confidence = 0;
  int _framesProcessed = 0;
  double _liveSharpness = 0;
  double _maxSharpness = 0;
  int _calibPct = 0;
  int _skippedBlurry = 0;
  MultiAngleScanner? _scanner;
  String? _error;
  ScanResult? _result;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) { setState(() => _error = 'Aucune caméra disponible'); return; }
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
        _startScan();
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = 'Erreur caméra: $e');
        Future.delayed(const Duration(seconds: 2), () { if (mounted) { setState(() => _error = null); _initCamera(); } });
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
    _scanner?.cancel();
    setState(() { _scanning = true; _done = false; _scanner = null; _error = null; });
    final scanner = MultiAngleScanner(_cameraController!, gridRows: 5, gridCols: 5);
    _scanner = scanner;

    scanner.onProgress = (cov, conf) {
      if (mounted) setState(() { _coverage = cov; _confidence = conf; });
    };
    scanner.onSharpness = (qs, max, calibPct, skipped, processed) {
      if (mounted) setState(() {
        _liveSharpness = qs; _maxSharpness = max; _calibPct = calibPct;
        _skippedBlurry = skipped; _framesProcessed = processed;
      });
    };

    try {
      _result = await scanner.start();
    } catch (_) { _result = null; }

    if (!mounted) return;

    final cov = _result?.coverage ?? 0;
    if (cov < 0.6) {
      setState(() {
        _scanning = false;
        _error = 'Couverture insuffisante (${(cov * 100).toStringAsFixed(0)}%) — continue à tourner l\'objet';
      });
      Future.delayed(const Duration(seconds: 1), () {
        if (mounted) { setState(() => _error = null); _startScan(); }
      });
      return;
    }

    if (mounted) {
      setState(() { _scanning = false; _done = true; });
      await Future.delayed(const Duration(seconds: 2));
      _saveAndNext();
    }
  }

  Future<void> _saveAndNext() async {
    if (_result == null) return;
    setState(() => _saving = true);
    try {
      final api = context.read<ApiClient>();
      await api.patch('/pieces/${widget.pieceId}', body: {
        'color_signature': _result!.spatialSignature,
      });
      if (mounted) {
        final cam = _cameraController;
        _cameraController = null;
        await cam?.dispose();
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => FinalizePieceScreen(
            pieceId: widget.pieceId, digitGuess: widget.digitGuess,
          )),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Erreur: $e')));
      }
    }
  }

  @override
  void dispose() { _cameraController?.dispose(); _scanner?.cancel(); super.dispose(); }

  double get _gaugeValue => _saving ? 1.0 : (_done ? 1.0 : 0.8 + _coverage * 0.2);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Phase 3 — Rotation complète')),
      body: _error != null
          ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
              Text(_error!, style: const TextStyle(color: Colors.red)),
              const SizedBox(height: 16),
              const CircularProgressIndicator(),
              const Text('Nouvelle tentative...', style: TextStyle(color: Colors.white54)),
            ]))
          : LayoutBuilder(builder: (_, constraints) => Stack(children: [
              if (_isCameraReady && _cameraController != null)
                GestureDetector(
                  onTapUp: (d) => _onTapFocus(d, constraints),
                  child: CameraPreview(_cameraController!),
                ),
              if (!_isCameraReady) const Center(child: CircularProgressIndicator()),
              Container(
                width: double.infinity, height: double.infinity,
                decoration: const BoxDecoration(
                  color: Color.fromRGBO(255, 255, 255, 0.15),
                ),
                child: Center(
                  child: Container(
                    width: 400, height: 400,
                    decoration: BoxDecoration(
                      color: Colors.transparent,
                      borderRadius: BorderRadius.circular(200),
                      border: Border.all(color: Colors.white, width: 3),
                    ),
                  ),
                ),
              ),
              Column(children: [
                const Spacer(),
                Container(
                  margin: const EdgeInsets.all(24), padding: const EdgeInsets.all(20),
                  decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(16)),
                  child: Column(children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(4),
                      child: LinearProgressIndicator(
                        value: _gaugeValue, minHeight: 16, backgroundColor: Colors.white24,
                        valueColor: AlwaysStoppedAnimation<Color>(
                          _done || _saving ? Colors.green : Colors.amber),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      _saving ? 'Finalisation... 100%'
                      : _done ? '100% — Rotation terminée !'
                      : 'Rotation : ${(_coverage * 100).toStringAsFixed(0)}%',
                      style: TextStyle(
                        color: _done || _saving ? Colors.greenAccent : Colors.white70,
                        fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                    const SizedBox(height: 12),
                    Icon(_saving ? Icons.hourglass_top : (_done ? Icons.check_circle : Icons.threesixty),
                      color: _done || _saving ? Colors.green : Colors.amber, size: 48),
                    const SizedBox(height: 8),
                    Text(
                      _saving ? 'Sauvegarde des motifs...'
                      : _done ? 'Données couleur suffisantes !'
                      : 'Tourne l\'objet sur lui-même\nface à la caméra (dans la zone centrale)',
                      style: const TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.bold),
                    ),
                    if (_scanning) ...[
                      const SizedBox(height: 6),
                      Text('Couverture: ${(_coverage * 100).toStringAsFixed(0)}% | Frames: $_framesProcessed',
                        style: const TextStyle(color: Colors.white70, fontSize: 13)),
                      Text('Netteté: ${_liveSharpness.toStringAsFixed(1)} | Calib: $_calibPct% | Floues: $_skippedBlurry',
                        style: const TextStyle(color: Colors.white54, fontSize: 11)),
                    ],
                    if (_done && !_saving) ...[
                      const SizedBox(height: 12),
                      Text('Finalisation...', style: TextStyle(color: Colors.greenAccent, fontSize: 14)),
                    ],
                  ]),
                ),
                const SizedBox(height: 32),
              ]),
            ])),
    );
  }
}
