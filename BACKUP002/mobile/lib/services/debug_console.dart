import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'error_reporter.dart';

/// Instance partagée afin que les gestionnaires d'erreurs globaux (main.dart)
/// puissent pousser dans la même console que l'arbre de widgets.
final DebugConsole debugConsole = DebugConsole();

class DebugConsole extends ChangeNotifier {
  final List<DebugLogEntry> _entries = [];
  bool _visible = false;

  List<DebugLogEntry> get entries => List.unmodifiable(_entries);
  bool get visible => _visible;

  void toggle() {
    _visible = !_visible;
    notifyListeners();
  }

  void show() {
    _visible = true;
    notifyListeners();
  }

  void hide() {
    _visible = false;
    notifyListeners();
  }

  void log(String message, {String? source, ErrorLevel level = ErrorLevel.info}) {
    _entries.add(DebugLogEntry(
      message: message,
      source: source,
      level: level,
      timestamp: DateTime.now(),
    ));
    if (level == ErrorLevel.error || level == ErrorLevel.warning) {
      reportError(
        message: message,
        source: source,
        level: level == ErrorLevel.error ? 'error' : 'warning',
      );
    }
    notifyListeners();
  }

  void logError(dynamic error, {String? source, StackTrace? stack}) {
    _entries.add(DebugLogEntry(
      message: error.toString(),
      source: source ?? 'unknown',
      level: ErrorLevel.error,
      timestamp: DateTime.now(),
      stackTrace: stack,
    ));
    reportError(
      message: error.toString(),
      source: source ?? 'unknown',
      stack: stack?.toString(),
      level: 'error',
    );
    _visible = true;
    notifyListeners();
  }

  void clear() {
    _entries.clear();
    notifyListeners();
  }

  String get fullText => _entries.map((e) => e.formatted).join('\n');

  static DebugConsole? maybeOf(BuildContext context) {
    try {
      return context.read<DebugConsole>();
    } catch (_) {
      return null;
    }
  }
}

class DebugLogEntry {
  final String message;
  final String? source;
  final ErrorLevel level;
  final DateTime timestamp;
  final StackTrace? stackTrace;

  DebugLogEntry({
    required this.message,
    this.source,
    this.level = ErrorLevel.info,
    required this.timestamp,
    this.stackTrace,
  });

  String get formatted {
    final t = '${timestamp.hour.toString().padLeft(2, '0')}:${timestamp.minute.toString().padLeft(2, '0')}:${timestamp.second.toString().padLeft(2, '0')}';
    final icon = level == ErrorLevel.error ? '❌' : level == ErrorLevel.warning ? '⚠️' : 'ℹ️';
    final src = source != null ? '[$source] ' : '';
    return '$icon $t $src$message';
  }
}

enum ErrorLevel { info, warning, error }

class DebugOverlay extends StatelessWidget {
  final Widget child;

  const DebugOverlay({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        child,
        Positioned(
          right: 0,
          bottom: 0,
          child: Consumer<DebugConsole>(
            builder: (_, console, __) {
              if (!console.visible) return const SizedBox.shrink();
              return GestureDetector(
                onTap: () {},
                child: Container(
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: 300,
                  margin: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.black87,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: Column(
                    children: [
                      _header(context, console),
                      Expanded(child: _logList(console)),
                      _footer(context, console),
                    ],
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }

  Widget _header(BuildContext context, DebugConsole console) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.white24)),
      ),
      child: Row(
        children: [
          const Text('🐛 Debug Console', style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 13)),
          const Spacer(),
          _btn('Clear', () => console.clear()),
          const SizedBox(width: 8),
          _btn('Copy', () {
            Clipboard.setData(ClipboardData(text: console.fullText));
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(content: Text('Log copié !'), duration: Duration(seconds: 1)),
            );
          }),
          const SizedBox(width: 8),
          _btn('✕', () => console.hide()),
        ],
      ),
    );
  }

  Widget _btn(String label, VoidCallback onTap) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
        decoration: BoxDecoration(
          color: Colors.white12,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(label, style: const TextStyle(color: Colors.white70, fontSize: 11)),
      ),
    );
  }

  Widget _logList(DebugConsole console) {
    return ListView.builder(
      itemCount: console.entries.length,
      itemBuilder: (_, i) {
        final e = console.entries[i];
        final color = e.level == ErrorLevel.error
            ? Colors.red[300]
            : e.level == ErrorLevel.warning
                ? Colors.amber[300]
                : Colors.white70;
        return Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 1),
          child: Text(
            e.formatted,
            style: TextStyle(color: color, fontSize: 10, fontFamily: 'monospace'),
          ),
        );
      },
    );
  }

  Widget _footer(BuildContext context, DebugConsole console) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Colors.white24)),
      ),
      child: Text(
        '${console.entries.length} entrées',
        style: const TextStyle(color: Colors.white38, fontSize: 10),
      ),
    );
  }
}
