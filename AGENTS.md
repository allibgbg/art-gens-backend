# Projet Art-Gens

## Stack
- **Mobile**: Flutter (`D:\art-gens\mobile`)
- **Backend**: Python FastAPI (`D:\art-gens\backend`)
- **Base**: SQLite en dev, PostgreSQL en prod (Render)
- **Hébergement backend**: Render.com → `https://art-gens-backend.onrender.com`
- **GitHub backend**: `https://github.com/allibgbg/art-gens-backend.git`
- **Build APK**: `cd mobile && $env:JAVA_HOME = "D:\android-sdk\jdk17\jdk-17.0.2" && flutter build apk --debug`
- **APK output**: `mobile/build/app/outputs/flutter-apk/app-debug.apk`
- **Backend ZIP**: `D:\art-gens\backend.zip` (compresser depuis `D:\art-gens\backend\`)

## Flux de création d'une pièce (3 phases scan auto + finalisation)

### Routes API
1. `POST /pieces/draft` → crée un draft avec texture_signature → retourne `{id, status}`
2. `PATCH /pieces/{id}` → ajoute top_image, color_signature
3. `POST /pieces/{id}/finalize` → finalise avec display_number, series_value, etc.

### Ordre des phases (dans le mobile)
1. **Phase 1** - `DigitScanScreen` : photo dessus, détection du chiffre gravé (2/5) par moments de Hu → `top_image` + `digit_guess` (transmis à Phase 2)
2. **Phase 2** - `TextureScanScreen` : scan du fond poncé (ORB + CLAHE), **verrouillage de la MAP dès 72% de netteté** (sharpnessRatioInFixedCircle, au centre), `fillRatio >= 0.70`, top 256 keypoints, stabilité 2s → `POST /draft` → auto-next
3. **Phase 3** - `RotationScanScreen` : scan rotation complète, signature couleur **4×4** via `MultiAngleScanner` → `PATCH color_signature` → auto-next
4. **Phase 4** - `FinalizePieceScreen` : formulaire métadonnées → `POST /finalize`

### Règles absolues
- **Zéro bouton** pendant les 3 phases scan (utilisateur a les 2 mains sur l'objet)
- Erreur → auto-retry 2s (max 3 tentatives) → erreur permanente
- Décision serveur uniquement (matching jamais trusté coté client)
- `AdaptiveSharpnessGate` : calibration 20s, seuil plancher 1.8, ratio 70% du max

## Points sensibles déjà corrigés

### Route ordering (CRITIQUE)
FastAPI/Starlette matche le PATH avant la METHOD. Si `GET /{piece_id}` est déclaré avant `POST /draft`, une requête POST /pieces/draft match le path `/{piece_id}` avec piece_id="draft" → retourne 405 sans vérifier les routes suivantes.

**Règle :** toujours déclarer les routes à chemin fixe (`/draft`, `/`) AVANT les routes paramétrées (`/{piece_id}`, `/{piece_id}/scan`).

### Champs requis du modèle Piece
Le modèle SQL a `display_number`, `series_value`, `reference_pinceaux_value`, `color_primary` en `nullable=False`. Le draft endpoint doit fournir des placeholders :
- `display_number = pid[:10]` (préfixe de l'UUID)
- `series_value = 0`
- `reference_pinceaux_value = 0`
- `color_primary = ColorEnum.multicolore`

### Hu moments manuels
`dartcv4-1.1.8` n'exporte pas `HuMoments`. Les 7 formules de Hu sont implémentées manuellement dans `digit_scan_screen.dart` à partir des moments normalisés (`nu20`, `nu02`, `nu11`, `nu30`, `nu12`, `nu21`, `nu03`).

## Pour déployer

### Backend (Render)
```bash
# Depuis une machine avec git:
cd D:\art-gens\backend
git add -A
git commit -m "fix: route order, draft placeholders, retry limit"
git push origin main
# Render déploie automatiquement (auto-deploy)
```

### Mobile (APK)
```bash
cd D:\art-gens\mobile
$env:JAVA_HOME = "D:\android-sdk\jdk17\jdk-17.0.2"
flutter build apk --debug
# Installer build\app\outputs\flutter-apk\app-debug.apk sur le téléphone
```

## Fichiers clés
- `backend/app/routers/pieces.py` — routes API pieces (draft, patch, finalize, scan)
- `backend/app/services/matching_service.py` — matching (Hu + LBP + texture)
- `backend/app/services/piece_service.py` — CRUD pieces
- `backend/app/models/piece.py` — modèle SQL Piece
- `mobile/lib/screens/texture_scan_screen.dart` — Phase 1
- `mobile/lib/screens/digit_scan_screen.dart` — Phase 2
- `mobile/lib/screens/rotation_scan_screen.dart` — Phase 3
- `mobile/lib/screens/finalize_piece_screen.dart` — Phase 4
- `mobile/lib/services/texture_extraction.dart` — ORB + CLAHE + AdaptiveSharpnessGate
- `mobile/lib/main.dart` — routes et baseUrl
