#!/usr/bin/env bash
set -euo pipefail

# このscriptはpublisher container内で実行し、RPM配信volumeを完全に置き換える。
REPOSITORY_DIR="${REPOSITORY_DIR:-/repo}"
IMPORTS_DIR="${IMPORTS_DIR:-$REPOSITORY_DIR}"

case "$REPOSITORY_DIR" in
  "" | "/")
    echo "ERROR: REPOSITORY_DIR must not be empty or root." >&2
    exit 1
    ;;
esac

shopt -s nullglob
rpm_files=("$IMPORTS_DIR"/*.rpm)

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

if [ "${#rpm_files[@]}" -gt 0 ]; then
  cp -f "${rpm_files[@]}" "$build_dir/"
fi

if [ -f "$REPOSITORY_DIR/.gitkeep" ]; then
  printf '\n' > "$build_dir/.gitkeep"
fi

createrepo_c --update "$build_dir"

cat > "$build_dir/index.html" <<'EOF'
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>createrepo_c</title></head>
<body>
<h1>createrepo_c</h1>
<p>RPM source repository for dnf/yum.</p>
<ul>
  <li><a href="./repodata/repomd.xml">repodata/repomd.xml</a></li>
</ul>
</body>
</html>
EOF

chmod -R a+rX "$build_dir"

mkdir -p "$REPOSITORY_DIR"
find "$REPOSITORY_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -R "$build_dir"/. "$REPOSITORY_DIR"/
chmod -R a+rX "$REPOSITORY_DIR"
