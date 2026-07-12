cmake_minimum_required(VERSION 3.22.1)
project(colmap_ffi CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Petit wrapper natif (libcolmap_ffi.so) qui appelle le binaire COLMAP
# bundlé. Il NE link PAS COLMAP : tout se fait via le binaire.
add_library(colmap_ffi SHARED
    colmap_ffi.cpp
    colmap_ffi.h)

# --- Build (depuis un poste avec l'Android NDK) -----------------------------
# 1) Compiler COLMAP pour Android arm64 (CPU, SANS CUDA) et récupérer le
#    binaire `colmap` (voir colmap_build.md). Le bundler dans l'APK en asset.
# 2) Compiler ce wrapper :
# cmake -S . -B build-android \
#   -DCMAKE_TOOLCHAIN_FILE=$ANDROID_NDK/build/cmake/android.toolchain.cmake \
#   -DANDROID_ABI=arm64-v8a -DANDROID_PLATFORM=android-24
# cmake --build build-android
# -> libcolmap_ffi.so dans build-android/
# 3) Copier libcolmap_ffi.so dans mobile/android/app/src/main/jniLibs/arm64-v8a/
#    et le binaire colmap en mobile/assets/colmap (l'app l'extrait au runtime).
