import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../providers/auth_provider.dart';
import '../providers/pieces_provider.dart';
import '../models/piece.dart';
import 'object_3d_capture_screen.dart';
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
  Widget build(BuildContext context) {
    return Scaffold(
      body: _screens[_currentIndex],
      floatingActionButton: FloatingActionButton.small(
        onPressed: () => Navigator.pushNamed(context, '/first-scan'),
        child: const Icon(Icons.add),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _currentIndex,
        onDestinationSelected: (i) => setState(() => _currentIndex = i),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.collections), label: 'Ma collection'),
          NavigationDestination(icon: Icon(Icons.explore), label: 'Explorer'),
          NavigationDestination(icon: Icon(Icons.account_balance_wallet), label: 'Portefeuille'),
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
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Ma collection')),
      body: Consumer<PiecesProvider>(
        builder: (_, provider, __) {
          final children = <Widget>[
            Padding(
              padding: const EdgeInsets.all(12),
              child: Card(
                color: Colors.amber.shade100,
                child: ListTile(
                  leading: const Icon(Icons.view_in_ar, size: 32),
                  title: const Text('Outil scan 3D (photos live)'),
                  subtitle: const Text('Capture l\'objet sous plusieurs angles'),
                  trailing: const Icon(Icons.arrow_forward_ios),
                onTap: () => Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const Object3DCaptureScreen()),
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
                  subtitle: const Text('Scanne et affiche la fiche de l\'œuf'),
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
  String? _selectedColor;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<PiecesProvider>().loadAllPieces();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Explorer'),
        actions: [
          IconButton(
            icon: const Icon(Icons.filter_list),
            onPressed: _showFilters,
          ),
        ],
      ),
      body: Consumer<PiecesProvider>(
        builder: (_, provider, __) {
          return RefreshIndicator(
            onRefresh: () => provider.loadAllPieces(),
            child: ListView.builder(
              padding: const EdgeInsets.all(8),
              itemCount: provider.pieces.length,
              itemBuilder: (_, i) => ListTile(
                leading: CircleAvatar(
                  backgroundColor: _colorFromString(provider.pieces[i].colorPrimary),
                  child: Text(provider.pieces[i].seriesValue.toString()),
                ),
                title: Text(provider.pieces[i].displayNumber),
                subtitle: Text('Série ${provider.pieces[i].seriesValue}'),
                trailing: Text('${provider.pieces[i].referencePinceauxValue} 🖌'),
                onTap: () => Navigator.pushNamed(
                  context,
                  '/piece-detail',
                  arguments: provider.pieces[i].id,
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  void _showFilters() {
    showModalBottomSheet(
      context: context,
      builder: (_) => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('Filtres', style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 16),
            DropdownButtonFormField<String?>(
              initialValue: _selectedColor,
              decoration: const InputDecoration(labelText: 'Couleur'),
              items: const [
                DropdownMenuItem(value: null, child: Text('Toutes')),
                DropdownMenuItem(value: 'blanc', child: Text('Blanc')),
                DropdownMenuItem(value: 'noir', child: Text('Noir')),
                DropdownMenuItem(value: 'rouge', child: Text('Rouge')),
                DropdownMenuItem(value: 'bleu', child: Text('Bleu')),
                DropdownMenuItem(value: 'vert', child: Text('Vert')),
                DropdownMenuItem(value: 'jaune', child: Text('Jaune')),
                DropdownMenuItem(value: 'multicolore', child: Text('Multicolore')),
              ],
              onChanged: (v) {
                setState(() => _selectedColor = v);
                Navigator.pop(context);
                context.read<PiecesProvider>().loadAllPieces(
                  filters: {
                    if (v != null) 'color_primary': v,
                  },
                );
              },
            ),
          ],
        ),
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

  @override
  Widget build(BuildContext context) {
    return Card(
      child: InkWell(
        onTap: () => Navigator.pushNamed(
          context,
          '/piece-detail',
          arguments: piece.id,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Container(
                decoration: BoxDecoration(
                  color: _colorFromString(piece.colorPrimary),
                  borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
                ),
                child: Center(
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
                  Text('Série ${piece.seriesValue}',
                      style: const TextStyle(fontWeight: FontWeight.bold)),
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
