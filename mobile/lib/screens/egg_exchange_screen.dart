import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/pieces_provider.dart';
import '../providers/egg_offers_provider.dart';

class EggExchangeScreen extends StatefulWidget {
  final String targetEggId;
  final String targetEggDisplay;

  const EggExchangeScreen({
    super.key,
    required this.targetEggId,
    required this.targetEggDisplay,
  });

  @override
  State<EggExchangeScreen> createState() => _EggExchangeScreenState();
}

class _EggExchangeScreenState extends State<EggExchangeScreen> {
  String? _selectedEggId;
  int _pinceaux = 0;
  bool _sending = false;

  @override
  Widget build(BuildContext context) {
    final pieces = context.watch<PiecesProvider>();
    final myEggs = pieces.myPieces.where((p) => p.id.startsWith('egg_')).toList();

    return Scaffold(
      appBar: AppBar(
        title: Text('Échanger pour ${widget.targetEggDisplay}'),
      ),
      body: myEggs.isEmpty
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.inventory_2, size: 64, color: Colors.grey),
                  SizedBox(height: 16),
                  Text('Tu n\'as aucune pierre à échanger.'),
                  Text('Scanne une pierre pour la réclamer d\'abord.'),
                ],
              ),
            )
          : Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Choisis la pierre que tu proposes :',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 12),
                  Expanded(
                    child: GridView.builder(
                      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: 2,
                        childAspectRatio: 0.85,
                        crossAxisSpacing: 8,
                        mainAxisSpacing: 8,
                      ),
                      itemCount: myEggs.length,
                      itemBuilder: (_, i) {
                        final egg = myEggs[i];
                        final hasPhoto = egg.photoUrl != null &&
                            (egg.photoUrl!.startsWith('/') || egg.photoUrl!.contains('\\'));
                        final selected = _selectedEggId == egg.id;
                        return GestureDetector(
                          onTap: () => setState(() => _selectedEggId = egg.id),
                          child: Card(
                            color: selected
                                ? Theme.of(context).colorScheme.primaryContainer
                                : null,
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(12),
                              side: selected
                                  ? BorderSide(
                                      color: Theme.of(context).colorScheme.primary,
                                      width: 2,
                                    )
                                  : BorderSide.none,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Expanded(
                                  child: hasPhoto
                                      ? ClipRRect(
                                          borderRadius: const BorderRadius.vertical(
                                            top: Radius.circular(12),
                                          ),
                                          child: Image.file(
                                            File(egg.photoUrl!),
                                            fit: BoxFit.cover,
                                          ),
                                        )
                                      : Container(
                                          decoration: BoxDecoration(
                                            color: Colors.purple.shade200,
                                            borderRadius: const BorderRadius.vertical(
                                              top: Radius.circular(12),
                                            ),
                                          ),
                                          child: Center(
                                            child: Text(
                                              egg.displayNumber,
                                              style: const TextStyle(
                                                fontSize: 20,
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
                                    children: [
                                      Text(
                                        egg.displayNumber,
                                        style: const TextStyle(fontWeight: FontWeight.bold),
                                      ),
                                      Text(
                                        '${egg.referencePinceauxValue} 🖌',
                                        style: TextStyle(
                                          color: Colors.grey[600],
                                          fontSize: 12,
                                        ),
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
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Icon(Icons.brush, size: 20),
                      const SizedBox(width: 8),
                      const Text('Pinceaux supplémentaires :'),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Slider(
                          value: _pinceaux.toDouble(),
                          min: 0,
                          max: 200,
                          divisions: 20,
                          label: '$_pinceaux',
                          onChanged: (v) => setState(() => _pinceaux = v.round()),
                        ),
                      ),
                      SizedBox(
                        width: 50,
                        child: Text(
                          '$_pinceaux',
                          textAlign: TextAlign.center,
                          style: const TextStyle(fontWeight: FontWeight.bold),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: (_selectedEggId != null && !_sending)
                        ? _sendOffer
                        : null,
                    child: _sending
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Envoyer la proposition'),
                  ),
                ],
              ),
            ),
    );
  }

  Future<void> _sendOffer() async {
    if (_selectedEggId == null) return;
    setState(() => _sending = true);

    final offers = context.read<EggOffersProvider>();
    final offer = await offers.createOffer(
      targetEggId: widget.targetEggId,
      offeredEggId: _selectedEggId!,
      offeredPinceaux: _pinceaux,
    );

    if (mounted) {
      setState(() => _sending = false);
      if (offer != null) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Proposition envoyée !')),
        );
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Erreur lors de l\'envoi')),
        );
      }
    }
  }
}
