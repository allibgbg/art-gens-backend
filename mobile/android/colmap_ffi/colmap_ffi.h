#ifndef COLMAP_FFI_H
#define COLMAP_FFI_H

#ifdef __cplusplus
extern "C" {
#endif

// Reconstruit un nuage de points (COLMAP, CPU) à partir des images de
// images_dir, écrit model.ply dans output_dir.
// colmap_bin = chemin du binaire COLMAP bundlé sur l'appareil.
// Retourne 0 si succès, !=0 sinon.
int colmap_reconstruct(const char* images_dir,
                       const char* output_dir,
                       const char* colmap_bin);

#ifdef __cplusplus
}
#endif

#endif // COLMAP_FFI_H
