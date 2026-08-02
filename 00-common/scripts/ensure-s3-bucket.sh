#!/bin/sh
set -eu

: "${RUSTFS_DEFAULT_BUCKET:?RUSTFS_DEFAULT_BUCKET is required}"

# RustFS/MinIO系のS3互換storageでは、bucketはapplication起動前に存在している必要がある。
# 同じ処理を複数stackで使うため、AWS CLIの接続情報はCompose側の環境変数に任せる。
if aws s3api head-bucket --bucket "${RUSTFS_DEFAULT_BUCKET}"; then
  echo "Bucket already exists: ${RUSTFS_DEFAULT_BUCKET}"
else
  echo "Creating bucket: ${RUSTFS_DEFAULT_BUCKET}"
  aws s3api create-bucket --bucket "${RUSTFS_DEFAULT_BUCKET}"
fi
