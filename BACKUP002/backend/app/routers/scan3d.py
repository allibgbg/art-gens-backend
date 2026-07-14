"""Endpoints de scan 3D (photogrammétrie + comparaison d'auth).

/reconstruct : upload de plusieurs photos -> reconstruction -> mesh (OBJ).
/compare     : upload de 2 meshes (référence + candidat) -> score de similarité.
"""
import os
import json
import tempfile
import shutil
from typing import List

from fastapi import APIRouter, UploadFile, File, Form, HTTPException
from fastapi.responses import FileResponse

from ..services import reconstruction as recon
from ..services import mesh_compare as mc
from ..services.reconstruction import ReconstructionUnavailable

router = APIRouter(prefix="/scan3d", tags=["scan3d"])


@router.post("/reconstruct")
async def reconstruct(
    files: List[UploadFile] = File(...),
    dense: bool = Form(True),
):
    """Reconstruit un mesh OBJ à partir d'un set de photos de l'objet."""
    if not recon.colmap_available():
        raise HTTPException(
            status_code=501,
            detail="COLMAP non disponible sur ce serveur. "
            "Lance la reconstruction sur un worker/local (voir reconstruction.py).",
        )
    tmp = tempfile.mkdtemp(prefix="artgens_imgs_")
    try:
        for i, f in enumerate(files):
            ext = os.path.splitext(f.filename or "")[1] or ".jpg"
            dest = os.path.join(tmp, f"img_{i:03d}{ext}")
            with open(dest, "wb") as out:
                shutil.copyfileobj(f.file, out)
        result = recon.reconstruct_folder(tmp, dense=dense)
    except ReconstructionUnavailable as e:
        raise HTTPException(
            status_code=501,
            detail="COLMAP non disponible sur ce serveur: %s" % e,
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)

    mesh = result.pop("mesh")
    return FileResponse(
        mesh,
        media_type="application/octet-stream",
        filename="model.obj",
        headers={"X-Recon": json.dumps(result, default=str)},
    )


@router.post("/compare")
async def compare(
    reference: UploadFile = File(...),
    candidate: UploadFile = File(...),
    threshold: float = Form(0.02),
):
    """Compare deux meshes (référence vs candidat) et renvoie un score d'auth."""
    tmp = tempfile.mkdtemp(prefix="artgens_cmp_")
    ref_p = os.path.join(tmp, "ref.obj")
    cand_p = os.path.join(tmp, "cand.obj")
    try:
        with open(ref_p, "wb") as o:
            shutil.copyfileobj(reference.file, o)
        with open(cand_p, "wb") as o:
            shutil.copyfileobj(candidate.file, o)
        result = mc.compare_meshes(ref_p, cand_p, threshold=threshold)
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))
    finally:
        shutil.rmtree(tmp, ignore_errors=True)
    return result
