FROM paddlepaddle/paddle:3.3.0

WORKDIR /app

RUN apt-get update && apt-get install -y --no-install-recommends \
  libgomp1 \
  libglib2.0-0 \
  libsm6 \
  libxext6 \
  libxrender-dev \
  libgl1 \
  && rm -rf /var/lib/apt/lists/*

RUN pip install --no-cache-dir \
  paddleocr \
  fastapi \
  uvicorn[standard] \
  python-multipart

COPY app.py .

EXPOSE 8080

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8080"]
