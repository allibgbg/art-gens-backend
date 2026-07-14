import 'dart:io';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:camera/camera.dart';
import 'package:opencv_dart/opencv_dart.dart' as cv;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../providers/auth_provider.dart';
import '../providers/pieces_provider.dart';
import '../providers/notifications_provider.dart';
import '../models/piece.dart';
import 'egg_base_scan_screen.dart';
import 'egg_verify_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _currentIndex = 0;

  final _screens = [
    const _CollectionTab(),
    const _ExploreTab(),
    const _WalletTab(),
    const _ProfileTab(),
  ];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<NotificationsProvider>().loadNotifications();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    final unreadCount = context.watch<NotificationsProvider>().unreadCount;
    return Scaffold(
      appBar: AppBar(
        actions: [
          Stack(
            children: [
              IconButton(
                icon: const Icon(Icons.notifications_outlined),
                onPressed: () => Navigator.pushNamed(context, '/notifications'),
              ),
              if (unreadCount > 0)
                Positioned(
                  right: 8,
                  top: 8,
                  child: Container(
                    padding: const EdgeInsets.all(4),
                    decoration: const BoxDecoration(
                      color: Colors.red,
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      unreadCount > 9 ? '9+' : '$unreadCount',
                      style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
      body: _screens[_currentIndex],
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => Navigator.pushNamed(context, '/first-scan'),
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: [
          NavigationDestination(
            icon: const Icon(Icons.collections),
            label: isAdmin ? 'Stock' : 'Collection',
          ),
          const NavigationDestination(icon: Icon(Icons.explore), label: 'Explorer'),
          const NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Portefeuille'),
          NavigationDestination(icon: Icon(Icons.person), label: 'Profil'),
        ],
      ),
    );
  }
}

class _CollectionTab extends StatefulWidget {
  const _CollectionTab();

  @override
  State<_CollectionTab> createState() => _CollectionTabState();
}

class _CollectionTabState extends State<_CollectionTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PiecesProvider>().loadMyPieces();
      context.read<PiecesProvider>().loadMyEggPieces();
      context.read<PiecesProvider>().loadEggIdentities();
    });
  }

  @override
  Widget build(BuildContext context) {
    final isAdmin = context.watch<AuthProvider>().isAdmin;
    return Scaffold(
      appBar: AppBar(title: Text(isAdmin ? 'Mon stock' : 'Ma collection')),
      body: Consumer<PiecesProvider>(
        builder: (_, provider, __) {
          final children = <Widget>[
            if (isAdmin)
              Padding(
                padding: const EdgeInsets.all(12),
                child: Card(
                  color: Colors.amber.shade100,
                  child: ListTile(
                    leading: const Icon(Icons.fingerprint, size: 32),
                    title: const Text('Scanner la base'),
                    subtitle: const Text('Enregistrer la base d\'un œuf (3-5 photos)'),
                    trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EggBaseScanScreen()),
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Card(
                color: Colors.green.shade100,
                child: ListTile(
                  leading: const Icon(Icons.badge, size: 32),
                  title: const Text('Vérifier un œuf'),
                  subtitle: const Text('Scan live : compare la base à l\'identité'),
                  trailing: const Icon(Icons.arrow_forward_ios),
                  onTap: () => Navigator.push(
                    context,
                    MaterialPageRoute(builder: (_) => const EggVerifyScreen()),
                  ),
                ),
              ),
            ),
          ];
          if (provider.myPieces.isEmpty) {
            children.add(
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.inventory_2, size: 64, color: Colors.grey[400]),
                      const SizedBox(height: 16),
                      Text('Aucun objet dans ta collection',
                          style: Theme.of(context).textTheme.titleMedium),
                    ],
                  ),
                ),
              ),
            );
          } else {
            children.add(const SizedBox(height: 8));
            children.add(
              Expanded(
                child: GridView.builder(
                  padding: const EdgeInsets.all(8),
                  gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                    crossAxisCount: 2,
                    childAspectRatio: 0.8,
                    crossAxisSpacing: 8,
                    mainAxisSpacing: 8,
                  ),
                  itemCount: provider.myPieces.length,
                  itemBuilder: (_, i) => _PieceCard(piece: provider.myPieces[i]),
                ),
              ),
            );
          }
          return RefreshIndicator(
            onRefresh: () => provider.loadMyPieces(),
            child: Column(children: children),
          );
        },
      ),
    );
  }
}

