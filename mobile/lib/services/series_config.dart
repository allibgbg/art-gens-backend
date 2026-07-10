/// Configuration de scan par série (chiffre gravé sur l'objet).
/// Ces valeurs doivent être calibrées empiriquement sur l'appareil réel :
/// scanner un objet de chaque série, ajuster [zoom] jusqu'à obtenir une
/// netteté maximale stable, puis ajuster [circleFraction] pour que le
/// cercle de guidage corresponde à la taille apparente de l'objet à ce zoom.
class SeriesScanConfig {
  final double zoom;
  final double circleFraction; // taille du cercle en fraction de min(largeur, hauteur)

  const SeriesScanConfig({required this.zoom, required this.circleFraction});
}

/// Presets par série — VALEURS DE DÉPART À CALIBRER, pas encore vérifiées sur device réel.
const Map<String, SeriesScanConfig> kSeriesScanConfigs = {
  '2': SeriesScanConfig(zoom: 2.0, circleFraction: 0.55),
  '5': SeriesScanConfig(zoom: 1.3, circleFraction: 0.6),
};

/// Preset par défaut si le chiffre n'a pas pu être détecté.
const SeriesScanConfig kDefaultScanConfig = SeriesScanConfig(zoom: 1.0, circleFraction: 0.6);

SeriesScanConfig scanConfigForDigit(String? digit) {
  if (digit == null) return kDefaultScanConfig;
  return kSeriesScanConfigs[digit] ?? kDefaultScanConfig;
}
