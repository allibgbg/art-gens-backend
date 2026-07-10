# Plan de refonte — Système d'authentification Art-gens

## Problèmes structurels à corriger (par ordre de priorité)

### 1. Normalisation de rotation via le chiffre gravé — BLOQUANT

**Problème :** Grille spatiale fixe (zone[0][0] = "haut gauche écran") → mesure la position à l'écran, pas la position physique sur l'objet. L'objet tenu à la main sera orienté différemment à chaque scan → faux négatifs massifs.

**À faire :**
- Détecter le chiffre gravé (2, 5, 10) sur l'objet par contour/OCR
- Normaliser l'orientation de l'image pour que le chiffre soit toujours dans la même position
- Découper la grille 4×4 après cette normalisation
- Sans ça, rien d'autre n'est fiable

### 2. Séparation référence d'ancrage / référence vivante

**Problème :** La référence est écrasée à chaque scan ≥ 0.65 → dérive cumulative silencieuse.

**À faire :**
- **Référence d'ancrage :** premier scan artiste, jamais écrasée
- **Référence vivante :** mise à jour au fil des trades (tolère usure)
- Comparer chaque scan aux DEUX références
- Seuil d'alerte distinct si écart cumulé à l'ancrage trop grand
- Journaliser chaque mise à jour avec score déclencheur

### 3. Ajouter une composante texture

**Problème :** Centroïde Lab par zone = couleur moyenne, pas la texture. Deux objets avec dégradé similaire peuvent scorer au-dessus du seuil sans être le même objet.

**À faire :**
- Ajouter des descripteurs de texture locale (variance, gradients, LBP)
- À terme : embedding visuel (Siamese network)
- Couleur = filtre de pré-tri, texture = décision finale

### 4. Validation empirique du seuil

**Problème :** Seuil 0.65 choisi arbitrairement, sans données réelles.

**À faire :**
- Constituer un jeu de test avec dizaines d'objets réels
- Calculer faux positifs / faux négatifs pour plusieurs seuils
- Recalibrer après ajout de la texture ET de la normalisation de rotation
- Deux seuils distincts : mise à jour vivante vs tolérance dérive ancrage

## Ordre d'exécution

1. Normalisation de rotation
2. Référence d'ancrage / vivante
3. Composante texture
4. Protocole de test empirique
5. (Optionnel) grille plus fine, segmentation fond

## Notes importantes découvertes pendant l'implémentation

### Rotation normalisation — précisions
- **Le chiffre gravé est identique dans toute une série (même moule).** L'asymétrie 180° ne doit être vérifiée qu'une fois par moule (2, 5, 10, 20), pas par objet. "10" et "20" contiennent un "0" couplé à "1"/"2" → la masse combinée est asymétrique. À confirmer par scan réel d'un moule de chaque série.
- **Rotation 2D uniquement.** L'approche actuelle (moments d'image sur le plan Y) ne corrige que la rotation dans le plan. Les changements d'angle de vue 3D ne sont pas couverts — documenté comme limite dans `rotation_normalizer.dart`.
- **focusFraction=0.5** par défaut : l'analyse du chiffre est restreinte aux 50% centraux du crop 60%, soit ~30% de l'image. Évite la contamination par les bords de la pièce, les doigts, ou les reflets.

### Conséquences sur l'architecture
- **La forme du chiffre ne peut jamais distinguer deux objets d'une même série.** Seule la signature de peinture (couleur + texture) individualise chaque pièce. → Le Point 3 (composante texture) n'est pas une amélioration optionnelle, c'est le fondement de toute authentification intra-série.
- **Le rôle de l'étape 1 est uniquement de normaliser l'orientation** pour que la grille 4×4 soit cohérente entre scans. Elle ne contribue pas à la discrimination.

### Tests
- SDK Dart installé à `$env:USERPROFILE\dart-sdk` (portable, pas admin requis)
- 9 tests unitaires PASS pour `RotationNormalizer.computeAngle` :
  1. Pas de bords → angle 0
  2. Arête horizontale → 0 rad
  3. Arête verticale → π/2 rad
  4. Diagonale 45° → π/4 rad
  5. Diagonale 60° → ~π/3 rad
  6. focusFraction : filtre les bords périphériques
  7. Invariance 180° : diff < 0.15 rad entre forme à 0° et 180°
  8. Contamination : focusFraction isole le signal central
- Les tests chiffres simulés (2, 5, 10, 20) ne sont pas fiables en synthétique pur — validation réelle nécessaire sur scans de vrais moules

## Fichiers impactés

- `mobile/lib/services/rotation_normalizer.dart` — détection d'angle (NOUVEAU)
- `mobile/lib/services/color_extraction.dart` — grille, extraction, signature (MODIFIÉ)
- `mobile/lib/services/multi_angle_scan.dart` — scanner (inchangé)
- `backend/app/services/matching_service.py` — comparaison, seuils, double orientation (MODIFIÉ)
- `backend/app/schemas/piece.py` — modèle de données
- `backend/app/services/piece_service.py` — stockage signature
- `test/rotation_normalizer_test.dart` — tests unitaires