class _ExploreTab extends StatefulWidget {
  const _ExploreTab();

  @override
  State<_ExploreTab> createState() => _ExploreTabState();
}

class _ExploreTabState extends State<_ExploreTab> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PiecesProvider>().loadEggIdentities();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explorer'),
      ),
      body: Consumer<PiecesProvider>(
        builder: (_, provider, __) {
          final eggs = provider.eggPieces;
          if (eggs.isEmpty) {
            return const Center(child: Text('Aucune pierre répertoriée'));
          }
          return RefreshIndicator(
            onRefresh: () => provider.loadEggIdentities(),
            child: GridView.builder(
              padding: const EdgeInsets.all(8),
              gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                crossAxisCount: 2,
                childAspectRatio: 0.75,
                crossAxisSpacing: 8,
                mainAxisSpacing: 8,
              ),
              itemCount: eggs.length,
              itemBuilder: (_, i) {
                final piece = eggs[i];
                final hasPhoto = piece.photoUrl != null &&
                    (piece.photoUrl!.startsWith('/') || piece.photoUrl!.contains('\\'));
                final name = piece.materialNotes;
                return Card(
                  clipBehavior: Clip.antiAlias,
                  child: InkWell(
                    onTap: () => Navigator.pushNamed(
                      context,
                      '/egg-detail',
                      arguments: piece.id,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Expanded(
                          child: hasPhoto
                              ? Image.file(
                                  File(piece.photoUrl!),
                                  fit: BoxFit.cover,
                                )
                              : Container(
                                  color: Colors.purple.shade200,
                                  child: Center(
                                    child: Text(
                                      piece.displayNumber,
                                      style: const TextStyle(
                                        fontSize: 24,
                                        fontWeight: FontWeight.bold,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                        ),
                        Padding(
                          padding: const EdgeInsets.all(8),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                name != null && name.isNotEmpty
                                    ? '${piece.displayNumber.split('-').last}-$name'
                                    : piece.displayNumber,
                                style: const TextStyle(fontWeight: FontWeight.bold),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              Text(
                                'Série ${piece.seriesValue} — ${piece.referencePinceauxValue} 🖌',
                                style: TextStyle(color: Colors.grey[600], fontSize: 11),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          );
        },
      ),
    );
  }
}

class _WalletTab extends StatelessWidget {
  const _WalletTab();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Portefeuille')),
      body: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              '${user?.pinceauxBalance ?? 0}',
              style: Theme.of(context).textTheme.displayLarge?.copyWith(
                    fontWeight: FontWeight.bold,
                    color: Theme.of(context).colorScheme.primary,
                  ),
            ),
            const SizedBox(height: 8),
            const Text('pinceaux', style: TextStyle(fontSize: 18)),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: () {},
              icon: const Icon(Icons.add),
              label: const Text('Acheter des pinceaux'),
            ),
          ],
        ),
      ),
    );
  }
}

