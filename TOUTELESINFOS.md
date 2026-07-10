# TOUTE LES INFOS — Projet Art-Gens

## Stack Technique

| Composant | Technologie | Emplacement |
|-----------|-----------|-------------|
| **Mobile** | Flutter (Dart) | `D:\art-gens\mobile\` |
| **Backend** | Python FastAPI | `D:\art-gens\backend\` |
| **Base locale** | SQLite | `D:\art-gens\backend\art_gens.db` |
| **Base prod** | PostgreSQL (Render) | `art-gens-db` (Free tier) |
| **Hébergement** | Render.com | `https://art-gens-backend.onrender.com` |
| **GitHub backend** | `https://github.com/allibgbg/art-gens-backend.git` | push → auto-deploy Render |

## Build APK

```powershell
cd D:\art-gens\mobile
$env:JAVA_HOME = "D:\android-sdk\jdk17\jdk-17.0.2"
flutter build apk --debug
# Output: build\app\outputs\flutter-apk\app-debug.apk
```

## Backend ZIP

```powershell
# Compresser tout le dossier backend
Compress-Archive -Path "D:\art-gens\backend\*" -DestinationPath "D:\art-gens\backend.zip" -Force
```

## Déploiement Render

1. **Modifier le code** → `git add -A` → `git commit -m "message"` → `git push origin main`
2. Render détecte le push et redéploie automatiquement
3. Vérifier le statut sur https://dashboard.render.com

### Variables d'environnement Render (service art-gens-backend)

| Variable | Valeur |
|----------|--------|
| `DATABASE_URL` | `postgresql://art_gens_db_user:yytL7a9LRbg0tGngccOz8SydqA4gF0ko@dpg-d98842e7r5hc73clf7c0-a/art_gens_db` |
| `SECRET_KEY` | `tr477z0_415712zer2-4875` |
| `ALGORITHM` | `HS256` |
| `ACCESS_TOKEN_EXPIRE_MINUTES` | `1440` |

| `ARTIST_EMAIL` | `robert.marmouth@gmail.com` |

### Base de données Render PostgreSQL

- **Nom** : `art-gens-db`
- **Plan** : Free (expire le 9 août 2026 si pas upgradé)
- **Région** : Oregon (US West)
- **Host** : `dpg-d98842e7r5hc73clf7c0-a`
- **Port** : 5432
- **Database** : `art_gens_db`
- **User** : `art_gens_db_user`
- **Password** : `yytL7a9LRbg0tGngccOz8SydqA4gF0ko`
- **Chaîne interne** : `postgresql://art_gens_db_user:yytL7a9LRbg0tGngccOz8SydqA4gF0ko@dpg-d98842e7r5hc73clf7c0-a/art_gens_db`

## Connexion GitHub

```powershell
cd D:\art-gens\backend
# Le remote utilise un token GitHub déjà configuré
git remote -v  # vérifier l'URL distante
git add -A
git commit -m "message"
git pull --rebase origin main  # toujours faire rebase avant push
git push origin main
```

Git a été installé via Chocolatey sur ce PC (`C:\ProgramData\chocolatey\bin\choco.exe`).

## Problèmes Résolus

### 1. Route Order (405 Method Not Allowed)
**Symptôme** : `POST /pieces/draft` retourne 405.
**Cause** : FastAPI/Starlette matche le PATH avant la METHOD. Si `GET /{piece_id}` est déclaré AVANT `POST /draft`, une requête POST /pieces/draft match le path `/{piece_id}` (piece_id="draft") mais méthode GET → 405, sans vérifier les routes suivantes.
**Fix** : Toujours déclarer les routes à chemin fixe (`/draft`, `/`) AVANT les routes paramétrées (`/{piece_id}`). Fichier : `backend/app/routers/pieces.py`.

### 2. Champs requis manquants dans le draft
**Symptôme** : Erreur DB à la création du draft (display_number, series_value, etc. sont NULL).
**Cause** : Le modèle `Piece` a `nullable=False` sur `display_number`, `series_value`, `reference_pinceaux_value`, `color_primary`. Le draft ne fournit que `texture_signature`.
**Fix** : Le POST /draft crée maintenant le `Piece` avec des placeholders :
- `display_number = pid[:10]` (prefixe UUID)
- `series_value = 0`
- `reference_pinceaux_value = 0`
- `color_primary = ColorEnum.multicolore`

### 3. Boucle infinie de retry
**Symptôme** : L'app scanne, la jauge se remplit, "Sauvegarde..." puis recommence à scanner, en boucle.
**Cause** : Toute erreur (API, DB) dans le catch de `_saveAndNext()` appelait `_startCapture()` immédiatement → retry immédiat → boucle infinie.
**Fix** :
- Ajout d'un compteur de retries (max 3)
- Délai de 2s entre chaque retry
- Après 3 échecs, erreur permanente affichée

### 4. Utilisateur introuvable après redéploiement
**Symptôme** : `Erreur sauvegarde: ApiException(404): Utilisateur introuvable`
**Cause** : Le token JWT stocké sur le téléphone référence un utilisateur qui n'existe plus dans la DB (DB détruite au redéploiement SQLite).
**Fix** :
- Migration vers PostgreSQL Render (DB persistante)
- Ajout d'un callback `onAuthError` dans `ApiClient` : si 401 ou 404 "introuvable" → logout automatique → redirection vers écran login

