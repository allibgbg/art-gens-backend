import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/api_client.dart';
import 'services/auth_service.dart';
import 'providers/auth_provider.dart';
import 'providers/pieces_provider.dart';
import 'providers/trade_provider.dart';
import 'providers/backend_status.dart';
import 'screens/login_screen.dart';
import 'screens/onboarding_screen.dart';
import 'screens/home_screen.dart';
import 'screens/piece_detail_screen.dart';
import 'screens/make_offer_screen.dart';
import 'screens/digit_scan_screen.dart';
import 'screens/texture_scan_screen.dart';
import 'screens/trade_window_screen.dart';
import 'services/debug_console.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const ArtGensApp());
}

class ArtGensApp extends StatelessWidget {
  const ArtGensApp({super.key});

  @override
  Widget build(BuildContext context) {
    final backendStatus = BackendStatus();
    final apiClient = ApiClient(
      baseUrl: 'https://art-gens-backend.onrender.com',
      backendStatus: backendStatus,
    );
    final authService = AuthService(apiClient);

    return MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: backendStatus),
        Provider.value(value: apiClient),
        Provider.value(value: authService),
        ChangeNotifierProvider(create: (_) => AuthProvider(authService, apiClient)),
        ChangeNotifierProvider(create: (_) => PiecesProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => TradeProvider(apiClient)),
        ChangeNotifierProvider(create: (_) => DebugConsole()),
      ],
      child: SleepingOverlay(
        child: MaterialApp(
          title: 'Art-gens',
          debugShowCheckedModeBanner: false,
          theme: ThemeData(
            colorScheme: ColorScheme.fromSeed(
              seedColor: const Color(0xFF5C4D7D),
            ),
            useMaterial3: true,
          ),
          home: const _AuthGate(),
          onGenerateRoute: _onGenerateRoute,
          builder: (context, child) => DebugOverlay(child: child!),
        ),
      ),
    );
  }

  Route<dynamic>? _onGenerateRoute(RouteSettings settings) {
    switch (settings.name) {
      case '/piece-detail':
        return MaterialPageRoute(
          builder: (_) => PieceDetailScreen(pieceId: settings.arguments as String),
        );
      case '/make-offer':
        return MaterialPageRoute(
          builder: (_) => MakeOfferScreen(targetPieceId: settings.arguments as String),
        );
      case '/first-scan':
        return MaterialPageRoute(
          builder: (_) => const DigitScanScreen(),
        );
      case '/trade':
        return MaterialPageRoute(
          builder: (_) => TradeWindowScreen(tradeSessionId: settings.arguments as String),
        );
      default:
        return null;
    }
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  bool _checking = true;

  @override
  void initState() {
    super.initState();
    context.read<ApiClient>().onAuthError = () {
      context.read<AuthProvider>().logout();
    };
    _check();
  }

  Future<void> _check() async {
    final auth = context.read<AuthProvider>();
    await auth.tryRestoreSession();
    if (mounted) {
      setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_checking) {
      return const Scaffold(
        body: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 24),
              Text(
                'Le réveil du serveur…',
                style: TextStyle(color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600),
                textAlign: TextAlign.center,
              ),
              SizedBox(height: 8),
              Text(
                'Premier démarrage : le backend Render (plan gratuit) se réveille.\nCela peut prendre 30–60 secondes.',
                style: TextStyle(color: Colors.white54, fontSize: 13),
                textAlign: TextAlign.center,
              ),
            ],
          ),
        ),
      );
    }

    return Consumer<AuthProvider>(
      builder: (_, auth, __) {
        if (!auth.isLoggedIn) return const LoginScreen();
        if (auth.needsOnboarding) return const OnboardingScreen();
        return const HomeScreen();
      },
    );
  }
}
