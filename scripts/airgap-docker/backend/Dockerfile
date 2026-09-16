FROM ubuntu:22.04

COPY deb/ubuntu-22.04/ /opt/airgap/deb/

RUN export DEBIAN_FRONTEND=noninteractive; \
    dpkg --unpack /opt/airgap/deb/*.deb || true; \
    apt-get install -y --fix-broken --no-install-recommends /opt/airgap/deb/*.deb \
    && dpkg --configure -a \
    && test -z "$(dpkg --audit)" \
    && python3 --version \
    && python3 -m pip --version \
    && apt-get clean \
    && rm -rfv /var/lib/apt/lists/* /var/cache/apt/* /opt/airgap/deb

WORKDIR /app

COPY pypi/ /opt/airgap/pypi/
COPY pyproject.toml uv.lock ./

RUN python3 -m pip install \
        --no-index \
        --find-links=/opt/airgap/pypi \
        uv \
    && uv export \
        --frozen \
        --no-dev \
        --no-emit-project \
        --no-hashes \
        --output-file=/tmp/requirements.txt \
    && uv venv --python=/usr/bin/python3 --no-python-downloads \
    && uv pip sync \
        --python=.venv/bin/python \
        --no-index \
        --offline \
        --find-links=/opt/airgap/pypi \
        /tmp/requirements.txt \
    && rm -f /tmp/requirements.txt \
    && rm -rfv /root/.cache /opt/airgap/pypi

COPY src/ src/

ENV PYTHONPATH=/app/src

RUN .venv/bin/python -c "from airgap_backend.main import app; assert app.title == 'Air-gap FastAPI'"

CMD [".venv/bin/uvicorn", "airgap_backend.main:app", "--host", "0.0.0.0", "--port", "8000"]
