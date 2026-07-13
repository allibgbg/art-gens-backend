import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/texture_extraction.dart' show yPlaneToGrayMat, quickSharpness, quickSharpnessMat, centerCropRegion;
import '../services/on_device_sfm.dart';
import '../services/api_client.dart';
import '../services/debug_console.dart';

/// Outil de capture 3D séparé du scan de nouvel objet.
/// Capture une série de photos "live" (auto sur mouvement ou manuel) pendant
/// que l'utilisateur fait pivoter l'objet, puis exporte la liste des vues +
/// un fichier capture_info.txt dans le dossier ARTGENS.
class Object3DCaptureScreen extends StatefulWidget {
  const Object3DCaptureScreen({super.key});

  @override
  State<Object3DCaptureScreen> createState() => _Object3DCaptureScreenState();
}

class _Object3DCaptureScreenState extends State<Object3DCaptureScreen> {
  CameraController? _controller;
  bool _ready = false;
  bool _auto = false;
  bool _busy = false;
  final List<String> _frames = [];
  String _dir = '';
  cv.Mat? _prevGray;
  DateTime _lastCap = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastMeshPath;
  Map<String, dynamic>? _lastScore;
  bool _processing = false;
  String? _statusMsg;
  final List<double> _frameSharpness = [];
  double _screenW = 400;
  double _screenH = 800;

  @override
  void initState() {
    super.initState();
    final view = WidgetsBinding.instance.platformDispatcher.views.first;
    final dpr = view.devicePixelRatio;
    if (dpr > 0) {
      _screenW = view.physicalSize.width / dpr;
      _screenH = view.physicalSize.height / dpr;
    }
    _init();
  }

  Future<void> _init() async {
    _dir = await _artgensDir();
    final cameras = await availableCameras();
    if (cameras.isEmpty) return;
    final back = cameras.firstWhere(
      (c) => c.lensDirection == CameraLensDirection.back,
      orElse: () => cameras.first,
    );
    _controller = CameraController(
      back,
      ResolutionPreset.medium,
      imageFormatGroup: ImageFormatGroup.yuv420,
    );
    await _controller!.initialize();
    await _controller!.setZoomLevel(1.3);
    if (!mounted) return;
    setState(() => _ready = true);
  }

  /// Dossier de destination : C:\Users\BGG\Downloads\ARTGENS sur Windows
  /// (build desktop), sinon le stockage externe de l'app sur Android.
  Future<String> _artgensDir() async {
    if (Platform.isWindows) {
      final p = r'C:\Users\BGG\Downloads\ARTGENS';
      await Directory(p).create(recursive: true);
      return p;
    }
    final ext = await getExternalStorageDirectory();
    final p = '${ext!.path}/ARTGENS';
    await Directory(p).create(recursive: true);
    return p;
  }

  void _onImage(CameraImage image) async {
    if (!_auto || _busy || _controller == null) return;
    final gray = yPlaneToGrayMat(image);
    if (gray == null) return;
    if (_prevGray != null) {
      final a = cv.resize(gray, (64, 64));
      final b = cv.resize(_prevGray!, (64, 64));
      final d = cv.absDiff(a, b);
      final mean = cv.mean(d).val[0];
      a.dispose();
      b.dispose();
      d.dispose();
      final now = DateTime.now();
      if (mean > 6.0 && now.difference(_lastCap).inMilliseconds > 500) {
        _busy = true;
        _prevGray?.dispose();
        _prevGray = null;
        final saved = await _captureNow();
        if (saved != null) _frameSharpness.add(quickSharpness(image));
        _lastCap = DateTime.now();
        _busy = false;
      }
    }
    _prevGray?.dispose();
    _prevGray = gray;
  }

