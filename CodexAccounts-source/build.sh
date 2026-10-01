#!/bin/zsh
set -euo pipefail

source_dir="${0:A:h}"
output_dir="${source_dir:h}"
app_dir="${output_dir}/CodexAccounts.app"

mkdir -p "${app_dir}/Contents/MacOS"
cp "${source_dir}/Info.plist" "${app_dir}/Contents/Info.plist"
swiftc -target arm64-apple-macos14.0 -parse-as-library \
  -framework AppKit -framework SwiftUI -framework Security -lsqlite3 \
  "${source_dir}/AccountStore.swift" \
  "${source_dir}/AppServer.swift" \
  "${source_dir}/AppServerSession.swift" \
  "${source_dir}/AuthSwitcher.swift" \
  "${source_dir}/ExternalQuota.swift" \
  "${source_dir}/main.swift" \
  -o "${app_dir}/Contents/MacOS/CodexAccounts"
codesign --force --deep --sign - "${app_dir}"
echo "Built ${app_dir}"

# Keep the easy-to-find installed copy in sync with each successful build.
installed_app="/Applications/Codex Accounts.app"
install_tmp="$(mktemp -d '/Applications/.CodexAccounts-install.XXXXXX')"
cleanup_install() {
  if [[ -d "${install_tmp}/backup.app" && ! -e "${installed_app}" ]]; then
    mv "${install_tmp}/backup.app" "${installed_app}"
  fi
  rm -rf "${install_tmp}"
}
trap cleanup_install EXIT

ditto "${app_dir}" "${install_tmp}/new.app"
codesign --verify --deep --strict "${install_tmp}/new.app"

running_pattern="^${installed_app}/Contents/MacOS/CodexAccounts$"
was_running=false
while IFS= read -r pid; do
  [[ -z "${pid}" ]] && continue
  was_running=true
  kill -TERM "${pid}"
done < <(pgrep -f "${running_pattern}" || true)

if ${was_running}; then
  for attempt in {1..40}; do
    pgrep -f "${running_pattern}" >/dev/null || break
    sleep 0.25
  done
  if pgrep -f "${running_pattern}" >/dev/null; then
    echo "The running Codex Accounts app did not exit; installation was cancelled." >&2
    exit 1
  fi
fi

if [[ -d "${installed_app}" ]]; then
  mv "${installed_app}" "${install_tmp}/backup.app"
fi
mv "${install_tmp}/new.app" "${installed_app}"
echo "Installed ${installed_app}"

if ${was_running}; then
  open -a "${installed_app}"
fi