class _ProfileTab extends StatelessWidget {
  const _ProfileTab();

  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    return Scaffold(
      appBar: AppBar(title: const Text('Profil')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          children: [
            CircleAvatar(
              radius: 40,
              child: Text(user?.pseudo[0].toUpperCase() ?? '?'),
            ),
            const SizedBox(height: 16),
            Text(user?.pseudo ?? '', style: Theme.of(context).textTheme.headlineSmall),
            const SizedBox(height: 8),
            Text(user?.email ?? '', style: TextStyle(color: Colors.grey[600])),
            const SizedBox(height: 24),
            ListTile(
              leading: const Icon(Icons.star),
              title: Text('Fiabilité: ${((user?.reputationScore ?? 1.0) * 100).toStringAsFixed(0)}%'),
            ),
            const Spacer(),
            OutlinedButton(
              onPressed: () => context.read<AuthProvider>().logout(),
              child: const Text('Déconnexion'),
            ),
          ],
        ),
      ),
    );
  }
}

class _PieceCard extends StatelessWidget {
  final Piece piece;
  const _PieceCard({required this.piece});

  bool get _isLocal => kAdminBuild && piece.id.startsWith('egg_');

  @override
  Widget build(BuildContext context) {
    final hasPhoto = piece.photoUrl != null &&
        (piece.photoUrl!.startsWith('/') || piece.photoUrl!.contains('\\'));

    return Card(
      child: InkWell(
        onTap: _isLocal
            ? () => _showLocalDetail(context)
            : () => Navigator.pushNamed(context, '/piece-detail', arguments: piece.id),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                width: double.infinity,
                decoration: BoxDecoration(
                  color: hasPhoto ? null : _colorFromString(piece.colorPrimary),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                  image: hasPhoto
                      ? DecorationImage(
                          image: FileImage(File(piece.photoUrl!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: hasPhoto
                    ? null
                    : Center(
                        child: Text(
                          piece.displayNumber,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    piece.materialNotes != null && piece.materialNotes!.isNotEmpty
                        ? '${piece.displayNumber.split('-').last}-${piece.materialNotes}'
                        : piece.displayNumber,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  Text('Série ${piece.seriesValue}',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                  Text('${piece.referencePinceauxValue} 🖌',
                      style: TextStyle(color: Colors.grey[600], fontSize: 12)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showLocalDetail(BuildContext context) {
    final hasPhoto = piece.photoUrl != null &&
        (piece.photoUrl!.startsWith('/') || piece.photoUrl!.contains('\\'));
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => _LocalEggEditScreen(piece: piece)),
    );
  }
}

class _LocalEggEditScreen extends StatefulWidget {
  final Piece piece;
  const _LocalEggEditScreen({required this.piece});

  @override
  State<_LocalEggEditScreen> createState() => _LocalEggEditScreenState();
}

class _LocalEggEditScreenState extends State<_LocalEggEditScreen> {
  late TextEditingController _seriesCtrl;
  late TextEditingController _numberCtrl;
  late TextEditingController _notesCtrl;
  late TextEditingController _pinceauxCtrl;
  bool _hasPhoto = false;

  @override
  void initState() {
    super.initState();
    _seriesCtrl = TextEditingController(text: widget.piece.seriesValue.toString());
    _numberCtrl = TextEditingController(text: widget.piece.displayNumber.split('-').last);
    _notesCtrl = TextEditingController(text: widget.piece.materialNotes ?? '');
    _pinceauxCtrl = TextEditingController(text: widget.piece.referencePinceauxValue.toString());
    _hasPhoto = widget.piece.photoUrl != null &&
        (widget.piece.photoUrl!.startsWith('/') || widget.piece.photoUrl!.contains('\\'));
  }

  @override
  void dispose() {
    _seriesCtrl.dispose();
    _numberCtrl.dispose();
    _notesCtrl.dispose();
    _pinceauxCtrl.dispose();
    super.dispose();
  }

  Future<void> _retakeFacePhoto() async {
    final result = await Navigator.push<String>(context,
      MaterialPageRoute(builder: (_) => _RetakeFacePhotoScreen(pieceId: widget.piece.id)),
    );
    if (result != null && mounted) {
      setState(() => _hasPhoto = true);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Photo de face remplacée')),
        );
      }
    }
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        icon: const Icon(Icons.warning, color: Colors.red, size: 48),
        title: const Text('Supprimer cet œuf ?'),
        content: Text(
          'Œuf ${widget.piece.displayNumber}\n'
          'Cette action est irréversible.\n\n'
          'La photo de face et les données seront supprimées.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Annuler'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(context); // close dialog

              // Delete from server
              if (context.mounted) {
                context.read<PiecesProvider>().removeEggIdentity(widget.piece.id);
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Œuf supprimé du serveur')),
                );
                Navigator.pop(context); // back to list
              }
            },
            child: const Text('Supprimer'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Œuf ${widget.piece.displayNumber}'),
      ),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_hasPhoto)
              Center(
                child: Column(
                  children: [
                    Container(
                      width: 160, height: 160,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: Colors.grey.shade300),
                        image: DecorationImage(
                          image: FileImage(File(widget.piece.photoUrl!)),
                          fit: BoxFit.cover,
                        ),
                      ),
                    ),
                    TextButton.icon(
                      onPressed: _retakeFacePhoto,
                      icon: const Icon(Icons.camera_alt, size: 18),
                      label: const Text('Reprendre la photo de face'),
                    ),
                  ],
                ),
              ),
            TextField(
              controller: _seriesCtrl,
              decoration: const InputDecoration(labelText: 'Série', hintText: '2 ou 5'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _numberCtrl,
              decoration: const InputDecoration(labelText: 'Numéro', hintText: 'Ex: 42'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _notesCtrl,
              decoration: const InputDecoration(labelText: 'Nom', hintText: 'Nom de l\'œuf...'),
              maxLines: 3,
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _pinceauxCtrl,
              decoration: const InputDecoration(labelText: 'Valeur pinceaux', hintText: 'Ex: 100'),
              keyboardType: TextInputType.number,
            ),
            const SizedBox(height: 8),
            Text(
              'Enregistré le ${widget.piece.creationDate.day}/${widget.piece.creationDate.month}/${widget.piece.creationDate.year}',
              style: TextStyle(color: Colors.grey[500], fontSize: 12),
            ),
            const Spacer(),
            Row(
              children: [
                OutlinedButton.icon(
                  onPressed: () => _confirmDelete(context),
                  icon: const Icon(Icons.delete_outline, color: Colors.red),
                  label: const Text('Supprimer', style: TextStyle(color: Colors.red)),
                ),
                const Spacer(),
                FilledButton.icon(
                  onPressed: () async {
                    final series = int.tryParse(_seriesCtrl.text) ?? widget.piece.seriesValue;
                    final number = _numberCtrl.text.isNotEmpty ? _numberCtrl.text : widget.piece.displayNumber.split('-').last;
                    final notes = _notesCtrl.text.isNotEmpty ? _notesCtrl.text : null;
                    final pinceaux = int.tryParse(_pinceauxCtrl.text) ?? widget.piece.referencePinceauxValue;
                    final displayNum = '$series-${number.padLeft(3, '0')}';

                    await context.read<PiecesProvider>().updateEggIdentity(
                      widget.piece.id,
                      seriesValue: series,
                      displayNumber: displayNum,
                      notes: notes,
                      pinceauxValue: pinceaux,
                    );

                    if (mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Modifications enregistrées sur le serveur')),
                      );
                      Navigator.pop(context);
                    }
                  },
                  icon: const Icon(Icons.check),
                  label: const Text('Enregistrer'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RetakeFacePhotoScreen extends StatefulWidget {
  final String pieceId;
  const _RetakeFacePhotoScreen({required this.pieceId});

  @override
  State<_RetakeFacePhotoScreen> createState() => _RetakeFacePhotoScreenState();
}

class _RetakeFacePhotoScreenState extends State<_RetakeFacePhotoScreen> {
  CameraController? _controller;
  bool _ready = false;
  bool _busy = false;
  String? _facePhotoPath;
  String? _dir;
  double _currentZoom = 1.0;
  double _maxZoom = 5.0;
  double _zoomAtGestureStart = 1.0;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      final cameras = await availableCameras();
      final cam = cameras.firstWhere(
        (c) => c.lensDirection == CameraLensDirection.back,
        orElse: () => cameras.first,
      );
      _controller = CameraController(cam, ResolutionPreset.high, enableAudio: false);
      await _controller!.initialize();
      try {
        _maxZoom = await _controller!.getMaxZoomLevel();
        await _controller!.setZoomLevel(1.0);
        await _controller!.setFocusPoint(const Offset(0.5, 0.5));
      } catch (_) {}
      final dir = await getApplicationDocumentsDirectory();
      _dir = dir.path;
      if (mounted) setState(() => _ready = true);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur caméra: $e')),
        );
        Navigator.pop(context);
      }
    }
  }

  Future<void> _captureFace() async {
    if (_busy || _controller == null || !_controller!.value.isInitialized) return;
    setState(() => _busy = true);

    try {
      final streaming = _controller!.value.isStreamingImages;
      if (streaming) await _controller!.stopImageStream();

      final ts = DateTime.now().millisecondsSinceEpoch;
      final xfile = await _controller!.takePicture();
      final bytes = await xfile.readAsBytes();

      final colorMat = cv.imdecode(bytes, 1);
      if (colorMat.cols <= 0 || colorMat.rows <= 0) {
        _busy = false;
        return;
      }

      final cropped = cropEgg(colorMat);
      colorMat.dispose();

      final outPath = '$_dir/face_$ts.jpg';
      cv.imwrite(outPath, cropped);
      cropped.dispose();

      if (mounted) setState(() { _facePhotoPath = outPath; _busy = false; });

      if (_controller!.value.isInitialized && mounted) {
        await _controller!.startImageStream((_) {});
      }
    } catch (e) {
      _busy = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _save() async {
    if (_facePhotoPath == null) return;
    setState(() => _busy = true);

    try {
      final bytes = await File(_facePhotoPath!).readAsBytes();
      final b64 = base64Encode(bytes);

      // Save to egg_faces cache
      final serverId = widget.pieceId.replaceFirst('egg_', '');
      final cacheDir = Directory('${_dir!}/../egg_faces');
      await cacheDir.create(recursive: true);
      final localPath = '${cacheDir.path}/$serverId.jpg';
      await File(_facePhotoPath!).copy(localPath);

      // Upload to server
      if (mounted) {
        await context.read<PiecesProvider>().updateEggIdentity(
          widget.pieceId,
          facePhoto: b64,
          localPhotoPath: localPath,
        );
        Navigator.pop(context, localPath);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
      }
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_ready || _controller == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: Stack(
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
                      : 'Photo capturée ! Appuyez "Enregistrer".',
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
                if (!_busy)
                  FloatingActionButton(
                    onPressed: _captureFace,
                    backgroundColor: Colors.white,
                    child: Icon(Icons.camera, color: Theme.of(context).primaryColor),
                  ),
                if (_busy)
                  const CircularProgressIndicator(color: Colors.white),
                if (_facePhotoPath != null) ...[
                  const SizedBox(width: 24),
                  FloatingActionButton.extended(
                    onPressed: _save,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    icon: const Icon(Icons.check, color: Colors.white),
                    label: const Text('Enregistrer', style: TextStyle(color: Colors.white)),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

Color _colorFromString(String color) {
  switch (color) {
    case 'blanc': return Colors.grey.shade200;
    case 'noir': return Colors.grey.shade900;
    case 'rouge': return Colors.red;
    case 'bleu': return Colors.blue;
    case 'vert': return Colors.green;
    case 'jaune': return Colors.amber;
    case 'magenta': return Colors.pink;
    case 'multicolore': return Colors.purple;
    default: return Colors.grey;
  }
}
