import base64
import io

from fastapi import FastAPI, File, UploadFile, HTTPException
from fastapi.responses import JSONResponse
from paddleocr import PaddleOCR
from PIL import Image
import numpy as np

app = FastAPI(title="PaddleOCR API")

ocr = PaddleOCR(use_angle_cls=True, lang="japan", use_gpu=False)


@app.get("/health")
def health():
    return {"status": "ok"}


@app.post("/ocr")
async def run_ocr(file: UploadFile = File(...)):
    if not file.content_type.startswith("image/"):
        raise HTTPException(status_code=400, detail="Image file required")

    data = await file.read()
    image = Image.open(io.BytesIO(data)).convert("RGB")
    img_array = np.array(image)

    result = ocr.ocr(img_array, cls=True)

    lines = []
    if result and result[0]:
        for line in result[0]:
            text = line[1][0]
            confidence = line[1][1]
            box = line[0]
            lines.append({"text": text, "confidence": confidence, "box": box})

    return JSONResponse({"results": lines})


@app.post("/ocr/base64")
async def run_ocr_base64(body: dict):
    try:
        image_data = base64.b64decode(body["image"])
    except Exception:
        raise HTTPException(status_code=400, detail="Invalid base64 image")

    image = Image.open(io.BytesIO(image_data)).convert("RGB")
    img_array = np.array(image)

    result = ocr.ocr(img_array, cls=True)

    lines = []
    if result and result[0]:
        for line in result[0]:
            text = line[1][0]
            confidence = line[1][1]
            box = line[0]
            lines.append({"text": text, "confidence": confidence, "box": box})

    return JSONResponse({"results": lines})
