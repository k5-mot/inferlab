# GPU ドライバに対応する PyTorch イメージを使用
FROM pytorch/pytorch:2.8.0-cuda12.9-cudnn9-runtime

WORKDIR /app

# 必要なパッケージをインストール
RUN apt-get update && apt-get install -y --no-install-recommends \
  git \
  && rm -rf /var/lib/apt/lists/*

# ComfyUI をインストール
RUN git clone https://github.com/comfyanonymous/ComfyUI.git
WORKDIR /app/ComfyUI
RUN pip install --no-cache-dir -r requirements.txt

# 非 root ユーザーで実行
RUN groupadd -g 1000 appuser && \
    useradd -m -u 1000 -g 1000 appuser && \
    chown -R appuser:appuser /app
USER appuser

EXPOSE 8188

ENTRYPOINT ["python", "main.py", "--listen", "--port", "8188"]
