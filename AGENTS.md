# Projet Art-Gens

## Stack
- **Mobile**: Flutter (`D:\art-gens\mobile`)
- **Backend**: Python FastAPI (`D:\art-gens\backend`)
- **Base**: SQLite en dev, PostgreSQL en prod (Render)
- **OpenCV mobile**: `dartcv4 1.1.8` + `opencv_dart 1.4.5`
- **Hébergement backend**: Render.com → `https://art-gens-backend.onrender.com`
- **Repo git**: `D:\art-gens` → remote `origin` → branche `main` → Render auto-deploy
- **Admin email**: `robert.marmouth@gmail.com`

## Conventions de build

### Admin APK — "ADMIN GENS" (toute la logique admin)
```powershell
$env:PATH="D:\flutter_sdk\flutter\bin;$env:PATH"
$env:ANDROID_HOME="D:\android-sdk"
cd D:\art-gens\mobile
flutter build apk --debug --dart-define=ADMIN_BUILD=true -PadminBuild=true
# Sortie: build\app\outputs\flutter-apk\app-debug.apk
Copy-Item "build\app\outputs\flutter-apk\app-debug.apk" "build\app\outputs\flutter-apk\admin-debug.apk" -Force
```

### Lambda APK — "ART GENS" (AUCUN code admin)
```powershell
$env:PATH="D:\flutter_sdk\flutter\bin;$env:PATH"
$env:ANDROID_HOME="D:\android-sdk"
cd D:\art-gens\mobile
flutter build apk --debug
# Sortie: build\app\outputs\flutter-apk\app-debug.apk
Copy-Item "build\app\outputs\flutter-apk\app-debug.apk" "build\app\outputs\flutter-apk\lambda-debug.apk" -Force
```

**IMPORTANT**: `flutter build` écrase toujours `app-debug.apk`. Il faut renommer/copy immédiatement après chaque build. Les deux builds sont indépendants.

### Backend (Render)
```bash
cd D:\art-gens
git add -A
git commit -m "..."
git push origin main
# Render déploie automatiquement
```

## Deux APK : Admin vs Lambda

- `config.dart` → `kAdminBuild = bool.fromEnvironment('ADMIN_BUILD')`
- `auth_provider.dart` → `isAdmin = kAdminBuild && email == 'robert.marmouth@gmail.com'`
- Le build lambda ne contient **AUCUN** code admin (sécurité compile-time).
- Les écrans admin (enrollment, édition, suppression) sont conditionnés par `auth.isAdmin`.

## Modèle Egg Identity (100% serveur)

### Table `egg_identities` (SQLAlchemy)
| Colonne | Type | Description |
|---------|------|-------------|
| `id` | VARCHAR(36) PK | UUID |
| `display_number` | VARCHAR(32) | Numéro d'affichage (ex: "2-124") |
| `series_value` | INTEGER | Série (2, 5, 10, 20) |
| `reference_pinceaux_value` | INTEGER | Nombre de pinceaux, défaut 0 |
| `digit_number` | VARCHAR(16) | Numéro du chiffre |
| `notes` | TEXT | Notes libres (ancien champ "Nom") |
| `face_photo` | TEXT | Photo de face en base64 JPEG |
| `identity_data` | JSON | Carte SIFT (version, image_w, image_h, quality, points: [...]) |
| `created_at` | DATETIME | Timestamp création |
| `created_by` | VARCHAR(36) | User ID créateur |

### Endpoints API
| Méthode | Route | Description |
|---------|-------|-------------|
| `POST` | `/egg-identity/` | Créer un œuf (enrollment) |
| `GET` | `/egg-identity/?series_value=X` | Lister (optionnel: filtrer par série) |
| `GET` | `/egg-identity/{id}` | Détail (inclut `face_photo` + `identity_data`) |
| `PATCH` | `/egg-identity/{id}` | Modifier (inclut `face_photo` pour remplacer la photo) |
| `DELETE` | `/egg-identity/{id}` | Supprimer |

**NOTE**: Le endpoint list (`GET /egg-identity/`) ne renvoie **PAS** `identity_data` (optimisation). Le endpoint détail (`GET /egg-identity/{id}`) le renvoie.

## Flux Enrollment (enregistrement œuf)
1. **Étape 0**: Photo de face → `cropEgg()` → 512×512 fond blanc
2. **Étape 1**: 3-5 photos de la base (SIFT extraction → 120 points)
3. **Étape 2**: Formulaire : Série (2/5/10/20), Numéro, Nom, Valeur pinceaux
4. **Upload**: POST `/egg-identity/` avec base64 face_photo + identity_data JSON
5. **Stock**: 100% serveur, plus de `local_eggs.json`

