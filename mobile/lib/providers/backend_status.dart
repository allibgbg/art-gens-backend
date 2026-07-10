import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

class BackendStatus extends ChangeNotifier {
  bool _sleeping = false;

  bool get sleeping => _sleeping;

  void markSleeping() {
    if (!_sleeping) {
      _sleeping = true;
      notifyListeners();
    }
  }

  void markAwake() {
    if (_sleeping) {
      _sleeping = false;
      notifyListeners();
    }
  }
}

class SleepingOverlay extends StatelessWidget {
  final Widget child;

  const SleepingOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Stack(
      children: [
        child,
        Consumer<BackendStatus>(
          builder: (_, status, __) {
            if (!status.sleeping) return const SizedBox.shrink();
            return Container(
              color: Colors.black54,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(Icons.hourglass_bottom, size: 64, color: Colors.white),
                    const SizedBox(height: 16),
                    Text(
                      'Réveil du serveur en cours...',
                      style: const TextStyle(color: Colors.white, fontSize: 18),
                    ),
                    const SizedBox(height: 32),
                    const SizedBox(
                      width: 24,
                      height: 24,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
      ),
    );
  }
}
