import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:provider/provider.dart';
import '../services/egg_base_identity.dart';
import '../services/api_client.dart';
import '../services/texture_extraction.dart';
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
  bool _capturing = false;

  double _currentScore = 0;
  int _currentMatchCount = 0;
  double _peakScore = 0;
  int _stableCount = 0;
  static const int _stableThreshold = 3;
  static const double _authThreshold = 0.25;

  final List<double> _scoreHistory = [];
  static const int _historySize = 5;

  int _snapshotsTaken = 0;
  int _liveFeatureCount = 0;

  List<_EggCandidate> _candidates = [];
  _EggCandidate? _bestCandidate;
  Timer? _snapshotTimer;

  bool _seriesSelected = false;
  int? _selectedSeries;

  @override
  Widget build(BuildContext context) {
    if (!_seriesSelected) return _buildSeriesPicker();
    return _buildScanScreen();
  }

  Widget _buildSeriesPicker() {
    return Scaffold(
      appBar: AppBar(title: const Text('Vérifier un œuf')),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search, size: 64, color: Colors.green),
            const SizedBox(height: 24),
            const Text('Quelle série ?', style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            const Text('Choisissez le numéro de série de l\'œuf à vérifier'),
            const SizedBox(height: 32),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [2, 5, 10, 20].map((s) => Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    minimumSize: const Size(72, 72),
                    textStyle: const TextStyle(fontSize: 22, fontWeight: FontWeight.bold),
                  ),
                  onPressed: () => _onSeriesChosen(s),
                  child: Text('$s'),
                ),
              )).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _onSeriesChosen(int series) async {
    setState(() {
      _selectedSeries = series;
      _seriesSelected = true;
    });
    await _loadIdentities(series);
  }

  Widget _buildScanScreen() {
    if (_noIdentity) {
      return Scaffold(
        appBar: AppBar(title: Text('Série ${_selectedSeries}')),
        body: Center(
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
        ),
      );
    }

    if (_error != null) {
      return Scaffold(
        appBar: AppBar(title: Text('Série ${_selectedSeries}')),
        body: Center(child: SelectableText(_error!, style: const TextStyle(color: Colors.red))),
      );
    }

    if (!_ready || _controller == null) {
      return Scaffold(
        appBar: AppBar(title: Text('Série ${_selectedSeries}')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      appBar: AppBar(title: Text(_bestCandidate != null ? '${_bestCandidate!.display}' : 'Série ${_selectedSeries}')),
      body: Stack(
        fit: StackFit.expand,
        children: [
          CameraPreview(_controller!),
          _buildCircleGuide(),
          _buildScoreOverlay(),
        ],
      ),
    );
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
    if (_done || _candidates.isEmpty || _capturing || _controller == null) return;
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

      // Match against all candidates, find best
      _EggCandidate? best;
      MatchResult? bestResult;
      for (final c in _candidates) {
        final result = matchAgainstIdentity(features, c.identity);
        if (bestResult == null || result.score > bestResult.score) {
          best = c;
          bestResult = result;
        }
      }
      features.dispose();

      if (bestResult == null || best == null) {
        _capturing = false;
        if (wasStreaming && mounted) await _controller!.startImageStream((_) {});
        return;
      }

      _bestCandidate = best;
      _snapshotsTaken++;

      _scoreHistory.add(bestResult.score);
      if (_scoreHistory.length > _historySize) _scoreHistory.removeAt(0);
      final smoothed =
          _scoreHistory.reduce((a, b) => a + b) / _scoreHistory.length;

      _currentScore = smoothed;
      _currentMatchCount = bestResult.matchCount;
      if (smoothed > _peakScore) _peakScore = smoothed;

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
                  _bestCandidate!.display,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Score: ${(_currentScore * 100).toStringAsFixed(0)}%',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                Text(
                  '$_currentMatchCount points matchés',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                Text(
                  '$_snapshotsTaken snapshots analysés',
                  style: TextStyle(color: Colors.grey[500], fontSize: 12),
                ),
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

  Future<void> _loadIdentities(int series) async {
    try {
      final api = context.read<ApiClient>();
      final list = await api.getList('/egg-identity/?series_value=$series');
      final candidates = <_EggCandidate>[];
      for (final item in list) {
        final m = item as Map<String, dynamic>;
        final serverId = m['id'] as String;
        final display = m['display_number'] as String? ?? serverId;
        // The list endpoint doesn't include identity_data, fetch detail
        Map<String, dynamic>? identityData;
        try {
          final detail = await api.get('/egg-identity/$serverId');
          identityData = detail['identity_data'] as Map<String, dynamic>?;
        } catch (_) {}
        if (identityData == null) continue;
        try {
          final id = EggBaseIdentity.fromJson(identityData);
          candidates.add(_EggCandidate(serverId: serverId, display: display, identity: id));
        } catch (_) {}
      }
      if (candidates.isEmpty) {
        setState(() {
          _noIdentity = true;
          _error = 'Aucun œuf série $series trouvé sur le serveur.';
        });
        return;
      }
      setState(() => _candidates = candidates);
      _initCamera();
    } catch (e) {
      setState(() {
        _noIdentity = true;
        _error = 'Erreur chargement: $e';
      });
    }
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
                '$_currentMatchCount points',
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

class _EggCandidate {
  final String serverId;
  final String display;
  final EggBaseIdentity identity;
  _EggCandidate({required this.serverId, required this.display, required this.identity});
}
