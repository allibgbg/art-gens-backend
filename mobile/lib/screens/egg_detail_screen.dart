import 'dart:io';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../models/piece.dart';
import '../providers/auth_provider.dart';
import '../providers/pieces_provider.dart';

class EggDetailScreen extends StatefulWidget {
  final String eggId;

  const EggDetailScreen({super.key, required this.eggId});

  @override
  State<EggDetailScreen> createState() => _EggDetailScreenState();
}

class _EggDetailScreenState extends State<EggDetailScreen> {
  Piece? _egg;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final provider = context.read<PiecesProvider>();
    final egg = provider.eggPieces.firstWhere(
      (p) => p.id == widget.eggId,
      orElse: () => provider.myPieces.firstWhere(
        (p) => p.id == widget.eggId,
        orElse: () => Piece(
          id: '',
          displayNumber: '?',
          seriesValue: 0,
          referencePinceauxValue: 0,
          colorPrimary: 'multicolore',
        ),
      ),
    );
    if (mounted) {
      setState(() {
        _egg = egg;
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }

    final egg = _egg;
    if (egg == null || egg.id.isEmpty) {
      return const Scaffold(body: Center(child: Text('Pierre introuvable')));
    }

    final userId = context.watch<AuthProvider>().user?.id;
    final isOwner = egg.currentOwnerId == userId;
    final hasOwner = egg.currentOwnerId != null;
    final canExchange = hasOwner && !isOwner;

    final hasPhoto = egg.photoUrl != null &&
        (egg.photoUrl!.startsWith('/') || egg.photoUrl!.contains('\\'));

    return Scaffold(
      appBar: AppBar(
        title: Text(egg.displayNumber),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (hasPhoto)
              Center(
                child: Container(
                  width: 200,
                  height: 200,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(16),
                    image: DecorationImage(
                      image: FileImage(File(egg.photoUrl!)),
                      fit: BoxFit.cover,
                    ),
                  ),
                ),
              )
            else
              Center(
                child: Container(
                  width: 200,
                  height: 200,
                  margin: const EdgeInsets.only(bottom: 20),
                  decoration: BoxDecoration(
                    color: Colors.purple.shade200,
                    borderRadius: BorderRadius.circular(16),
                  ),
                  child: Center(
                    child: Text(
                      egg.displayNumber,
                      style: const TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ),
              ),
            Text(
              egg.displayNumber,
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 4),
            if (egg.materialNotes != null && egg.materialNotes!.isNotEmpty)
              Text(
                egg.materialNotes!,
                style: const TextStyle(color: Colors.white70, fontSize: 16),
                textAlign: TextAlign.center,
              ),
            const SizedBox(height: 24),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  children: [
                    _infoRow('Série', '${egg.seriesValue}'),
                    _infoRow('Pinceaux', '${egg.referencePinceauxValue} 🖌'),
                    _infoRow(
                      'Créé le',
                      '${egg.creationDate.day}/${egg.creationDate.month}/${egg.creationDate.year}',
                    ),
                    _infoRow(
                      'Propriétaire',
                      isOwner
                          ? 'Vous'
                          : hasOwner
                              ? 'Autre utilisateur'
                              : 'Non réclamée',
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 24),
            if (canExchange)
              FilledButton.icon(
                onPressed: () => Navigator.pushNamed(
                  context,
                  '/egg-exchange',
                  arguments: {
                    'targetEggId': egg.id.replaceFirst('egg_', ''),
                    'targetEggDisplay': egg.displayNumber,
                  },
                ),
                icon: const Icon(Icons.swap_horiz),
                label: const Text('Proposer un échange'),
              ),
            if (!hasOwner && userId != null)
              OutlinedButton.icon(
                onPressed: () async {
                  final confirmed = await showDialog<bool>(
                    context: context,
                    builder: (_) => AlertDialog(
                      title: const Text('Réclamer cette pierre ?'),
                      content: Text(
                        'Tu vas réclamer ${egg.displayNumber}.\n'
                        'Elle sera ajoutée à ta collection.',
                      ),
                      actions: [
                        TextButton(
                          onPressed: () => Navigator.pop(context, false),
                          child: const Text('Annuler'),
                        ),
                        FilledButton(
                          onPressed: () => Navigator.pop(context, true),
                          child: const Text('Réclamer'),
                        ),
                      ],
                    ),
                  );
                  if (confirmed == true && context.mounted) {
                    final success = await context.read<PiecesProvider>().claimEgg(egg.id);
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        SnackBar(
                          content: Text(
                            success ? '${egg.displayNumber} réclamée !' : 'Erreur lors du claim',
                          ),
                        ),
                      );
                      if (success) Navigator.pop(context);
                    }
                  }
                },
                icon: const Icon(Icons.add_circle_outline),
                label: const Text('Réclamer cette pierre'),
              ),
            if (isOwner)
              Card(
                color: Colors.green.withOpacity(0.1),
                child: const ListTile(
                  leading: Icon(Icons.check_circle, color: Colors.green),
                  title: Text('Cette pierre est dans ta collection'),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _infoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          SizedBox(
            width: 120,
            child: Text(label, style: const TextStyle(color: Colors.white54)),
          ),
          Expanded(
            child: Text(value, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        ],
      ),
    );
  }
}
