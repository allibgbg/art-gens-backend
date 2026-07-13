import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

/// Échantillon de la base (fond poncé) d'un œuf : descripteurs ORB binaires
/// + points-clés, sérialisables pour stockage local et comparaison Dart.
class EggBaseSample {
  final List<List<int>> descriptors; // chaque descripteur = 32 octets (0..255)
  final List<Map<String, dynamic>> keypoints; // {x,y,response}
  final int keypointsCount;
  final double sharpness;

  const EggBaseSample({
    required this.descriptors,
    required this.keypoints,
    required this.keypointsCount,
    required this.sharpness,
  });

  Map<String, dynamic> toJson() => {
        'descriptors': descriptors,
        'keypoints': keypoints,
        'keypoints_count': keypointsCount,
        'sharpness': sharpness,
      };

  factory EggBaseSample.fromJson(Map<String, dynamic> json) => EggBaseSample(
        descriptors: (json['descriptors'] as List)
            .map((e) => (e as List).map((v) => (v as num).toInt()).toList())
            .toList(),
        keypoints: (json['keypoints'] as List)
            .map((e) => Map<String, dynamic>.from(e as Map))
            .toList(),
        keypointsCount: (json['keypoints_count'] as num).toInt(),
        sharpness: (json['sharpness'] as num).toDouble(),
      );
}

/// Référence officielle d'un œuf, stockée LOCALEMENT sur l'appareil.
class EggReference {
  final String digit;
  final List<double> hu; // signature Hu du chiffre gravé (moule)
  final EggBaseSample base;
  final Map<String, dynamic> colorSignature; // SpatialSignature.toJson()
  final int createdAt;

  const EggReference({
    required this.digit,
    required this.hu,
    required this.base,
    required this.colorSignature,
    required this.createdAt,
  });

  Map<String, dynamic> toJson() => {
        'digit': digit,
        'hu': hu,
        'base': base.toJson(),
        'color_signature': colorSignature,
        'created_at': createdAt,
      };

  factory EggReference.fromJson(Map<String, dynamic> json) => EggReference(
        digit: json['digit'] as String,
        hu: (json['hu'] as List).map((e) => (e as num).toDouble()).toList(),
        base: EggBaseSample.fromJson(json['base'] as Map<String, dynamic>),
        colorSignature: json['color_signature'] as Map<String, dynamic>,
        createdAt: (json['created_at'] as num).toInt(),
      );
}

/// Coffre-fort local des références d'œufs (un fichier JSON par chiffre 2/5).
/// Aucun serveur : tout reste sur l'appareil.
class EggVault {
  static Future<String> _path(String digit) async {
    final dir = await getApplicationDocumentsDirectory();
    return '${dir.path}/egg_ref_$digit.json';
  }

  static Future<EggReference?> load(String digit) async {
    try {
      final file = File(await _path(digit));
      if (!await file.exists()) return null;
      final json =
          jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      return EggReference.fromJson(json);
    } catch (_) {
      return null;
    }
  }

  static Future<List<EggReference>> loadAll() async {
    final List<EggReference> out = [];
    for (final d in ['2', '5']) {
      final ref = await load(d);
      if (ref != null) out.add(ref);
    }
    return out;
  }

  static Future<void> save(EggReference ref) async {
    final file = File(await _path(ref.digit));
    await file.writeAsString(jsonEncode(ref.toJson()));
  }

  static Future<bool> has(String digit) async {
    final file = File(await _path(digit));
    return file.exists();
  }
}
