#!/usr/bin/env sh
set -eu

repo="${SYMPHONY_REPO:-DannyMac180/simphony}"
version="${SYMPHONY_VERSION:-latest}"
install_dir="${SYMPHONY_INSTALL_DIR:-$HOME/.local/bin}"

os="$(uname -s | tr '[:upper:]' '[:lower:]')"
arch="$(uname -m)"

case "$os" in
  darwin) os="macos" ;;
  linux) os="linux" ;;
  *)
    echo "Unsupported OS: $os" >&2
    exit 1
    ;;
esac

case "$arch" in
  arm64|aarch64) arch="arm64" ;;
  x86_64|amd64) arch="x64" ;;
  *)
    echo "Unsupported architecture: $arch" >&2
    exit 1
    ;;
esac

asset="symphony-${os}-${arch}.tar.gz"

if [ "$version" = "latest" ]; then
  base_url="https://github.com/${repo}/releases/latest/download"
else
  base_url="https://github.com/${repo}/releases/download/${version}"
fi

tmp_dir="$(mktemp -d)"
trap 'rm -rf "$tmp_dir"' EXIT

echo "Downloading ${asset}..."
curl -fsSL "${base_url}/${asset}" -o "${tmp_dir}/${asset}"

if command -v shasum >/dev/null 2>&1; then
  curl -fsSL "${base_url}/checksums.txt" -o "${tmp_dir}/checksums.txt"
  grep " ${asset}\$" "${tmp_dir}/checksums.txt" > "${tmp_dir}/asset.sha256"
  (cd "$tmp_dir" && shasum -a 256 -c asset.sha256)
elif command -v sha256sum >/dev/null 2>&1; then
  curl -fsSL "${base_url}/checksums.txt" -o "${tmp_dir}/checksums.txt"
  grep " ${asset}\$" "${tmp_dir}/checksums.txt" > "${tmp_dir}/asset.sha256"
  (cd "$tmp_dir" && sha256sum -c asset.sha256)
fi

mkdir -p "$install_dir"
tar -xzf "${tmp_dir}/${asset}" -C "$tmp_dir"

release_root="$(find "$tmp_dir" -type f -path '*/bin/symphony' -perm -111 | head -n 1 | sed 's#/bin/symphony$##')"

if [ -z "$release_root" ]; then
  echo "Could not find the Symphony release executable in ${asset}" >&2
  exit 1
fi

target_root="${install_dir}/.symphony-release"
rm -rf "$target_root"
mkdir -p "$target_root"
cp -R "$release_root"/. "$target_root"/
cat > "${install_dir}/symphony" <<EOF
#!/usr/bin/env sh
set -eu

release_bin="${target_root}/bin/symphony"

open_url() {
  url="\$1"
  if command -v open >/dev/null 2>&1; then
    open "\$url" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "\$url" >/dev/null 2>&1 || true
  fi
}

settings_file() {
  case "\$(uname -s)" in
    Darwin) printf '%s\n' "\$HOME/Library/Application Support/Symphony/settings.json" ;;
    *) printf '%s\n' "\${XDG_CONFIG_HOME:-\$HOME/.config}/symphony/settings.json" ;;
  esac
}

workflow_file() {
  settings="\$(settings_file)"
  printf '%s\n' "\$(dirname "\$settings")/WORKFLOW.md"
}

symphony_port() {
  settings="\$(settings_file)"
  if [ -f "\$settings" ]; then
    port="\$(sed -n 's/.*\"server_port\"[[:space:]]*:[[:space:]]*\\([0-9][0-9]*\\).*/\\1/p' "\$settings" | head -n 1)"
    if [ -n "\$port" ]; then
      printf '%s\n' "\$port"
      return
    fi
  fi

  printf '%s\n' "7957"
}

open_setup() {
  open_url "http://127.0.0.1:\$(symphony_port)/setup"
}

open_dashboard() {
  open_url "http://127.0.0.1:\$(symphony_port)/"
}

configured() {
  test -f "\$(settings_file)" && test -f "\$(workflow_file)"
}

should_open_browser() {
  if [ "\${SYMPHONY_NO_OPEN:-}" = "1" ]; then
    return 1
  fi

  for arg in "\$@"; do
    if [ "\$arg" = "--no-open" ]; then
      return 1
    fi
  done

  return 0
}

case "\${1:-start}" in
  start)
    shift || true
    if should_open_browser "\$@"; then
      if configured; then
        (sleep 2; open_dashboard) &
      else
        (sleep 2; open_setup) &
      fi
    fi
    exec "\$release_bin" start "\$@"
    ;;
  setup)
    shift || true
    if [ "\$#" -eq 0 ] || [ "\${1#-}" != "\$1" ]; then
      if should_open_browser "\$@"; then
        (sleep 2; open_setup) &
      fi
      exec "\$release_bin" start "\$@"
    fi
    exec "\$release_bin" setup "\$@"
    ;;
  status)
    exec "\$release_bin" pid
    ;;
  stop)
    exec "\$release_bin" stop
    ;;
  *)
    exec "\$release_bin" "\$@"
    ;;
esac
EOF
chmod +x "${install_dir}/symphony"

echo "Installed symphony to ${install_dir}/symphony"

case ":$PATH:" in
  *":$install_dir:"*) ;;
  *) echo "Add ${install_dir} to PATH to run symphony from any shell." ;;
esac

if [ "${SYMPHONY_AGENT_SETUP:-}" = "1" ] || [ "${SYMPHONY_SKIP_START:-}" = "1" ]; then
  echo "Skipping automatic start. Run ${install_dir}/symphony start when setup is complete."
else
  "${install_dir}/symphony" start
fi
