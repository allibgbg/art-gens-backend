import 'dart:ffi';
import 'package:ffi/ffi.dart';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

// Binding Dart vers le module natif COLMAP (NDK, CPU) compilé en
// libcolmap_ffi.so. Le wrapper exécute le binaire COLMAP (bundlé en asset)
// pour reconstruire un nuage de points sur l'appareil, sans backend.
// Si le .so ou le binaire sont absents, `available` est false et l'app
// retombe sur le backend (pycolmap).

typedef _ReconstructNative = Int32 Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);
typedef _Reconstruct = int Function(
    Pointer<Utf8>, Pointer<Utf8>, Pointer<Utf8>);

class ColmapFfi {
  static DynamicLibrary? _lib;
  static _Reconstruct? _reconstruct;

  static bool get available {
    try {
      _lib ??= DynamicLibrary.open('libcolmap_ffi.so');
      _reconstruct ??=
          _lib!.lookupFunction<_ReconstructNative, _Reconstruct>('colmap_reconstruct');
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Reconstruit sur l'appareil. Retourne :
  ///  0  = succès (model.ply produit dans outputDir)
  /// -1 = erreur COLMAP
  /// -2 = binaire COLMAP non bundlé
  /// -3 = module natif absent
  static Future<int> reconstruct(String imagesDir, String outputDir) async {
    if (!available) return -3;
    final binPath = await _ensureColmapBinary();
    if (binPath == null) return -2;
    return _reconstruct!(
      imagesDir.toNativeUtf8(),
      outputDir.toNativeUtf8(),
      binPath.toNativeUtf8(),
    );
  }

  static Future<String?> _ensureColmapBinary() async {
    try {
      final data = await rootBundle.load('assets/colmap');
      final dir = await getApplicationSupportDirectory();
      final f = File('${dir.path}/colmap');
      if (!f.existsSync() || f.lengthSync() != data.lengthInBytes) {
        await f.writeAsBytes(data.buffer.asUint8List());
        await Process.run('chmod', ['+x', f.path]);
      }
      return f.path;
    } catch (_) {
      return null;
    }
  }
}
