#!/usr/bin/env bash
set -euo pipefail

# このscriptはaptlyを使わず、APTが読める最小metadataだけを生成する。
IMPORTS_DIR="${IMPORTS_DIR:-/imports}"
REPOSITORY_DIR="${REPOSITORY_DIR:-/repo}"

case "$REPOSITORY_DIR" in
  "" | "/")
    echo "ERROR: REPOSITORY_DIR must not be empty or root." >&2
    exit 1
    ;;
esac

shopt -s nullglob
deb_files=("$IMPORTS_DIR"/*.deb)

if [ "${#deb_files[@]}" -eq 0 ]; then
  exit 0
fi

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

cp -f "${deb_files[@]}" "$build_dir/"

packages_file="$build_dir/Packages.tmp"
for file in "$build_dir"/*.deb; do
  package="./$(basename "$file")"
  size="$(wc -c < "$file" | tr -d ' ')"
  md5="$(md5sum "$file" | awk '{print $1}')"
  sha1="$(sha1sum "$file" | awk '{print $1}')"
  sha256="$(sha256sum "$file" | awk '{print $1}')"

  dpkg-deb -f "$file"
  printf 'Filename: %s\nSize: %s\nMD5sum: %s\nSHA1: %s\nSHA256: %s\n\n' "$package" "$size" "$md5" "$sha1" "$sha256"
done > "$packages_file"

mv "$packages_file" "$build_dir/Packages"
gzip -kf "$build_dir/Packages"

cat > "$build_dir/Release" <<EOF
Archive: stable
Component: main
Date: $(date -Ru)
MD5Sum:
 $(md5sum "$build_dir/Packages" | awk '{print $1}') $(wc -c < "$build_dir/Packages" | tr -d ' ') Packages
 $(md5sum "$build_dir/Packages.gz" | awk '{print $1}') $(wc -c < "$build_dir/Packages.gz" | tr -d ' ') Packages.gz
SHA1:
 $(sha1sum "$build_dir/Packages" | awk '{print $1}') $(wc -c < "$build_dir/Packages" | tr -d ' ') Packages
 $(sha1sum "$build_dir/Packages.gz" | awk '{print $1}') $(wc -c < "$build_dir/Packages.gz" | tr -d ' ') Packages.gz
SHA256:
 $(sha256sum "$build_dir/Packages" | awk '{print $1}') $(wc -c < "$build_dir/Packages" | tr -d ' ') Packages
 $(sha256sum "$build_dir/Packages.gz" | awk '{print $1}') $(wc -c < "$build_dir/Packages.gz" | tr -d ' ') Packages.gz
EOF

cat > "$build_dir/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>APT repository</title></head>
<body>
<h1>APT repository</h1>
<p>Flat APT repository.</p>
<ul>
  <li><a href="./Packages">Packages</a></li>
</ul>
</body>
</html>
EOF

chmod -R a+rX "$build_dir"

mkdir -p "$REPOSITORY_DIR"
find "$REPOSITORY_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -a "$build_dir"/. "$REPOSITORY_DIR"/
