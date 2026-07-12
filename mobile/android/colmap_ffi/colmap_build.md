# COLMAP sur Android (on-device)

L'app reconstruit le nuage de points **sur le téléphone** via un module natif
(`libcolmap_ffi.so`) qui appelle le binaire COLMAP (CPU, sans CUDA).
Si le module ou le binaire sont absents, l'app retombe automatiquement sur le
backend (pycolmap).

## 1) Compiler COLMAP pour Android (arm64, CPU)

COLMAP n'a pas de package Flutter : il faut le cross-compiler avec le NDK.
Depuis un poste Linux/macOS avec l'Android NDK :

```bash
git clone https://github.com/colmap/colmap && cd colmap
mkdir build-android && cd build-android
cmake .. -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24 \
  -DCMAKE_BUILD_TYPE=Release -DCOLMAP_CUDA_ENABLED=OFF \
  -DBUILD_TESTS=OFF -DBUILD_APPS=ON
cmake --build . -j
# -> binaire `colmap` (dans lib/ ou bin/)
```

(noter : COLMAP tire Eigen, Ceres, glog, gflags, FLANN, SQLite — le build NDK
les compile ensemble. Compter plusieurs dizaines de minutes.)

## 2) Compiler le wrapper

```bash
cd mobile/android/colmap_ffi
cmake -S . -B build-android \
  -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
  -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24
cmake --build build-android
```

## 3) Bundler dans l'APK

- `libcolmap_ffi.so` -> `mobile/android/app/src/main/jniLibs/arm64-v8a/`
- binaire `colmap`     -> `mobile/assets/colmap` (l'app l'extrait au runtime)

Puis `flutter build apk`. L'écran « Outil scan 3D » reconstruit alors en local.