### 5. Driver PostgreSQL manquant
**Symptôme** : Render déploie mais le conteneur crash au démarrage.
**Cause** : `requirements.txt` n'incluait pas `psycopg2-binary` → SQLAlchemy ne peut pas se connecter à PostgreSQL.
**Fix** : Ajout de `psycopg2-binary==2.9.10` dans `requirements.txt`.

## Fonctionnalités Développées

### Scan 3 phases (100% automatique, zéro bouton)

#### Phase 1 — Texture du fond (TextureScanScreen)
- Extrait les points ORB (OpenCV) du fond poncé
- Top 256 meilleurs keypoints sauvegardés (triés par response)
- CLAHE avant extraction pour améliorer le contraste
- Stabilisation 2s requise avec min 30 keypoints
- Trame guide cercle affichée
- Keypoints overlay : tous en blanc, top 30 en rouge
- `AdaptiveSharpnessGate` : calibration 20s, seuil plancher 1.8, ratio 70% du max
- Auto-next vers Phase 2 après sauvegarde réussie

#### Phase 2 — Chiffre gravé (DigitScanScreen)
- Prend une photo du dessus
- Calcule les 7 moments de Hu (implémentés manuellement car dartcv4 1.1.8 n'exporte pas HuMoments)
- Formules : nu20+nu02, (nu20-nu02)²+4*nu11², ...
- Compare avec les références stockées (ref2, ref5 — valeurs approximatives)
- Affiche "Chiffre X détecté (YY%)"
- Auto-next vers Phase 3 après PATCH top_image

#### Phase 3 — Rotation complète (RotationScanScreen)
- `MultiAngleScanner` avec grille 5×5 (25 positions)
- Capture la signature couleur sur 360°
- Feedback visuel sur les angles couverts
- Auto-next vers Phase 4 après PATCH color_signature

#### Phase 4 — Finalisation (FinalizePieceScreen)
- Formulaire : numéro, série, référence pinceaux, couleurs, notes
- POST /finalize crée la pièce finale

### API Backend

| Méthode | Route | Description |
|---------|-------|-------------|
| GET | `/pieces/` | Liste toutes les pièces |
| GET | `/pieces/{id}` | Détail d'une pièce |
| POST | `/pieces/` | Création directe |
| POST | `/pieces/draft` | Création draft (texture seulement) |
| PATCH | `/pieces/{id}` | Mise à jour partielle (top_image, color_signature) |
| POST | `/pieces/{id}/finalize` | Finalisation avec métadonnées |
| POST | `/pieces/{id}/scan` | Scan de vérification (matching) |
| POST | `/auth/google` | Auth Google |
| GET | `/users/me` | Profil utilisateur connecté |

### Matching (backend `matching_service.py`)
- **Texture** : ORB + RANSAC (`estimateAffinePartial2D`, min 8 inliers) — poids 60%
- **Hu** : Distance euclidienne sur les 7 moments — poids 20%
- **LBP** : Histogramme LBP manuel (numpy, pas de scikit-image) — poids 20%
- Score combiné : `0.6×texture + 0.2×Hu + 0.2×LBP`

## Points d'Attention

- `dartcv4-1.1.8` pas de `HuMoments` → implémentation manuelle dans `digit_scan_screen.dart`
- API findContours : `(Contours, VecVec4i) findContours(Mat src, int mode, int method)`
- API threshold : `(double, Mat) threshold(...)`
- API moments : `Moments moments(Mat src, {bool binaryImage = false})`
- Les valeurs de référence Hu (`ref2`, `ref5`) dans `digit_scan_screen.dart` sont approximatives — à calibrer avec des captures réelles
- Pour le scan de vérification (utilisateur lambda) : adapter le flux pour n'utiliser que la Phase 3 (rotation) avec seuil 60%
- `trade_service.py` a `authenticity_match` toujours écrit en dur à True (trou de sécurité non corrigé)

## Fichiers Clés

| Fichier | Rôle |
|---------|------|
| `mobile/lib/screens/texture_scan_screen.dart` | Phase 1 — fond |
| `mobile/lib/screens/digit_scan_screen.dart` | Phase 2 — chiffre |
| `mobile/lib/screens/rotation_scan_screen.dart` | Phase 3 — rotation |
| `mobile/lib/screens/finalize_piece_screen.dart` | Phase 4 — formulaire |
| `mobile/lib/services/texture_extraction.dart` | ORB + CLAHE + AdaptiveSharpnessGate |
| `mobile/lib/services/api_client.dart` | Client HTTP avec gestion d'erreurs auth |
| `mobile/lib/main.dart` | Routes, AuthGate, baseUrl |
| `backend/app/routers/pieces.py` | Routes API pieces (draft, patch, finalize) |
| `backend/app/services/matching_service.py` | Matching (Hu + LBP + texture) |
| `backend/app/services/piece_service.py` | CRUD pieces |
| `backend/app/models/piece.py` | Modèle SQL Piece |
| `backend/app/services/auth_service.py` | Auth JWT + Google |
| `backend/app/main.py` | Point d'entrée FastAPI + migrations |
| `backend/requirements.txt` | Dépendances Python |
| `backend/Dockerfile` | Build Docker pour Render |
| `backend/.env` | Variables locales (gitignoré) |
