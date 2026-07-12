#include "colmap_ffi.h"
#include <cstdlib>
#include <string>

static int run(const std::string& cmd) {
  return std::system(cmd.c_str());
}

// Pipeline COLMAP CPU (sans CUDA) : extraction -> matching -> mapper
// (sparse) -> conversion PLY. Le binaire COLMAP est bundlé et appelé
// via system(). Aucune dépendance CUDA.
extern "C" int colmap_reconstruct(const char* images_dir,
                                   const char* output_dir,
                                   const char* colmap_bin) {
  std::string img = images_dir;
  std::string out = output_dir;
  std::string bin = colmap_bin;

  std::string db = out + "/database.db";
  std::string sparse = out + "/sparse";
  std::string ply = out + "/model.ply";

  if (run("mkdir -p \"" + sparse + "\"") != 0) return 1;

  std::string c1 = "\"" + bin + "\" feature_extractor"
                   " --database_path \"" + db + "\""
                   " --image_path \"" + img + "\""
                   " --ImageReader.camera_model SIMPLE_RADIAL";
  std::string c2 = "\"" + bin + "\" exhaustive_matcher"
                   " --database_path \"" + db + "\"";
  std::string c3 = "\"" + bin + "\" mapper"
                   " --database_path \"" + db + "\""
                   " --image_path \"" + img + "\""
                   " --output_path \"" + sparse + "\"";
  std::string c4 = "\"" + bin + "\" model_converter"
                   " --input_path \"" + sparse + "/0\""
                   " --output_path \"" + ply + "\""
                   " --output_type PLY";

  if (run(c1.c_str()) != 0) return 1;
  if (run(c2.c_str()) != 0) return 1;
  if (run(c3.c_str()) != 0) return 1;
  if (run(c4.c_str()) != 0) return 1;
  return 0;
}
