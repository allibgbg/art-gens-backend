import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/pieces_provider.dart';
import '../providers/auth_provider.dart';
import '../models/piece.dart';

class PieceDetailScreen extends StatefulWidget {
  final String pieceId;
  const PieceDetailScreen({super.key, required this.pieceId});

  @override
  State<PieceDetailScreen> createState() => _PieceDetailScreenState();
}

class _PieceDetailScreenState extends State<PieceDetailScreen> {
  Piece? _piece;
  List<Map<String, dynamic>> _provenance = [];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<PiecesProvider>();
    final piece = await provider.loadPieceDetails(widget.pieceId);
    final provenance = await provider.loadProvenance(widget.pieceId);
    if (mounted) {
      setState(() {
        _piece = piece;
        _provenance = provenance;
        _isLoading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (_piece == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Objet introuvable')),
      );
    }

    final piece = _piece!;
    final currentUserId = context.read<AuthProvider>().user?.id;
    final isOwner = piece.currentOwnerId == currentUserId;

    return Scaffold(
      appBar: AppBar(title: Text(piece.displayNumber)),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Center(
              child: Container(
                width: 200,
                height: 200,
                decoration: BoxDecoration(
                  color: _colorFromString(piece.colorPrimary),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Center(
                  child: Text(
                    piece.displayNumber,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 48,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(height: 24),
            Text(piece.displayNumber,
                style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.bold,
                    )),
            const SizedBox(height: 8),
            Chip(label: Text('Série ${piece.seriesValue}')),
            const SizedBox(height: 16),
            _infoRow('Valeur de référence', '${piece.referencePinceauxValue} 🖌'),
            _infoRow('Couleur principale', piece.colorPrimary),
            if (piece.colorSecondary != null)
              _infoRow('Couleur secondaire', piece.colorSecondary!),
            if (piece.materialNotes != null)
              _infoRow('Matériau', piece.materialNotes!),
            if (piece.artistNote != null)
              _infoRow('Note de l\'artiste', piece.artistNote!),
            const SizedBox(height: 24),
            Text('Provenance',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 8),
            if (_provenance.isEmpty)
              Text('Encore aucune trace de provenance',
                  style: TextStyle(color: Colors.grey[600]))
            else
              ..._provenance.map((e) => ListTile(
                    leading: Icon(
                      e['event_type'] == 'don_initial'
                          ? Icons.card_giftcard
                          : Icons.swap_horiz,
                    ),
                    title: Text(e['event_type'] == 'don_initial'
                        ? 'Don initial'
                        : 'Échange'),
                    subtitle: Text(_formatDate(e['timestamp'] as String)),
                  )),
            if (!isOwner && piece.currentOwnerId != null) ...[
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: () => Navigator.pushNamed(
                    context,
                    '/make-offer',
                    arguments: piece.id,
                  ),
                  icon: const Icon(Icons.send),
                  label: const Text('Faire une offre'),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 140,
            child: Text(label, style: TextStyle(color: Colors.grey[600])),
          ),
          Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
        ],
      ),
    );
  }

  String _formatDate(String iso) {
    final dt = DateTime.parse(iso);
    return '${dt.day}/${dt.month}/${dt.year}';
  }

  Color _colorFromString(String color) {
    switch (color) {
      case 'blanc': return Colors.grey.shade300;
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
}
