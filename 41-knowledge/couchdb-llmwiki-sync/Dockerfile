FROM docker.io/library/python:3.13-slim

WORKDIR /app

COPY sync_worker.py /app/sync_worker.py

RUN chmod 0555 /app/sync_worker.py

ENTRYPOINT ["python", "/app/sync_worker.py"]