## cropEgg() — Fonction top-level partagée

**Fichier**: `egg_base_scan_screen.dart` (ligne 574)
**Utilisée par**: `egg_base_scan_screen.dart` (enrollment) + `home_screen.dart` (_RetakeFacePhotoScreen)

Pipeline:
1. Canny(30, 80) → dilate ellipse(15,15) → findContours → plus gros contour centré
2. Masque filled → érosion ellipse(7,7) (supprime halo gris)
3. `bitwiseAND(colorMat, colorMat, mask)` → egg on black
4. `subtract(white, mask)` → invMask → `bitwiseAND(whiteBgr, whiteBgr, mask: invMask)` → bgWhite
5. `bitwiseOR(eggOnBlack, bgWhite)` → compositing final
6. Crop bounding rect + 3% padding → resize longSide=90% de 512 → canvas blanc 512×512

**Bug corrigé (use-after-free)**: `white.region()` retourne un sub-matrix (pointe sur les mêmes données que `white`). Il ne faut PAS `white.dispose()` avant d'avoir fini avec le sub-matrix. Fix: `white.dispose()` APRES `cv.resize()`.

## Vérification (authentification)

**Fichier**: `egg_verify_screen.dart`
1. **Sélecteur de série**: 4 boutons (2/5/10/20)
2. `_loadIdentities(series)`: fetch list par `series_value` → GET détail individuel pour chaque œuf (car list endpoint ne renvoie pas `identity_data`)
3. **Scan continu**: preview caméra, `takePicture()` plein résolution → SIFT extraction
4. **Comparaison**: brute-force BFMatcher + Lowe ratio 0.75 → matches par stabilité → score
5. **Seuils actuels**: threshold 25% (pas 90% trop strict), minMatches 60
6. **Pinch-to-zoom** disponible sur l'écran caméra (enrollment + vérification)

## Constants SIFT
```dart
kIdentityPointCount = 120
kLoweRatio = 0.75
kAuthThreshold = 0.9  (seuil théorique, en pratique 25% pour commencer)
kMinMatches = 60
```

## Écrans mobiles

### `home_screen.dart` — Hub principal
- **Tabs**: Collection (Stock) | Explorer | Portefeuille | Profil
- **_PieceCard**: Affiche photo, nom, série, pinceaux 🖌
- **_LocalEggEditScreen**: Édition série/numéro/nom/valeur pinceaux + bouton "Reprendre la photo de face"
- **_RetakeFacePhotoScreen**: Interface caméra complète (preview, guide rect, instructions, capture, thumbnail, enregistrer) — même UI que l'enrollment
- Boutons "Scanner base" (→ EggBaseScanScreen) et "Vérifier" (→ EggVerifyScreen) visibles si `auth.isAdmin`

### `egg_base_scan_screen.dart` — Enrollment
- Photo de face + 3-5 photos base + formulaire → upload serveur
- Pinch-to-zoom sur le preview caméra

### `egg_verify_screen.dart` — Vérification
- Sélecteur série → scan auto → score d'authentification

### `egg_fiche_screen.dart` — Fiche détail œuf

### Autres écrans (legacy/pieces)
- `login_screen.dart`, `onboarding_screen.dart`
- `piece_detail_screen.dart`, `make_offer_screen.dart`
- `rotation_scan_screen.dart`, `finalize_piece_screen.dart`
- `trade_window_screen.dart`

## Services mobiles

| Fichier | Rôle |
|---------|------|
| `api_client.dart` | GET/POST/PATCH/DELETE, retry on sleep, multipart 3D, `delete()` |
| `egg_base_identity.dart` | SIFT extraction, 120 points, matching, `fromJson()` |
| `egg_auth.dart` | Logique auth œufs |
| `egg_vault.dart` | Stockage œufs |
| `texture_extraction.dart` | `centerCropRegion`, `quickSharpness`, SIFT helpers |
| `error_reporter.dart` | `showErrorDialog()` (SelectableText copiable + log serveur) |
| `debug_console.dart` | `debugConsole.logError()` → `reportError()` |
| `auth_service.dart` | Auth Facebook/Google |
| `digit_detection.dart` | Détection chiffre gravé |
| `color_extraction.dart` | Extraction couleur |
| `multi_angle_scan.dart` | Scanner multi-angle |
| `series_config.dart` | Config séries |

## Providers mobiles

