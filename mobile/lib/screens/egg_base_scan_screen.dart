import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../providers/pieces_provider.dart';
import '../services/egg_base_identity.dart';
import '../services/texture_extraction.dart';
import '../services/error_reporter.dart';
import '../services/debug_console.dart';

/// Écran d'enrollment :
/// Étape 1 — Photo de face (image de profil de l'œuf)
/// Étape 2 — 3-5 photos de la base (SIFT identity)
/// Étape 3 — Formulaire série/numéro → sauvegarde locale + collection
class EggBaseScanScreen extends StatefulWidget {
  const EggBaseScanScreen({super.key});

  @override
  State<EggBaseScanScreen> createState() => _EggBaseScanScreenState();
}

class _EggBaseScanScreenState extends State<EggBaseScanScreen> {
  CameraController? _controller;
  bool _ready = false;
  String? _error;

  // Steps: 0=face, 1=base, 2=processing
  int _step = 0;

  // Face photo
  String? _facePhotoPath;

  // Base photos
  final List<String> _basePaths = [];
  final List<double> _sharpnessScores = [];
  final List<int> _featureCounts = []; // SIFT features per photo
  bool _busy = false;
  bool _processing = false;

  String? _dir;
  int _sensorOrientation = 0;
  double _screenW = 0, _screenH = 0;
  double _currentZoom = 1.0;
  double _zoomAtGestureStart = 1.0;
  double _maxZoom = 10.0;

  static const int _minBasePhotos = 3;
  static const int _maxBasePhotos = 5;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      _dir = '${dir.path}/ARTGENS';
      await Directory(_dir!).create(recursive: true);

      final cameras = await availableCameras();
      if (cameras.isEmpty) {
        setState(() => _error = 'Aucune caméra disponible');
        return;
      }
      final back = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _sensorOrientation = back.sensorOrientation;

