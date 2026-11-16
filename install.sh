#!/usr/bin/env bash
# Download the packaged installer into a regular file before starting Bash.
set -eu
umask 077

origin=https://raw.githubusercontent.com/SUYUEM/Hrules-install/main
temp=$(mktemp -d "${TMPDIR:-/tmp}/hrules-bootstrap.XXXXXXXX")
package=$temp/hrules-six.sh
checksum=$temp/hrules-six.sh.sha256
cleanup() {
    rm -f -- "$package" "$checksum"
    rmdir -- "$temp"
}
trap cleanup EXIT

download() {
    curl -fsSL --proto '=https' --proto-redir '=https' --connect-timeout 12 --max-time 90 --retry 2 \
        "$origin/$1" -o "$temp/$1"
}

verified=false
for attempt in 1 2 3; do
    download hrules-six.sh.sha256
    download hrules-six.sh
    read -r expected < "$checksum"
    actual=$(sha256sum -- "$package")
    if [[ $expected =~ ^[0-9a-f]{64}$ && $expected == "${actual%% *}" ]]; then
        verified=true
        break
    fi
    # GitHub's raw endpoints can briefly serve different revisions during a release.
    if [[ $attempt != 3 ]]; then
        sleep 2
    fi
done
if [[ $verified != true ]]; then
    printf '%s\n' 'Hrules 安装包校验失败，请稍后重试。' >&2
    exit 1
fi
bash -n "$package"
if (( $# == 0 )); then
    set -- online
fi
bash "$package" "$@"
