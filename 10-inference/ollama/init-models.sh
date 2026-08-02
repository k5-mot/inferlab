#!/bin/sh
set -eu

: "${OLLAMA_INIT_MODELS:=gemma4:31b-cloud gpt-oss:20b-cloud nemotron-3-nano:30b-cloud}"

# `ollama pull`にはlocal daemonが必要なため、init container内で一時的にserverを起動する。
# 本体serviceはこのcontainerの正常終了後に同じvolumeを使って起動する。
ollama serve &
ollama_pid="$!"

# init失敗時にdaemonだけが残らないよう、明示的に終了させる。
trap 'kill "${ollama_pid}" 2>/dev/null || true' INT TERM EXIT

until ollama list >/dev/null 2>&1; do
  echo "Waiting for Ollama to be ready..."
  sleep 1
done

echo "Ollama is ready. Importing models sequentially..."
for model in ${OLLAMA_INIT_MODELS}; do
  echo "Pulling ${model}..."
  ollama pull "${model}"
done

echo "All models pulled."
trap - INT TERM EXIT
kill "${ollama_pid}"
wait "${ollama_pid}" 2>/dev/null || true