| Fichier | Rôle |
|---------|------|
| `pieces_provider.dart` | Charge depuis `/egg-identity/`, cache photos dans `egg_faces/` |
| `auth_provider.dart` | `isAdmin = kAdminBuild && email == 'robert.marmouth@gmail.com'` |
| `trade_provider.dart` | Échanges |
| `backend_status.dart` | Status Render |

## Backend — Fichiers clés

| Fichier | Rôle |
|---------|------|
| `app/main.py` | FastAPI app, CORS, migrations ALTER TABLE, routers |
| `app/database.py` | SQLite (dev) / PostgreSQL (Render) |
| `app/models/egg_identity.py` | SQLAlchemy EggIdentity |
| `app/models/piece.py` | SQLAlchemy Piece |
| `app/models/user.py` | SQLAlchemy User |
| `app/routers/egg_identity.py` | CRUD endpoints egg identities |
| `app/routers/pieces.py` | CRUD pieces |
| `app/routers/auth.py` | Auth routes |
| `app/routers/users.py` | User routes |
| `app/routers/offers.py` | Offres |
| `app/routers/trades.py` | Échanges |
| `app/routers/scan.py` | Scan routes |
| `app/routers/digit_auth.py` | Auth digits |
| `app/routers/scan3d.py` | Scan 3D (legacy) |
| `app/routers/logs.py` | Logs/errors |

## Règles absolues

### Route ordering (CRITIQUE)
FastAPI/Starlette matche le PATH avant la METHOD. Toujours déclarer les routes à chemin fixe AVANT les routes paramétrées.

### Deux builds séparés
Ne **JAMAIS** mettre du code admin dans le build lambda. Le flag `kAdminBuild` est compile-time.

### Stock = serveur
Plus de `local_eggs.json`. Tout est sur `/egg-identity/`. Les photos face sont en base64 dans `face_photo`, cache local dans `egg_faces/`.

### Branches
- Locale: `main` tracking `origin/main`
- Render déploie depuis `main`
- **Ne JAMAIS push sur `master`** (ancienne branche renommée)

### BACKUP001
`D:\art-gens\BACKUP001` — **ne plus y toucher** après création.

## Erreurs
Toute erreur doit être :
1. Envoyée au serveur via `reportError()`
2. Affichée à l'écran dans un dialog copiable (`showErrorDialog()` — `SelectableText`)

## OpenCV dartcv4 — APIs disponibles et indisponibles

### Disponibles
`cv.bitwiseAND`, `cv.bitwiseOR`, `cv.subtract`, `cv.threshold` (retourne `(double, Mat)`), `cv.canny`, `cv.dilate`, `cv.erode`, `cv.drawContours`, `cv.findContours`, `cv.contourArea`, `cv.boundingRect`, `cv.meanStdDev`, `cv.gaussianBlur`, `cv.morphologyEx`, `cv.resize`, `cv.adaptiveThreshold`, `cv.SIFT.create`, `cv.BFMatcher.create`, `matcher.knnMatch`, `cv.Mat.zeros`, `cv.cvtColor`, `cv.region`, `cv.imwrite`, `cv.imdecode`, `cv.clone`

### Indisponibles / pièges
- `bitwiseNot`, `bitwiseXor`, `cv.add` — **n'existent pas** dans dartcv4
- `Mat(h,w,type,scalar)` — **n'existe pas**, utiliser `cv.Mat.zeros` + opérations
- `cv.rectangle` — **n'existe pas**, dessiner via contours ou `cv.drawContours`
- `cv.copyTo(src, dst)` — **ne fonctionne pas** (ne copie rien), utiliser `src.copyTo(dst.submat)` à la place
- `cv.resize` `dsize`: `(int, int)` = `(width, height)` — confirmé via `Size.fromRecord`
- `region()` retourne un sub-matrix qui **partage les données** du parent. Ne PAS disposer le parent tant que le sub-matrix est utilisé.

## Eggs sur serveur (état actuel)
- 2-124, 5-117, 5-142 (tous avec `reference_pinceaux_value` sauvegardé)

## Backups
- `D:\art-gens\BACKUP001` — **ne plus modifier**
- `D:\art-gens\BACKUP002` — backup complet du 2026-07-14

## TODO
1. Assignation œufs aux users lambda (mécanisme admin)
2. Ajuster seuil authentification avec de vrais tests (actuellement 25%)
3. Nettoyer les services legacy non utilisés (`egg_auth.dart`, `egg_vault.dart`, `digit_detection.dart`, `color_extraction.dart`, `multi_angle_scan.dart`, `series_config.dart`)
4. Nettoyer les écrans legacy non utilisés (`rotation_scan_screen.dart`, `finalize_piece_screen.dart`)
