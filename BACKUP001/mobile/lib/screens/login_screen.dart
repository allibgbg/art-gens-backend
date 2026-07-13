import 'dart:math';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:google_sign_in/google_sign_in.dart';
import '../providers/auth_provider.dart';
import '../services/debug_console.dart';
import '../services/error_reporter.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  late final String _subtitle;

  static const _subtitles = [
    'le lard et les gants',
    'hasard chenapan',
    'l\'histoire de maintenant',
    'la suite des mouvements',
    'une histoire sans francs',
  ];

  @override
  void initState() {
    super.initState();
    _subtitle = _subtitles[Random().nextInt(_subtitles.length)];
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 32),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                'Art-gens',
                style: Theme.of(context).textTheme.displaySmall?.copyWith(
                  fontWeight: FontWeight.bold,
                  letterSpacing: 2,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                _subtitle,
                style: TextStyle(color: Colors.grey[500], fontSize: 16),
              ),
              const SizedBox(height: 48),
              Consumer<AuthProvider>(
                builder: (_, auth, __) => SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: auth.isLoading ? null : () => _loginGoogle(context),
                    icon: auth.isLoading
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.g_mobiledata, size: 28),
                    label: Text(auth.isLoading ? 'Connexion...' : 'Continuer avec Google'),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(vertical: 14),
                    ),
                  ),
                ),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.facebook, size: 28),
                  label: const Text('Continuer avec Facebook'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _loginGoogle(BuildContext context) async {
    try {
      const String serverClientId = '587473932277-left98jqiqapvmok3h9nmq2b36h436a9.apps.googleusercontent.com';
      final googleSignIn = GoogleSignIn(
        scopes: ['email', 'profile'],
        serverClientId: serverClientId,
      );
      final account = await googleSignIn.signIn();
      if (account == null) return;

      final auth = await account.authentication;
      final idToken = auth.idToken;
      if (idToken == null) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Erreur: ID token Google introuvable')),
          );
        }
        return;
      }

      final authProvider = context.read<AuthProvider>();
      final success = await authProvider.loginWithGoogle(idToken);
      if (!success && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(authProvider.error ?? 'Erreur de connexion')),
        );
      }
    } catch (e) {
      if (context.mounted) {
        showErrorDialog(context, e, source: 'login-google');
      }
    }
  }
}