  /// Capture une vue (JPEG) dans le dossier ARTGENS. Gère l'arrêt/relance du
  /// flux d'images (takePicture exige l'absence de flux).
  Future<String?> _captureNow() async {
    if (_controller == null || !_controller!.value.isInitialized) return null;
    final streaming = _controller!.value.isStreamingImages;
    if (streaming) await _controller!.stopImageStream();
    String? saved;
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '$_dir/frame_${_frames.length.toString().padLeft(3, '0')}_$ts.jpg';
      final xfile = await _controller!.takePicture();
      final bytes = await xfile.readAsBytes();
      saved = await _saveCropped(path, bytes);
      _frames.add(saved);
      if (mounted) setState(() {});
    } catch (_) {
      saved = null;
    }
    if (mounted && _controller!.value.isInitialized && (_auto || streaming)) {
      await _controller!.startImageStream(_onImage);
    }
    return saved;
  }

  Future<String> _saveCropped(String path, Uint8List bytes) async {
    try {
      final mat = cv.imdecode(bytes, 1);
      if (mat.cols <= 0 || mat.rows <= 0) return _fallbackSave(path, bytes);
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
      final ok = cv.imwrite(path, cropped);
      mat.dispose();
      cropped.dispose();
      if (!ok) return _fallbackSave(path, bytes);
      return path;
    } catch (_) {
      return _fallbackSave(path, bytes);
    }
  }

  Future<String> _fallbackSave(String path, Uint8List bytes) async {
    await File(path).writeAsBytes(bytes);
    return path;
  }

  /// Sélectionne jusqu'à 60 vues en maximisant la diversité angulaire.
  /// Toutes les frames sont conservées brute ; le tri se fait ici au moment
  /// du "Terminer" : on calcule la sharpness de chaque vue, on élimine les
  /// floues, puis on sélectionne régulièrement sur la séquence pour couvrir
  /// un maximum d'angles différents.
  List<String> _selectFrames({int maxFrames = 60}) {
    if (_frames.isEmpty) return _frames;

    // 1) Calculer la netteté de chaque frame
    final scored = <_ScoredFrame>[];
    for (var i = 0; i < _frames.length; i++) {
      double sharpness;
      if (i < _frameSharpness.length) {
        sharpness = _frameSharpness[i];
      } else {
        // Pas encore mesuré → lire et calculer
        try {
          final bytes = File(_frames[i]).readAsBytesSync();
          final mat = cv.imdecode(bytes, cv.IMREAD_GRAYSCALE);
          if (mat.cols > 0 && mat.rows > 0) {
            sharpness = quickSharpnessMat(mat);
            mat.dispose();
          } else {
            sharpness = 0;
            mat.dispose();
          }
        } catch (_) {
          sharpness = 0;
        }
      }
      scored.add(_ScoredFrame(i, sharpness));
    }

    // 2) Trier par sharpness décroissante, garder les plus nettes (>=2.0)
    scored.sort((a, b) => b.sharpness.compareTo(a.sharpness));
    final sharp = scored.where((f) => f.sharpness >= 2.0).toList();

    // Si pas assez de frames nettes, on garde toutes les frames
    final pool = sharp.length >= 12 ? sharp : scored;

    // 3) Trier par index pour avoir l'ordre séquentiel
    pool.sort((a, b) => a.index.compareTo(b.index));

    if (pool.length <= maxFrames) {
      return pool.map((f) => _frames[f.index]).toList();
    }

    // 4) Sélection régulière pour diversité angulaire maximale
    final sel = <int>[];
    final step = (pool.length - 1) / (maxFrames - 1);
    for (var k = 0; k < maxFrames; k++) {
      sel.add(pool[(k * step).round().clamp(0, pool.length - 1)].index);
    }
    return sel.map((i) => _frames[i]).toList();
  }

  Future<void> _toggleAuto(bool v) async {
    _auto = v;
    if (_controller == null || !_controller!.value.isInitialized) return;
    if (v) {
      if (!_controller!.value.isStreamingImages) {
        await _controller!.startImageStream(_onImage);
      }
    } else if (_controller!.value.isStreamingImages) {
      await _controller!.stopImageStream();
    }
    if (mounted) setState(() {});
  }

  Future<void> _finish() async {
    if (_processing) return;
    final selected = _selectFrames();
    final sb = StringBuffer();
    sb.writeln('ARTGENS 3D CAPTURE');
    sb.writeln('date=${DateTime.now().toIso8601String()}');
    sb.writeln('frames=${_frames.length}');
    sb.writeln('selected=${selected.length}');
    sb.writeln('dir=$_dir');
    for (var i = 0; i < _frames.length; i++) {
      sb.writeln('frame[$i]=${_frames[i]}');
    }
    for (var i = 0; i < selected.length; i++) {
      sb.writeln('selected[$i]=${selected[i]}');
    }
    final txt = '$_dir/capture_info.txt';
    await File(txt).writeAsString(sb.toString());

    String msg = '${_frames.length} vues enregistrées (${selected.length} sélectionnées).\n$txt';
    if (selected.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        Navigator.pop(context);
      }
      return;
    }

    setState(() => _processing = true);
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final plyPath = '$_dir/model_$ts.ply';

      // 1) Reconstruction 3D ON-DEVICE (SIFT + triangulation)
      msg += '\nReconstruction 3D sur le téléphone...';
      if (mounted) setState(() {});

      final stats = await compute(_reconstructPly, _ReconstructArgs(selected, plyPath));

      _lastMeshPath = plyPath;
      msg += '\nNuage de points: ${stats['n_points']} pts (${stats['n_views']} vues, ${stats['n_raw_points']} bruts).';
      msg += '\nFichier: $plyPath';

      // 2) Comparaison avec la référence (si existante) via le backend
      final refPly = '$_dir/reference.ply';
      if (File(refPly).existsSync()) {
        try {
          final api = context.read<ApiClient>();
          final score = await api.compare3D(refPly, plyPath);
          _lastScore = score;
          final sc = (score['score'] as num?)?.toDouble() ?? 0.0;
          msg += '\nScore d\'authenticité vs référence: ${(sc * 100).toStringAsFixed(1)}%';
        } catch (e) {
          msg += '\n(Comparaison impossible: $e)';
        }
      } else {
        msg += '\nAucune référence: utilise "Définir réf." pour enregistrer ce scan.';
      }
    } on ApiException catch (e) {
      debugConsole.logError(e, source: 'ondevice-sfm');
      msg += '\nErreur backend (compare): $e';
    } catch (e) {
      debugConsole.logError(e, source: 'ondevice-sfm');
      msg += '\nErreur reconstruction: $e';
    } finally {
      if (mounted) setState(() => _processing = false);
    }

    _statusMsg = msg;
    if (mounted) {
      if (_lastMeshPath != null) {
        Navigator.pushReplacement(
          context,
          MaterialPageRoute(
            builder: (_) => _EnrollScanScreen(
              plyPath: _lastMeshPath!,
              dir: _dir,
              stats: msg,
            ),
          ),
        );
      } else {
        showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Résultat scan 3D'),
            content: SingleChildScrollView(child: SelectableText(msg)),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fermer'),
              ),
            ],
          ),
        );
      }
    }
  }

  /// Copie le dernier mesh reconstruit comme référence d'authentification.
  Future<void> _setReference() async {
    if (_lastMeshPath == null) return;
    final refPath = '$_dir/reference.ply';
    await File(_lastMeshPath!).copy(refPath);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Référence enregistrée: $refPath')),
      );
    }
  }

  @override
  void dispose() {
    _prevGray?.dispose();
    if (_controller?.value.isStreamingImages ?? false) {
      _controller!.stopImageStream();
    }
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Outil scan 3D (photos live)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.check),
            tooltip: 'Terminer et exporter',
            onPressed: _finish,
          ),
        ],
      ),
      body: _ready && _controller != null
          ? Stack(
              children: [
                CameraPreview(_controller!),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _CircleGuidePainter(280),
                  ),
                ),
                Positioned(
                  top: 12,
                  left: 12,
                  right: 12,
                  child: Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      'Cadrez l\'œuf dans le cercle. '
                      '(${_auto ? "auto" : "manuel"}) ${_frames.length} vues.',
                      style: const TextStyle(color: Colors.white),
                    ),
                  ),
                ),
              ],
            )
          : const Center(child: CircularProgressIndicator()),
      bottomNavigationBar: SafeArea(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: _processing
              ? const Center(child: CircularProgressIndicator())
              : Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _ready ? _captureNow : null,
                  icon: const Icon(Icons.camera),
                  label: const Text('Capturer une vue'),
                ),
              ),
              const SizedBox(width: 12),
              Switch(
                value: _auto,
                onChanged: _ready ? _toggleAuto : null,
                activeColor: Colors.amber,
              ),
              const Text('Auto'),
              const SizedBox(width: 12),
              OutlinedButton(
                onPressed: _lastMeshPath != null ? _setReference : null,
                child: const Text('Réf.'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Guide visuel : cercle FIXE de `diameter` dp au centre de l'écran. Ce cercle
/// correspond exactement à la zone recadrée côté app (centerCropRegion), donc
/// tout ce qui est dans le cercle sera conservé (qualité maximale de l'œuf),
/// le reste ignoré pour alléger les fichiers envoyés au backend.
class _CircleGuidePainter extends CustomPainter {
  final double diameter;
  const _CircleGuidePainter(this.diameter);

  @override
  void paint(Canvas canvas, Size size) {
    final r = diameter / 2;
    final center = Offset(size.width / 2, size.height / 2);
    final paint = Paint()
      ..color = Colors.white
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5;
    canvas.drawCircle(center, r, paint);
    final tick = Paint()
      ..color = Colors.amber
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    canvas.drawCircle(center, r + 6, tick);
  }

  @override
  bool shouldRepaint(covariant CustomPainter old) => false;
}

class _ReconstructArgs {
  final List<String> imagePaths;
  final String outPlyPath;
  _ReconstructArgs(this.imagePaths, this.outPlyPath);
}

Map<String, dynamic> _reconstructPly(_ReconstructArgs args) {
  return reconstructToPly(args.imagePaths, outPlyPath: args.outPlyPath);
}

class _ScoredFrame {
  final int index;
  final double sharpness;
  _ScoredFrame(this.index, this.sharpness);
}

class _EnrollScanScreen extends StatefulWidget {
  final String plyPath;
  final String dir;
  final String stats;
  const _EnrollScanScreen(
      {required this.plyPath, required this.dir, required this.stats});

  @override
  State<_EnrollScanScreen> createState() => _EnrollScanScreenState();
}

class _EnrollScanScreenState extends State<_EnrollScanScreen> {
  final _formKey = GlobalKey<FormState>();
  final _seriesCtrl = TextEditingController(text: '2');
  final _digitCtrl = TextEditingController();
  final _notesCtrl = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      // 1) Copier le PLY comme référence
      final refPly = '${widget.dir}/reference.ply';
      await File(widget.plyPath).copy(refPly);

      // 2) Sauvegarder les métadonnées
      final meta = {
        'series': int.parse(_seriesCtrl.text),
        'digit': _digitCtrl.text.isEmpty ? null : _digitCtrl.text,
        'notes': _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
        'ply': widget.plyPath,
        'date': DateTime.now().toIso8601String(),
      };
      final metaPath = '${widget.dir}/enrollment.json';
      await File(metaPath).writeAsString(jsonEncode(meta));

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text(
                  'Objet enregistré ! Série ${_seriesCtrl.text}${_digitCtrl.text.isNotEmpty ? ", n°${_digitCtrl.text}" : ""}')),
        );
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    } catch (e) {
      debugConsole.logError(e, source: 'enroll-scan');
      if (mounted) {
        setState(() => _saving = false);
        await showDialog(
          context: context,
          builder: (_) => AlertDialog(
            title: const Text('Erreur'),
            content: SingleChildScrollView(
              child: SelectableText(e.toString()),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('Fermer'),
              ),
            ],
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _seriesCtrl.dispose();
    _digitCtrl.dispose();
    _notesCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Enregistrer l\'objet')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: ListView(children: [
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green.withOpacity(0.1),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(widget.stats,
                  style: const TextStyle(fontSize: 13, color: Colors.white70)),
            ),
            const SizedBox(height: 24),
            TextFormField(
              controller: _seriesCtrl,
              decoration: const InputDecoration(
                  labelText: 'Série', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _digitCtrl,
              decoration: const InputDecoration(
                  labelText: 'Numéro (optionnel)',
                  border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _notesCtrl,
              decoration: const InputDecoration(
                  labelText: 'Notes (optionnel)',
                  border: OutlineInputBorder()),
              maxLines: 3,
            ),
            const SizedBox(height: 24),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_saving ? 'Enregistrement...' : 'Enregistrer'),
                style: ElevatedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
