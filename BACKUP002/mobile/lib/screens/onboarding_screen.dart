import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';

class OnboardingScreen extends StatefulWidget {
  const OnboardingScreen({super.key});

  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _pseudoCtrl = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _isLoading = false;

  @override
  void dispose() {
    _pseudoCtrl.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _isLoading = true);

    final ok = await context.read<AuthProvider>().setPseudo(_pseudoCtrl.text.trim());
    if (ok) {
      await context.read<AuthProvider>().completeOnboarding();
      if (mounted) {
        Navigator.pushReplacementNamed(context, '/first-scan');
      }
    } else {
      if (mounted) {
        setState(() => _isLoading = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Ce pseudo est déjà pris')),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.palette, size: 64, color: Colors.grey),
                const SizedBox(height: 24),
                Text(
                  'Bienvenue dans Art-gens',
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
                const SizedBox(height: 8),
                Text(
                  'Choisis ton pseudo',
                  style: TextStyle(color: Colors.grey[600]),
                ),
                const SizedBox(height: 24),
                TextFormField(
                  controller: _pseudoCtrl,
                  decoration: const InputDecoration(
                    labelText: 'Pseudo',
                    border: OutlineInputBorder(),
                    hintText: 'Ton identifiant unique',
                  ),
                  validator: (v) {
                    if (v == null || v.trim().length < 2) return 'Minimum 2 caractères';
                    return null;
                  },
                ),
                const SizedBox(height: 24),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton(
                    onPressed: _isLoading ? null : _submit,
                    child: _isLoading
                        ? const SizedBox(
                            width: 20, height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('C\'est parti !'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