      _controller = CameraController(
        back,
        ResolutionPreset.high,
        imageFormatGroup: ImageFormatGroup.yuv420,
      );
      await _controller!.initialize();
      try { _maxZoom = await _controller!.getMaxZoomLevel(); } catch (_) {}
      if (!mounted) return;
      setState(() => _ready = true);
    } catch (e) {
      setState(() => _error = e.toString());
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Capture
  // ---------------------------------------------------------------------------

  Future<void> _captureFace() async {
    if (_controller == null || !_busy) await _doCapture(isFace: true);
  }

  Future<void> _captureBase() async {
    if (_controller == null || _busy) return;
    await _doCapture(isFace: false);
  }

  Future<void> _doCapture({required bool isFace}) async {
    _busy = true;
    final streaming = _controller!.value.isStreamingImages;
    if (streaming) await _controller!.stopImageStream();

    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final xfile = await _controller!.takePicture();
      final bytes = await xfile.readAsBytes();

      final mat = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
      if (mat.cols <= 0 || mat.rows <= 0) {
        _busy = false;
        return;
      }

      String outPath;
      if (isFace) {
        outPath = '$_dir/face_$ts.jpg';
        final colorMat = cv.imdecode(bytes, 1);
        final cropped = _cropEgg(colorMat);
        cv.imwrite(outPath, cropped);
        cropped.dispose();
        colorMat.dispose();
        _facePhotoPath = outPath;
      } else {
        // Crop center for base
        final region = centerCropRegion(
          imgW: mat.cols.toDouble(),
          imgH: mat.rows.toDouble(),
          screenWidth: _screenW,
          screenHeight: _screenH,
        );
        final side = (region.radius * 2).round();
        final x = (region.cx - region.radius).round().clamp(0, mat.cols - 1);
        final y = (region.cy - region.radius).round().clamp(0, mat.rows - 1);
        final cw = side.clamp(1, mat.cols - x);
        final ch = side.clamp(1, mat.rows - y);
        final cropped = mat.region(cv.Rect(x, y, cw, ch));

        outPath = '$_dir/base_${ts}.jpg';
        cv.imwrite(outPath, cropped);

        // Count SIFT features
        final features = extractFromImage(outPath);
        final count = features?.count ?? 0;
        features?.dispose();

        cropped.dispose();

        final sharpness = quickSharpnessMat(mat);
        final isGood = sharpness > 50 && count > 200;

        if (_basePaths.length < _maxBasePhotos) {
          // Not full yet → just add
          _sharpnessScores.add(sharpness);
          _featureCounts.add(count);
          _basePaths.add(outPath);
        } else {
          // Full → find worst orange photo to replace
          int worstIdx = -1;
          double worstScore = double.infinity;
          for (int i = 0; i < _basePaths.length; i++) {
            final s = _sharpnessScores[i];
            final c = _featureCounts[i];
            final good = s > 50 && c > 200;
            if (!good) {
              final score = s * 0.5 + c * 0.01;
              if (score < worstScore) {
                worstScore = score;
                worstIdx = i;
              }
            }
          }

          if (worstIdx >= 0 && isGood) {
            // Replace worst orange with new good photo
            final oldPath = _basePaths[worstIdx];
            _basePaths[worstIdx] = outPath;
            _sharpnessScores[worstIdx] = sharpness;
            _featureCounts[worstIdx] = count;
            // Delete old file
            try { File(oldPath).deleteSync(); } catch (_) {}
          } else {
            // No orange to replace, or new photo is also bad → discard
            try { File(outPath).deleteSync(); } catch (_) {}
          }
        }
      }

      mat.dispose();
      if (mounted) setState(() {});
    } catch (e) {
      debugConsole.logError(e, source: isFace ? 'capture-face' : 'capture-base');
    }

    _busy = false;
    if (mounted && _controller!.value.isInitialized) {
      await _controller!.startImageStream((_) {});
    }
  }

  /// Post-prod : isole l'œuf sur fond blanc, 512×512.
  cv.Mat _cropEgg(cv.Mat colorMat) {
    try {
      final w = colorMat.cols;
      final h = colorMat.rows;

      // 1. Détection contour → trouver la zone de l'œuf
      final gray = cv.cvtColor(colorMat, cv.COLOR_BGR2GRAY);
      final blurred = cv.gaussianBlur(gray, (7, 7), 0);
      gray.dispose();
      final edges = cv.canny(blurred, 30, 80);
      blurred.dispose();
      final kernel = cv.getStructuringElement(cv.MORPH_ELLIPSE, (15, 15));
      final dilated = cv.dilate(edges, kernel);
      edges.dispose();
      kernel.dispose();

      final (contours, _) = cv.findContours(dilated, cv.RETR_EXTERNAL, cv.CHAIN_APPROX_SIMPLE);
      dilated.dispose();
      if (contours.isEmpty) return colorMat;

      final cx = w ~/ 2;
      final cy = h ~/ 2;
      int bestIdx = -1;
      double maxArea = 0;
      for (int i = 0; i < contours.length; i++) {
        final area = cv.contourArea(contours[i]);
        final r = cv.boundingRect(contours[i]);
        if (area > maxArea &&
            cx >= r.x && cx <= r.x + r.width &&
            cy >= r.y && cy <= r.y + r.height) {
          maxArea = area;
          bestIdx = i;
        }
      }
      if (bestIdx < 0) {
        for (int i = 0; i < contours.length; i++) {
          final area = cv.contourArea(contours[i]);
          if (area > maxArea) { maxArea = area; bestIdx = i; }
        }
      }
      if (bestIdx < 0 || maxArea < 1000) return colorMat;

      // 2. Masque drawContours FILLED, erodé pour supprimer le halo
      final mask = cv.Mat.zeros(h, w, cv.MatType.CV_8UC1);
      cv.drawContours(mask, contours, bestIdx, cv.Scalar.all(255), thickness: cv.FILLED);
      final erodeK = cv.getStructuringElement(cv.MORPH_ELLIPSE, (7, 7));
      final tightMask = cv.erode(mask, erodeK);
      mask.dispose();
      erodeK.dispose();

      // 3. Œuf seul sur fond noir (bitwiseAND avec masque)
      final eggOnBlack = cv.bitwiseAND(colorMat, colorMat, mask: tightMask);

      // 4. Masque inversé → blanc uniquement autour de l'œuf
      final (_, white1ch) = cv.threshold(
        cv.Mat.zeros(h, w, cv.MatType.CV_8UC1), 0, 255, cv.THRESH_BINARY);
      final invMask = cv.subtract(white1ch, tightMask);
      white1ch.dispose();
      tightMask.dispose();
      final whiteBgr = cv.cvtColor(invMask, cv.COLOR_GRAY2BGR);
      final bgWhite = cv.bitwiseAND(whiteBgr, whiteBgr, mask: invMask);
      invMask.dispose();
      whiteBgr.dispose();

      // 5. Combiner : œuf + fond blanc
      final white = cv.bitwiseOR(eggOnBlack, bgWhite);
      eggOnBlack.dispose();
      bgWhite.dispose();

      // 4. Crop tight au bounding rect
      final eggRect = cv.boundingRect(contours[bestIdx]);
      final pad = (eggRect.width * 0.03).round().clamp(2, 15);
      final rx = (eggRect.x - pad).clamp(0, w - 1);
      final ry = (eggRect.y - pad).clamp(0, h - 1);
      final rw = (eggRect.width + pad * 2).clamp(1, w - rx);
      final rh = (eggRect.height + pad * 2).clamp(1, h - ry);
      final cropped = white.region(cv.Rect(rx, ry, rw, rh));
      white.dispose();

      // 5. Resize + centrer sur 512×512
      final shortSide = rw < rh ? rw : rh;
      final scale = (512 * 0.90 / shortSide).clamp(0.1, 5.0);
      final nw = (rw * scale).round().clamp(1, 512);
      final nh = (rh * scale).round().clamp(1, 512);
      final resized = cv.resize(cropped, (nw, nh));
      cropped.dispose();

      final canvas = cv.cvtColor(
        cv.threshold(cv.Mat.zeros(512, 512, cv.MatType.CV_8UC1), 0, 255, cv.THRESH_BINARY).$2,
        cv.COLOR_GRAY2BGR);
      final ox = ((512 - nw) ~/ 2).clamp(0, 511);
      final oy = ((512 - nh) ~/ 2).clamp(0, 511);
      final roi = canvas.region(cv.Rect(ox, oy, nw, nh));
      resized.copyTo(roi);
      resized.dispose();
      roi.dispose();

      return canvas;
    } catch (_) {
      return colorMat;
    }
  }

  void _nextStep() {
    if (_step == 0 && _facePhotoPath != null) {
      setState(() => _step = 1);
    }
  }

  // ---------------------------------------------------------------------------
  // Processing
  // ---------------------------------------------------------------------------

  Future<void> _process() async {
    if (_basePaths.length < _minBasePhotos) return;
    setState(() {
      _step = 2;
      _processing = true;
    });

    try {
      final allFeatures = <ExtractedFeatures>[];
      for (final path in _basePaths) {
        final features = extractFromImage(path);
        if (features != null) allFeatures.add(features);
      }

      if (allFeatures.length < 2) {
        for (final f in allFeatures) f.dispose();
        if (mounted) {
          await showErrorDialog(context,
            StateError('Pas assez de features (${allFeatures.length}). Plus de lumière.'),
            source: 'base-scan-extract');
          setState(() { _step = 1; _processing = false; });
        }
        return;
      }

      final points = selectIdentityPoints(allFeatures);
      final avgFeatures =
          allFeatures.map((f) => f.count).reduce((a, b) => a + b) / allFeatures.length;
      final quality = (avgFeatures / 1500.0).clamp(0.0, 1.0);
      for (final f in allFeatures) f.dispose();

      final gray0 = cv.imdecode(File(_basePaths.first).readAsBytesSync(), cv.IMREAD_GRAYSCALE);
      final imgW = gray0.cols;
      final imgH = gray0.rows;
      gray0.dispose();

      final identity = EggBaseIdentity(
        version: 1,
        imageW: imgW,
        imageH: imgH,
        quality: quality,
        points: points,
        facePhotoPath: _facePhotoPath,
        createdAt: DateTime.now().millisecondsSinceEpoch,
      );

      if (mounted) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(builder: (_) => _EnrollBaseForm(identity: identity)),
        );
      }
    } catch (e) {
      debugConsole.logError(e, source: 'base-scan-process');
      if (mounted) {
        await showErrorDialog(context, e, source: 'base-scan-process');
        setState(() { _step = 1; _processing = false; });
      }
    }
  }

  // ---------------------------------------------------------------------------
  // UI
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(_step == 0 ? 'Photo de face' : 'Scanner la base')),
      body: _buildBody(),
    );
  }

  Widget _buildBody() {
    if (_error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            const Icon(Icons.error_outline, size: 48, color: Colors.red),
            const SizedBox(height: 16),
            SelectableText(_error!, textAlign: TextAlign.center),
          ]),
        ),
      );
    }

    if (!_ready || _controller == null) {
      return const Center(child: CircularProgressIndicator());
    }

    if (_step == 2 && _processing) {
      return const Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(),
          SizedBox(height: 16),
          Text('Analyse SIFT en cours...'),
        ]),
      );
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        _screenW = constraints.maxWidth;
        _screenH = constraints.maxHeight;

        return Stack(
          fit: StackFit.expand,
          children: [
            GestureDetector(
              onScaleStart: (details) {
                _zoomAtGestureStart = _currentZoom;
              },
              onScaleUpdate: (details) {
                final newZoom = (_zoomAtGestureStart * details.scale).clamp(1.0, _maxZoom);
                _currentZoom = newZoom;
                _controller?.setZoomLevel(newZoom);
              },
              child: CameraPreview(_controller!),
            ),
            if (_step == 0) _buildFaceOverlay(),
            if (_step == 1) _buildBaseOverlay(),
          ],
        );
      },
    );
  }

  // -- Step 0: Face photo ----------------------------------------------------

  Widget _buildFaceOverlay() {
    return Stack(
      children: [
        // Rectangle guide
        Center(
          child: Container(
            width: 220,
            height: 300,
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white70, width: 2),
              borderRadius: BorderRadius.circular(16),
            ),
          ),
        ),
        // Instructions
        Positioned(
          top: 16, left: 16, right: 16,
          child: Card(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Text(
                _facePhotoPath == null
                    ? 'Cadrez l\'œuf de face.\nCette photo servira d\'image à la fiche.'
                    : 'Photo capturée ! Appuyez "Suivant".',
                style: const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
        // Preview thumbnail
        if (_facePhotoPath != null)
          Positioned(
            top: 80, right: 16,
            child: Container(
              width: 80, height: 80,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.green, width: 2),
                image: DecorationImage(
                  image: FileImage(File(_facePhotoPath!)),
                  fit: BoxFit.cover,
                ),
              ),
            ),
          ),
        // Buttons
        Positioned(
          bottom: 32, left: 0, right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              FloatingActionButton(
                onPressed: _busy ? null : _captureFace,
                backgroundColor: Colors.white,
                child: Icon(Icons.camera, color: Theme.of(context).primaryColor),
              ),
              if (_facePhotoPath != null) ...[
                const SizedBox(width: 24),
                FloatingActionButton.extended(
                  onPressed: () => setState(() => _step = 1),
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  icon: const Icon(Icons.arrow_forward, color: Colors.white),
                  label: const Text('Suivant', style: TextStyle(color: Colors.white)),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  // -- Step 1: Base photos ---------------------------------------------------

  Widget _buildBaseOverlay() {
    final remaining = _maxBasePhotos - _basePaths.length;
    final canProcess = _basePaths.length >= _minBasePhotos;
    final totalFeatures = _featureCounts.fold(0, (a, b) => a + b);

    return Stack(
      children: [
        Center(
          child: Container(
            width: 280, height: 280,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white70, width: 2),
            ),
          ),
        ),
        // Zoom indicator
        if (_currentZoom > 1.01)
          Positioned(
            top: 16, right: 16,
            child: GestureDetector(
              onTap: () => setState(() { _currentZoom = 1.0; _controller?.setZoomLevel(1.0); }),
              child: Card(
                color: Colors.black54,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  child: Text('×${_currentZoom.toStringAsFixed(1)} (tap reset)',
                      style: const TextStyle(color: Colors.white, fontSize: 12)),
                ),
              ),
            ),
          ),
        // Instructions + feature count
        Positioned(
          top: 16, left: 16, right: 16,
          child: Card(
            color: Colors.black54,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                Text(
                  _basePaths.isEmpty
                      ? 'Placez la base de l\'œuf face à la caméra'
                      : _basePaths.length < _minBasePhotos
                          ? 'Capturez encore (${_minBasePhotos - _basePaths.length} minimum)'
                          : 'Orange = photo faible, sera remplacée si meilleure',
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  textAlign: TextAlign.center,
                ),
                if (_basePaths.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  // Total features display
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    decoration: BoxDecoration(
                      color: totalFeatures > 2000
                          ? Colors.green.withOpacity(0.3)
                          : totalFeatures > 500
                              ? Colors.amber.withOpacity(0.3)
                              : Colors.red.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      '$totalFeatures points remarquables détectés',
                      style: TextStyle(
                        color: totalFeatures > 2000
                            ? Colors.greenAccent
                            : totalFeatures > 500
                                ? Colors.amber
                                : Colors.orange,
                        fontSize: 15,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(height: 6),
                  // Per-photo feature dots with counts
                  Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.center,
                    children: List.generate(_basePaths.length, (i) {
                      final count = _featureCounts[i];
                      final sharp = _sharpnessScores[i];
                      final isGood = sharp > 50 && count > 200;
                      return Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: isGood
                              ? Colors.green.withOpacity(0.3)
                              : Colors.orange.withOpacity(0.3),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${i + 1}: $count',
                          style: TextStyle(
                            color: isGood ? Colors.greenAccent : Colors.orange,
                            fontSize: 11,
                          ),
                        ),
                      );
                    }),
                  ),
                ],
              ]),
            ),
          ),
        ),
        // Buttons
        Positioned(
          bottom: 32, left: 0, right: 0,
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              if (!_busy)
                FloatingActionButton(
                  onPressed: _captureBase,
                  backgroundColor: Colors.white,
                  child: Icon(Icons.camera, color: Theme.of(context).primaryColor),
                ),
              const SizedBox(width: 24),
              if (canProcess)
                FloatingActionButton.extended(
                  onPressed: _process,
                  backgroundColor: Theme.of(context).colorScheme.primary,
                  icon: const Icon(Icons.check, color: Colors.white),
                  label: Text('Enregistrer (${_basePaths.length})',
                      style: const TextStyle(color: Colors.white)),
                ),
            ],
          ),
        ),
        // Count
        Positioned(
          bottom: 100, left: 0, right: 0,
          child: Center(
            child: Text('${_basePaths.length}/$_maxBasePhotos photos',
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Formulaire d'inscription + ajout à la collection
// ---------------------------------------------------------------------------

class _EnrollBaseForm extends StatefulWidget {
  final EggBaseIdentity identity;
  const _EnrollBaseForm({required this.identity});

  @override
  State<_EnrollBaseForm> createState() => _EnrollBaseFormState();
}

class _EnrollBaseFormState extends State<_EnrollBaseForm> {
  final _seriesCtrl = TextEditingController(text: '2');
  final _digitCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _saving = false;

  @override
  void dispose() {
    _seriesCtrl.dispose();
    _digitCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    setState(() => _saving = true);

    try {
      final series = int.tryParse(_seriesCtrl.text) ?? 2;
      final digitNum = _digitCtrl.text.isNotEmpty ? _digitCtrl.text : '0';
      final displayNum = '$series-${digitNum.padLeft(3, '0')}';

      // Read face photo as base64
      String? faceBase64;
      if (widget.identity.facePhotoPath != null) {
        final f = File(widget.identity.facePhotoPath!);
        if (await f.exists()) {
          faceBase64 = base64Encode(await f.readAsBytes());
        }
      }

      final serverId = await context.read<PiecesProvider>().addEggIdentity(
        displayNumber: displayNum,
        seriesValue: series,
        digitNumber: _digitCtrl.text.isNotEmpty ? _digitCtrl.text : null,
        notes: _notesCtrl.text.isNotEmpty ? _notesCtrl.text : null,
        facePhoto: faceBase64,
        identityData: widget.identity.toJson(),
      );

      if (mounted) {
        final msg = serverId != null
            ? 'Œuf enregistré sur le serveur !'
            : 'Erreur serveur, réessayez';
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(msg)),
        );
        if (serverId != null) {
          Navigator.of(context).popUntil((route) => route.isFirst);
        } else {
          setState(() => _saving = false);
        }
      }
    } catch (e) {
      debugConsole.logError(e, source: 'base-enroll');
      if (mounted) {
        setState(() => _saving = false);
        await showErrorDialog(context, e, source: 'base-enroll');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enregistrer l\'œuf')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Face photo preview
            if (widget.identity.facePhotoPath != null)
              Center(
                child: Container(
                  width: 120, height: 120,
                  margin: const EdgeInsets.only(bottom: 16),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey.shade300),
                    image: DecorationImage(
                      image: FileImage(File(widget.identity.facePhotoPath!)),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              ),
            // Summary
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text('${widget.identity.points.length} points remarquables détectés',
                      style: Theme.of(context).textTheme.titleMedium),
                  const SizedBox(height: 4),
                  Text('Qualité: ${(widget.identity.quality * 100).toStringAsFixed(0)}%',
                      style: TextStyle(color: Colors.grey[600])),
                ]),
              ),
            ),
            const SizedBox(height: 24),

            TextField(
              controller: _seriesCtrl,
              decoration: const InputDecoration(labelText: 'Série', hintText: '2 ou 5'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _digitCtrl,
              decoration: const InputDecoration(labelText: 'Numéro (optionnel)', hintText: 'Ex: 42'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesCtrl,
              decoration: const InputDecoration(labelText: 'Nom', hintText: 'Nom de l\'œuf...'),
              maxLines: 3,
            ),
            const Spacer(),

            FilledButton.icon(
              onPressed: _saving ? null : _save,
              icon: _saving
                  ? const SizedBox(width: 20, height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.check),
              label: Text(_saving ? 'Enregistrement...' : 'Enregistrer'),
            ),
          ],
        ),
      ),
    );
  }
}
