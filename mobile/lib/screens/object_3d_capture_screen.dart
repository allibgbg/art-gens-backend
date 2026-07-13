import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/texture_extraction.dart' show yPlaneToGrayMat;
import '../services/api_client.dart';

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
  bool _auto = true;
  bool _busy = false;
  final List<String> _frames = [];
  String _dir = '';
  cv.Mat? _prevGray;
  DateTime _lastCap = DateTime.fromMillisecondsSinceEpoch(0);
  String? _lastMeshPath;
  Map<String, dynamic>? _lastScore;
  bool _processing = false;
  String? _statusMsg;

  @override
  void initState() {
    super.initState();
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
    if (!mounted) return;
    setState(() => _ready = true);
    await _controller!.startImageStream(_onImage);
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
        await _captureNow();
        _lastCap = DateTime.now();
        _busy = false;
      }
    }
    _prevGray?.dispose();
    _prevGray = gray;
  }

  /// Capture une vue (JPEG) dans le dossier ARTGENS. Gère l'arrêt/relance du
  /// flux d'images (takePicture exige l'absence de flux).
  Future<void> _captureNow() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    final streaming = _controller!.value.isStreamingImages;
    if (streaming) await _controller!.stopImageStream();
    try {
      final ts = DateTime.now().millisecondsSinceEpoch;
      final path = '$_dir/frame_${_frames.length.toString().padLeft(3, '0')}_$ts.jpg';
      final xfile = await _controller!.takePicture();
      await xfile.saveTo(path);
      _frames.add(path);
      if (mounted) setState(() {});
    } catch (_) {
      // ignore les échecs de capture
    }
    if (mounted && _controller!.value.isInitialized && (_auto || streaming)) {
      await _controller!.startImageStream(_onImage);
    }
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
    final sb = StringBuffer();
    sb.writeln('ARTGENS 3D CAPTURE');
    sb.writeln('date=${DateTime.now().toIso8601String()}');
    sb.writeln('frames=${_frames.length}');
    sb.writeln('dir=$_dir');
    for (var i = 0; i < _frames.length; i++) {
      sb.writeln('frame[$i]=${_frames[i]}');
    }
    final txt = '$_dir/capture_info.txt';
    await File(txt).writeAsString(sb.toString());

    String msg = '${_frames.length} vues enregistrées.\n$txt';
    if (_frames.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
        Navigator.pop(context);
      }
      return;
    }

    // Reconstruction COLMAP côté backend (instance unique, là où c'est le
    // mieux placé : serveur). Pas de reconstruction sur le téléphone.
    setState(() => _processing = true);
    try {
      final api = context.read<ApiClient>();
      final res = await api.reconstruct3D(_frames, dense: true);
      final info = res['info'] as Map<String, dynamic>? ?? {};
      final bytes = res['meshBytes'] as Uint8List;
      final ts = DateTime.now().millisecondsSinceEpoch;
      final meshPath = '$_dir/model_$ts.obj';
      await File(meshPath).writeAsBytes(bytes);
      _lastMeshPath = meshPath;
      msg += '\nMesh reconstruit: $meshPath';
      if (info['num_images'] != null) {
        msg += '\n(images traitées: ${info['num_images']}, dense: ${info['dense']})';
      }

      // Si une référence existe déjà, comparer pour score d'auth.
      final refPath = '$_dir/reference.obj';
      if (File(refPath).existsSync()) {
        try {
          final score = await api.compare3D(refPath, meshPath);
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
      if (e.statusCode == 501) {
        msg += '\nBackend: COLMAP indisponible (worker requis). '
            'Vues + infos enregistrées localement pour traitement ultérieur.';
      } else {
        msg += '\nErreur backend: $e';
      }
    } catch (e) {
      msg += '\nErreur: $e';
    } finally {
      if (mounted) setState(() => _processing = false);
    }

    _statusMsg = msg;
    if (mounted) {
      showDialog(
        context: context,
        builder: (_) => AlertDialog(
          title: const Text('Résultat scan 3D'),
          content: SingleChildScrollView(child: Text(msg)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Fermer'),
            ),
            if (_lastMeshPath != null)
              TextButton(
                onPressed: () {
                  Navigator.pop(context);
                  _setReference();
                },
                child: const Text('Définir réf.'),
              ),
          ],
        ),
      );
    }
  }

  /// Copie le dernier mesh reconstruit comme référence d'authentification.
  Future<void> _setReference() async {
    if (_lastMeshPath == null) return;
    final refPath = '$_dir/reference.obj';
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
                      'Faites pivoter l\'œuf lentement (${_auto ? "auto" : "manuel"}). '
                      'Recouvrement important. ${_frames.length} vues capturées.',
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
