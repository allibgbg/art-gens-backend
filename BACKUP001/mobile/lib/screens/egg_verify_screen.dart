import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import '../services/egg_base_identity.dart';
import '../services/texture_extraction.dart';
import '../services/error_reporter.dart';
import '../services/debug_console.dart';

/// Écran de vérification : preview caméra en continu, mais le SIFT
/// est extrait sur des photos plein résolution (takePicture) pour
/// matcher à la même échelle que l'enrollment.
class EggVerifyScreen extends StatefulWidget {
  const EggVerifyScreen({super.key});

  @override
  State<EggVerifyScreen> createState() => _EggVerifyScreenState();
}

class _EggVerifyScreenState extends State<EggVerifyScreen> {
  CameraController? _controller;
  bool _ready = false;
  String? _error;

  bool _done = false;
  bool _noIdentity = false;
  bool _capturing = false; // true pendant takePicture()

  // Score tracking
  double _currentScore = 0;
  int _currentMatchCount = 0;
  double _peakScore = 0;
  int _stableCount = 0;
  static const int _stableThreshold = 3;
  static const double _authThreshold = 0.25;

  // History for smoothing
  final List<double> _scoreHistory = [];
  static const int _historySize = 5;

  int _snapshotsTaken = 0;
  int _liveFeatureCount = 0;

  EggBaseIdentity? _identity;
  Timer? _snapshotTimer;

  @override
  void initState() {
    super.initState();
    _loadIdentity();
  }

