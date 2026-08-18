#!/usr/bin/env bash
set -euo pipefail

# このscriptは/srv/12-registry/deb直下のdebをreprepro repositoryへ反映する。
REPOSITORY_DIR="${REPOSITORY_DIR:-/repo}"
IMPORTS_DIR="${IMPORTS_DIR:-$REPOSITORY_DIR}"
DEB_DISTRIBUTION="${DEB_DISTRIBUTION:-stable}"
DEB_CODENAME="${DEB_CODENAME:-stable}"
DEB_COMPONENT="${DEB_COMPONENT:-main}"
DEB_ARCHITECTURES="${DEB_ARCHITECTURES:-amd64 arm64}"
DEB_ORIGIN="${DEB_ORIGIN:-Local}"
DEB_LABEL="${DEB_LABEL:-Local}"
PUBLIC_DIR="$REPOSITORY_DIR/public"

case "$REPOSITORY_DIR" in
  "" | "/")
    echo "ERROR: REPOSITORY_DIR must not be empty or root." >&2
    exit 1
    ;;
esac

case "$PUBLIC_DIR" in
  "$REPOSITORY_DIR" | "" | "/")
    echo "ERROR: PUBLIC_DIR must not be repository root." >&2
    exit 1
    ;;
esac

build_dir="$(mktemp -d)"
trap 'rm -rf "$build_dir"' EXIT

mkdir -p "$build_dir/conf"
cat > "$build_dir/conf/distributions" <<EOF
Origin: $DEB_ORIGIN
Label: $DEB_LABEL
Codename: $DEB_CODENAME
Suite: $DEB_DISTRIBUTION
Architectures: $DEB_ARCHITECTURES
Components: $DEB_COMPONENT
Description: Local APT repository
EOF

shopt -s nullglob
deb_files=("$IMPORTS_DIR"/*.deb)

if [ "${#deb_files[@]}" -gt 0 ]; then
  for file in "${deb_files[@]}"; do
    reprepro --basedir "$build_dir" --ignore=wrongdistribution includedeb "$DEB_CODENAME" "$file"
  done
else
  reprepro --basedir "$build_dir" export "$DEB_CODENAME"
fi

cat > "$build_dir/index.html" <<EOF
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>reprepro</title></head>
<body>
<h1>reprepro</h1>
<p>APT repository.</p>
<ul>
  <li><a href="./dists/$DEB_CODENAME/Release">dists/$DEB_CODENAME/Release</a></li>
</ul>
</body>
</html>
EOF

if [ -f "$PUBLIC_DIR/.gitkeep" ] || [ -f "$REPOSITORY_DIR/.gitkeep" ]; then
  printf '\n' > "$build_dir/.gitkeep"
fi

chmod -R a+rX "$build_dir"
mkdir -p "$PUBLIC_DIR"
find "$PUBLIC_DIR" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
cp -R "$build_dir"/. "$PUBLIC_DIR"/
chmod -R a+rX "$PUBLIC_DIR"
