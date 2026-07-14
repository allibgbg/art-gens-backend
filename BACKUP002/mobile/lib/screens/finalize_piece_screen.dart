import 'package:flutter/material.dart';
import '../services/api_client.dart';
import '../services/error_reporter.dart';
import '../providers/auth_provider.dart';
import 'package:provider/provider.dart';

class FinalizePieceScreen extends StatefulWidget {
  final String pieceId;
  final String? digitGuess;
  const FinalizePieceScreen({super.key, required this.pieceId, this.digitGuess});

  @override
  State<FinalizePieceScreen> createState() => _FinalizePieceScreenState();
}

class _FinalizePieceScreenState extends State<FinalizePieceScreen> {
  final _formKey = GlobalKey<FormState>();
  final _seriesCtrl = TextEditingController(text: '1');
  final _pinceauxCtrl = TextEditingController(text: '100');
  final _notesCtrl = TextEditingController();
  final _artistNoteCtrl = TextEditingController();
  bool _saving = false;
  String? _generatedNumber;

  @override
  void initState() {
    super.initState();
    final pseudo = context.read<AuthProvider>().user?.pseudo?.toUpperCase() ?? 'ART';
    _generatedNumber = '$pseudo-${DateTime.now().millisecondsSinceEpoch}';
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      final api = context.read<ApiClient>();
      await api.post('/pieces/${widget.pieceId}/finalize', body: {
        'display_number': _generatedNumber,
        'series_value': int.parse(_seriesCtrl.text),
        'reference_pinceaux_value': int.parse(_pinceauxCtrl.text),
        'color_primary': 'multicolore',
        'material_notes': _notesCtrl.text.isEmpty ? null : _notesCtrl.text,
        'artist_note': _artistNoteCtrl.text.isEmpty ? null : _artistNoteCtrl.text,
      });
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Pièce $_generatedNumber créée !')),
        );
        Navigator.pushReplacementNamed(context, '/home');
      }
    } catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        showErrorDialog(context, e, source: 'finalize');
      }
    }
  }

  @override
  void dispose() {
    _seriesCtrl.dispose(); _pinceauxCtrl.dispose();
    _notesCtrl.dispose(); _artistNoteCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Finaliser la pièce')),
      body: Padding(
        padding: const EdgeInsets.all(24),
        child: Form(
          key: _formKey,
          child: ListView(children: [
            // Gauge 100%
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: const LinearProgressIndicator(
                value: 1.0, minHeight: 16, backgroundColor: Colors.white24,
                valueColor: AlwaysStoppedAnimation<Color>(Colors.green),
              ),
            ),
            const SizedBox(height: 6),
            Text('Scan complet — 100%   ${widget.digitGuess != null ? 'Chiffre ${widget.digitGuess} détecté' : ''}',
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold, color: Colors.green),
            ),
            const SizedBox(height: 24),

            TextFormField(
              decoration: const InputDecoration(labelText: 'Numéro d\'affichage', border: OutlineInputBorder()),
              initialValue: _generatedNumber,
              enabled: false,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _seriesCtrl,
              decoration: const InputDecoration(labelText: 'Série', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _pinceauxCtrl,
              decoration: const InputDecoration(labelText: 'Valeur (Pinceaux)', border: OutlineInputBorder()),
              keyboardType: TextInputType.number,
              validator: (v) => (v == null || v.isEmpty) ? 'Requis' : null,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _notesCtrl,
              decoration: const InputDecoration(labelText: 'Notes matériaux (optionnel)', border: OutlineInputBorder()),
              maxLines: 2,
            ),
            const SizedBox(height: 16),

            TextFormField(
              controller: _artistNoteCtrl,
              decoration: const InputDecoration(labelText: 'Note artiste (optionnel)', border: OutlineInputBorder()),
              maxLines: 3,
            ),
            const SizedBox(height: 24),

            SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                onPressed: _saving ? null : _submit,
                icon: _saving
                    ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Icon(Icons.check),
                label: Text(_saving ? 'Création...' : 'Créer la pièce'),
                style: ElevatedButton.styleFrom(padding: const EdgeInsets.symmetric(vertical: 16)),
              ),
            ),
          ]),
        ),
      ),
    );
  }
}
