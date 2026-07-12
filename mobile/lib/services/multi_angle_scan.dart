import 'dart:async';
import 'package:camera/camera.dart';
import 'color_extraction.dart';
import 'texture_extraction.dart';

typedef ScanProgressCallback = void Function(double coverage, double confidence);

typedef ScanSharpnessCallback = void Function(
    double qs, double max, int calibPct, int skipped, int total);

class ScanResult {
  final Map<String, dynamic> spatialSignature;
  final double coverage;
  final double confidence;
  final int framesProcessed;

  ScanResult(this.spatialSignature, this.coverage, this.confidence, this.framesProcessed);
}

class MultiAngleScanner {
  final CameraController _camera;
  bool _running = false;
  int _frameCount = 0;
  int _skippedBlurry = 0;
  final CoverageTracker _tracker;
  final AdaptiveSharpnessGate _sharpnessGate = AdaptiveSharpnessGate();
  Completer<ScanResult>? _completer;

  ScanProgressCallback? onProgress;
  ScanSharpnessCallback? onSharpness;

  MultiAngleScanner(this._camera, {int gridRows = 4, int gridCols = 4})
      : _tracker = CoverageTracker(gridRows, gridCols);

  bool get running => _running;
  double get coverage => _tracker.coverage;
  double get confidence => _tracker.confidence;
  int get framesProcessed => _frameCount;
  int get skippedBlurry => _skippedBlurry;
  bool get isComplete => _tracker.isStable && _tracker.confidence >= 0.6 && _tracker.coverage >= 0.8;

  /// Scan « éternel » : le flux ne s'arrête que lorsque la couverture
  /// suffisante (isComplete) est atteinte. Aucun timeout ni cap de frames.
  Future<ScanResult> start() async {
    _tracker.reset();
    _sharpnessGate.reset();
    _frameCount = 0;
    _skippedBlurry = 0;
    _running = true;
    _completer = Completer<ScanResult>();

    try {
      await _camera.startImageStream(_onImage);
    } catch (e) {
      _finish();
      throw Exception('Erreur démarrage flux caméra: $e');
    }

    return _completer!.future;
  }

  void _onImage(CameraImage image) {
    if (!_running) return;

    final qs = quickSharpness(image);
    if (!_sharpnessGate.isSharp(qs)) {
      _skippedBlurry++;
      onSharpness?.call(qs, _sharpnessGate.maxSeen,
          _sharpnessGate.calibrationProgress, _skippedBlurry, _frameCount);
      return;
    }

    _frameCount++;
    final sig = SpatialSignature.extract(image);
    final cov = _tracker.addFrame(sig);
    onSharpness?.call(qs, _sharpnessGate.maxSeen,
        _sharpnessGate.calibrationProgress, _skippedBlurry, _frameCount);
    onProgress?.call(cov, _tracker.confidence);

    if (isComplete) {
      _finish();
    }
  }

  void _finish() {
    if (!_running) return;
    _running = false;
    try { _camera.stopImageStream(); } catch (_) {}
    if (_completer != null && !_completer!.isCompleted) {
      _completer!.complete(_buildResult());
    }
  }

  ScanResult _buildResult() {
    return ScanResult(
      _tracker.toSignatureJson(),
      _tracker.coverage,
      _tracker.confidence,
      _frameCount,
    );
  }

  void cancel() {
    _finish();
  }
}
