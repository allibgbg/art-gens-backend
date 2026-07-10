import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/pieces_provider.dart';
import '../services/api_client.dart';

class MakeOfferScreen extends StatefulWidget {
  final String targetPieceId;
  const MakeOfferScreen({super.key, required this.targetPieceId});

  @override
  State<MakeOfferScreen> createState() => _MakeOfferScreenState();
}

class _MakeOfferScreenState extends State<MakeOfferScreen> {
  String? _selectedMyPieceId;
  int _offeredPinceaux = 0;
  bool _isSubmitting = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PiecesProvider>().loadMyPieces();
    });
  }

  Future<void> _submit() async {
    if (_selectedMyPieceId == null) return;
    setState(() => _isSubmitting = true);

    try {
      final api = context.read<ApiClient>();
      await api.post('/offers/', body: {
        'target_piece_id': widget.targetPieceId,
        'offered_piece_id': _selectedMyPieceId,
        'offered_pinceaux': _offeredPinceaux,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Offre envoyée !')),
        );
        Navigator.pop(context);
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Erreur: $e')),
        );
        setState(() => _isSubmitting = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myPieces = context.watch<PiecesProvider>().myPieces;

    return Scaffold(
      appBar: AppBar(title: const Text('Faire une offre')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Objet proposé en échange',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            if (myPieces.isEmpty)
              const Text('Tu n\'as aucun objet à proposer')
            else
              DropdownButtonFormField<String>(
                initialValue: _selectedMyPieceId,
                items: myPieces.map((p) => DropdownMenuItem(
                  value: p.id,
                  child: Text('${p.displayNumber} (série ${p.seriesValue})'),
                )).toList(),
                onChanged: (v) => setState(() => _selectedMyPieceId = v),
                decoration: const InputDecoration(border: OutlineInputBorder()),
              ),
            const SizedBox(height: 24),
            Text('Ajustement en pinceaux',
                style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            TextField(
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Pinceaux (0 à l\'infini)',
                border: OutlineInputBorder(),
              ),
              onChanged: (v) => _offeredPinceaux = int.tryParse(v) ?? 0,
            ),
            const SizedBox(height: 32),
            SizedBox(
              width: double.infinity,
              child: FilledButton(
                onPressed: (_selectedMyPieceId != null && !_isSubmitting)
                    ? _submit
                    : null,
                child: _isSubmitting
                    ? const CircularProgressIndicator(strokeWidth: 2)
                    : const Text('Envoyer l\'offre'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
