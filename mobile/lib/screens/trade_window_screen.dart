import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:provider/provider.dart';
import 'dart:async';
import '../providers/trade_provider.dart';
import '../services/multi_angle_scan.dart';

class TradeWindowScreen extends StatefulWidget {
  final String tradeSessionId;
  const TradeWindowScreen({super.key, required this.tradeSessionId});

  @override
  State<TradeWindowScreen> createState() => _TradeWindowScreenState();
}

class _TradeWindowScreenState extends State<TradeWindowScreen> {
  CameraController? _cameraController;
  bool _isCameraReady = false;
  bool _scanning = false;
  bool _hasScanned = false;
  int _frameCount = 0;
  ScanResult? _scanResult;
  String? _cameraError;

  @override
  void initState() {
    super.initState();
    _initCamera();
    context.read<TradeProvider>().getSession(widget.tradeSessionId);
  }

  Future<void> _initCamera() async {
    final cameras = await availableCameras();
    if (cameras.isEmpty) {
      if (mounted) setState(() => _cameraError = 'Aucune caméra disponible');
      return;
    }
    try {
      final controller = CameraController(cameras.first, ResolutionPreset.medium);
      await controller.initialize();
      if (mounted) {
        setState(() {
          _cameraController = controller;
          _isCameraReady = true;
          _cameraError = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _cameraError = 'Erreur caméra: $e');
      }
    }
  }

  @override
  void dispose() {
    _cameraController?.dispose();
    super.dispose();
  }

  Future<void> _startScan() async {
    if (_cameraController == null || _scanning) return;
    setState(() {
      _scanning = true;
      _frameCount = 0;
    });

    final scanner = MultiAngleScanner(
      _cameraController!,
    );

    scanner.onProgress = (coverage, confidence) {
      if (mounted) setState(() => _frameCount = _frameCount + 1);
    };

    try {
      _scanResult = await scanner.start();
    } catch (_) {
      _scanResult = ScanResult({}, 0, 0, 0);
    }

    if (mounted) {
      setState(() {
        _scanning = false;
        _hasScanned = true;
      });
    }

    final trade = context.read<TradeProvider>();
    final session = trade.currentSession;
    final pieceId = session?.pieceAId ?? session?.pieceBId;
    if (pieceId != null && _scanResult != null) {
      await trade.scanPiece(
        widget.tradeSessionId,
        pieceId,
        {},
        _scanResult!.spatialSignature,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Échange')),
      body: Consumer<TradeProvider>(
        builder: (_, provider, __) {
          final session = provider.currentSession;
          final progress = _scanning ? _frameCount / 15 : 0.0;

          return Column(
            children: [
              Expanded(
                child: _cameraError != null
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(_cameraError!,
                                style: const TextStyle(color: Colors.red),
                                textAlign: TextAlign.center),
                            const SizedBox(height: 16),
                            ElevatedButton(
                              onPressed: () {
                                setState(() => _cameraError = null);
                                _initCamera();
                              },
                              child: const Text('Réessayer'),
                            ),
                          ],
                        ),
                      )
                    : _isCameraReady && _cameraController != null
                    ? Stack(
                        children: [
                          CameraPreview(_cameraController!),
                          if (_scanning)
                            Positioned(
                              bottom: 16,
                              left: 16,
                              right: 16,
                              child: Column(
                                children: [
                                  Text(
                                    'Tourne l\'objet : $_frameCount/15',
                                    style: const TextStyle(
                                        color: Colors.white, fontSize: 16),
                                  ),
                                  const SizedBox(height: 8),
                                  ClipRRect(
                                    borderRadius: BorderRadius.circular(4),
                                    child: LinearProgressIndicator(value: progress),
                                  ),
                                ],
                              ),
                            ),
                          if (_hasScanned && _scanResult != null)
                            Positioned(
                              top: 16,
                              right: 16,
                              child: Container(
                                padding: const EdgeInsets.all(8),
                                decoration: BoxDecoration(
                                  color: Colors.black54,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                                child: Text(
                                  'Scan terminé',
                                  style: const TextStyle(color: Colors.white, fontSize: 12),
                                ),
                              ),
                            ),
                        ],
                      )
                    : const Center(child: CircularProgressIndicator()),
              ),
              Container(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    Text('Session: ${session?.status ?? "..."}'),
                    const SizedBox(height: 8),
                    if (_scanning)
                      const CircularProgressIndicator()
                    else if (!_hasScanned)
                      SizedBox(
                        width: 72,
                        height: 72,
                        child: FloatingActionButton.large(
                          onPressed: _startScan,
                          child: const Icon(Icons.camera_alt),
                        ),
                      )
                    else ...[
                      Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          OutlinedButton(
                            onPressed: () {},
                            child: const Text('Ajuster delta'),
                          ),
                          const SizedBox(width: 16),
                          FilledButton(
                            onPressed: () => provider.confirm(widget.tradeSessionId),
                            child: const Text('Confirmer'),
                          ),
                        ],
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