  Future<void> _loadIdentity() async {
    final id = await EggBaseIdentity.load();
    if (id == null) {
      setState(() {
        _noIdentity = true;
        _error = 'Aucune carte d\'identité enregistrée.\n'
            'Enregistrez d\'abord un œuf via "Scanner la base".';
      });
      return;
    }
    setState(() => _identity = id);
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

    try {
      _controller = CameraController(
        cam,
        ResolutionPreset.high,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();
      try {
        final minZ = await _controller!.getMinZoomLevel();
        final maxZ = await _controller!.getMaxZoomLevel();
        await _controller!.setZoomLevel(1.3.clamp(minZ, maxZ));
        await _controller!.setFocusPoint(const Offset(0.5, 0.5));
      } catch (_) {}
      if (mounted) {
        setState(() => _ready = true);
        _startSnapshotLoop();
      }
    } catch (e) {
      setState(() => _error = 'Erreur caméra: $e');
    }
  }

  /// Tourne la preview + prend une snapshot haute rés toutes les ~1.2s
  void _startSnapshotLoop() {
    _snapshotTimer = Timer.periodic(const Duration(milliseconds: 1200), (_) {
      _takeSnapshot();
    });
    // Première immédiatement
    _takeSnapshot();
  }

  Future<void> _takeSnapshot() async {
    if (_done || _identity == null || _capturing || _controller == null) return;
    if (!_controller!.value.isInitialized) return;

    _capturing = true;
    try {
      // Stop stream temporairement pour takePicture
      final wasStreaming = _controller!.value.isStreamingImages;
      if (wasStreaming) await _controller!.stopImageStream();

      final xfile = await _controller!.takePicture();
      final bytes = await xfile.readAsBytes();

      // Decode grayscale plein résolution (comme enrollment)
      final gray = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
      if (gray.cols <= 0 || gray.rows <= 0) {
        gray.dispose();
        _capturing = false;
        if (wasStreaming && mounted) await _controller!.startImageStream((_) {});
        return;
      }

      // Crop centre (même logique que enrollment)
      final screen = MediaQuery.of(context).size;
      final region = centerCropRegion(
        imgW: gray.cols.toDouble(),
        imgH: gray.rows.toDouble(),
        screenWidth: screen.width,
        screenHeight: screen.height,
      );
      final side = (region.radius * 2).round();
      final x = (region.cx - region.radius).round().clamp(0, gray.cols - 1);
      final y = (region.cy - region.radius).round().clamp(0, gray.rows - 1);
      final cw = side.clamp(1, gray.cols - x);
      final ch = side.clamp(1, gray.rows - y);
      final cropped = gray.region(cv.Rect(x, y, cw, ch));

      // SIFT plein résolution
      final features = extractFromMat(cropped);
      cropped.dispose();
      gray.dispose();

      if (features == null || features.count < 10) {
        features?.dispose();
        _capturing = false;
        if (wasStreaming && mounted) await _controller!.startImageStream((_) {});
        return;
      }

      _liveFeatureCount = features.count;

      // Match
      final result = matchAgainstIdentity(features, _identity!);
      features.dispose();

      _snapshotsTaken++;

      // Smoothing
      _scoreHistory.add(result.score);
      if (_scoreHistory.length > _historySize) _scoreHistory.removeAt(0);
      final smoothed =
          _scoreHistory.reduce((a, b) => a + b) / _scoreHistory.length;

      _currentScore = smoothed;
      _currentMatchCount = result.matchCount;
      if (smoothed > _peakScore) _peakScore = smoothed;

      // Stable counting
      if (smoothed >= _authThreshold) {
        _stableCount++;
      } else {
        _stableCount = math.max(0, _stableCount - 1);
      }

      if (_stableCount >= _stableThreshold && !_done) {
        await _confirmAuthentic();
        return;
      }

      if (mounted) setState(() {});

      // Restart stream
      if (wasStreaming && mounted && !_done) {
        await _controller!.startImageStream((_) {});
      }
    } catch (e) {
      debugConsole.logError(e, source: 'egg-verify-snapshot');
    }
    _capturing = false;
  }

  Future<void> _confirmAuthentic() async {
    if (_done) return;
    setState(() {
      _done = true;
    });

    _snapshotTimer?.cancel();
    final cam = _controller;
    _controller = null;
    try { await cam?.stopImageStream(); } catch (_) {}
    await cam?.dispose();

    if (mounted) {
      await showDialog(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
          icon: const Icon(Icons.check_circle, color: Colors.green, size: 64),
          title: const Text('Authentique'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  'Score: ${(_currentScore * 100).toStringAsFixed(0)}%',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  '$_currentMatchCount/${_identity!.points.length} points matchés',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                Text(
                  '$_snapshotsTaken snapshots analysés',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
                if (_identity!.series != null) ...[
                  const SizedBox(height: 8),
                  Text('Série: ${_identity!.series}'),
                ],
                if (_identity!.digitNumber != null)
                  Text('Numéro: ${_identity!.digitNumber}'),
              ],
            ),
          ),
          actions: [
            FilledButton(
              onPressed: () {
                Navigator.pop(context);
                Navigator.pop(context);
              },
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  void dispose() {
    _snapshotTimer?.cancel();
    _controller?.stopImageStream();
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Vérifier un œuf')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_noIdentity) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.info_outline, size: 48, color: Colors.orange),
              const SizedBox(height: 16),
              SelectableText(_error!, textAlign: TextAlign.center),
            ],
          ),
        ),
      );
    }

    if (_error != null) {
      return Center(
        child: SelectableText(_error!, style: const TextStyle(color: Colors.red)),
      );
    }

    if (!_ready || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        CameraPreview(_controller!),
        _buildCircleGuide(),
        _buildScoreOverlay(),
      ],
    );
  }

  Widget _buildCircleGuide() {
    return Center(
      child: Container(
        width: 280,
        height: 280,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: _done
                ? Colors.green
                : _currentScore >= _authThreshold
                    ? Colors.greenAccent
                    : Colors.white38,
            width: 3,
          ),
        ),
      ),
    );
  }

  Widget _buildScoreOverlay() {
    final pct = (_currentScore * 100).toStringAsFixed(0);
    final color = _currentScore >= _authThreshold
        ? Colors.greenAccent
        : _currentScore >= _authThreshold * 0.5
            ? Colors.amber
            : Colors.white70;

    return Positioned(
      bottom: 32,
      left: 16,
      right: 16,
      child: Card(
        color: Colors.black54,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$pct%',
                style: TextStyle(
                  color: color,
                  fontSize: 42,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                '$_currentMatchCount/${_identity?.points.length ?? 120} points',
                style: const TextStyle(color: Colors.white70, fontSize: 13),
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _currentScore.clamp(0.0, 1.0),
                backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation(color),
                minHeight: 4,
              ),
              const SizedBox(height: 6),
              Text(
                _done
                    ? 'Authentique !'
                    : 'Live: $_liveFeatureCount | '
                        'Pic: ${(_peakScore * 100).toStringAsFixed(0)}% | '
                        'Stable: $_stableCount/$_stableThreshold | '
                        'Snap: $_snapshotsTaken',
                style: const TextStyle(color: Colors.white54, fontSize: 10),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
