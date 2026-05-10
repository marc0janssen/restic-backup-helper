#!/usr/bin/env bash

# Forked from https://rclone.org/install.sh with additions:
#   * Optional pinning via env RCLONE_VERSION (e.g. 1.69.1) → downloads from
#     https://downloads.rclone.org/v${RCLONE_VERSION}/ instead of /current/.
#   * Mandatory SHA256 verification of the downloaded archive against the
#     upstream SHA256SUMS file (fails the build if the checksum does not match).
#   * Used as the *only* rclone source in this image (no apk rclone install)
#     to keep the binary version reproducible and avoid double-installing.
#
# error codes
# 0 - exited without problems
# 1 - parameters not supported were used or some unexpected error occurred
# 2 - OS not supported by this script
# 3 - installed version of rclone is up to date
# 4 - supported unzip tools are not available
# 5 - SHA256 verification failed

set -e

#when adding a tool to the list make sure to also add its corresponding command further in the script
unzip_tools_list=('unzip' '7z' 'busybox')

usage() {
	echo "Usage: sudo -v ; curl https://rclone.org/install.sh | sudo bash [-s beta]" 1>&2
	exit 1
}

#check for beta flag
if [ -n "${1:-}" ] && [ "$1" != "beta" ]; then
	usage
fi

if [ -n "${1:-}" ]; then
	install_beta="beta "
fi

# Optional pinning. Empty / unset means "current" (latest stable). Beta forces "current beta".
RCLONE_VERSION="${RCLONE_VERSION:-}"

#create tmp directory and move to it with macOS compatibility fallback
tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t 'rclone-install.XXXXXXXXXX')
cd "$tmp_dir"

#make sure unzip tool is available and choose one to work with
set +e
for tool in "${unzip_tools_list[@]}"; do
	if hash "$tool" 2>>errors; then
		unzip_tool="$tool"
		break
	fi
done
set -e

# exit if no unzip tools available
if [ -z "$unzip_tool" ]; then
	printf '\nNone of the supported tools for extracting zip archives (%s) were found. ' "${unzip_tools_list[*]}"
	printf '%s\n' 'Please install one of them and try again.' ''
	exit 4
fi

# Make sure we don't create a root owned .config/rclone directory #2127
export XDG_CONFIG_HOME=config

#check installed version of rclone to determine if update is necessary
version=$(rclone --version 2>>errors | head -n 1 || true)
if [ -n "${RCLONE_VERSION}" ]; then
	current_version="rclone v${RCLONE_VERSION}"
	resolved_version="${RCLONE_VERSION}"
elif [ -z "${install_beta:-}" ]; then
	current_version=$(curl -fsS https://downloads.rclone.org/version.txt)
	# Strip leading "rclone v" so we can build a versioned download URL that
	# also serves SHA256SUMS (the /current/ alias does NOT publish SHA256SUMS).
	resolved_version="${current_version#rclone v}"
else
	current_version=$(curl -fsS https://beta.rclone.org/version.txt)
	resolved_version=""
fi

if [ "$version" = "$current_version" ]; then
	printf '\nThe requested %sversion of rclone %s is already installed.\n\n' "${install_beta:-}" "${version}"
	exit 3
fi

#detect the platform
OS="$(uname)"
case "$OS" in
Linux)
	OS='linux'
	;;
FreeBSD)
	OS='freebsd'
	;;
NetBSD)
	OS='netbsd'
	;;
OpenBSD)
	OS='openbsd'
	;;
Darwin)
	OS='osx'
	binTgtDir=/usr/local/bin
	man1TgtDir=/usr/local/share/man/man1
	;;
SunOS)
	OS='solaris'
	echo 'OS not supported'
	exit 2
	;;
*)
	echo 'OS not supported'
	exit 2
	;;
esac

OS_type="$(uname -m)"
case "$OS_type" in
x86_64 | amd64)
	OS_type='amd64'
	;;
i?86 | x86)
	OS_type='386'
	;;
aarch64 | arm64)
	OS_type='arm64'
	;;
armv7*)
	OS_type='arm-v7'
	;;
armv6*)
	OS_type='arm-v6'
	;;
arm*)
	OS_type='arm'
	;;
*)
	echo 'OS type not supported'
	exit 2
	;;
esac

#download and unzip
# For both pinned (RCLONE_VERSION set) and unpinned stable installs we always
# pull from the versioned directory because it ships SHA256SUMS alongside the
# zips. The /current/ alias under downloads.rclone.org does NOT.
if [ -n "${resolved_version}" ]; then
	base_url="https://downloads.rclone.org/v${resolved_version}"
	rclone_zip="rclone-v${resolved_version}-${OS}-${OS_type}.zip"
else
	# Beta channel only.
	base_url="https://beta.rclone.org"
	rclone_zip="rclone-beta-latest-${OS}-${OS_type}.zip"
fi

download_link="${base_url}/${rclone_zip}"
curl -OfsS "$download_link"

# Verify SHA256 against the upstream SHA256SUMS file. Mandatory for the
# stable channel (current or pinned). The beta channel does not always ship
# SHA256SUMS at the same path; warn and skip in that case.
if [ -z "${install_beta:-}" ]; then
	sums_url="${base_url}/SHA256SUMS"
	if ! curl -fsS -o SHA256SUMS "${sums_url}"; then
		printf '\n%s\n' "❌ Failed to download SHA256SUMS from ${sums_url}; refusing to install unverified rclone." >&2
		exit 5
	fi
	expected_line="$(grep -E "[[:space:]]\\*?${rclone_zip}\$" SHA256SUMS || true)"
	if [ -z "${expected_line}" ]; then
		printf '\n%s\n' "❌ SHA256SUMS does not contain an entry for ${rclone_zip}; refusing to install." >&2
		exit 5
	fi
	if ! printf '%s\n' "${expected_line}" | sha256sum -c - >/dev/null 2>&1; then
		printf '\n%s\n' "❌ SHA256 verification failed for ${rclone_zip}." >&2
		printf '%s\n' "  Expected line from upstream SHA256SUMS:" >&2
		printf '%s\n' "    ${expected_line}" >&2
		printf '%s\n' "  Local checksum:" >&2
		printf '%s\n' "    $(sha256sum "${rclone_zip}")" >&2
		exit 5
	fi
	printf '%s\n' "✅ SHA256 verified for ${rclone_zip}"
else
	printf '%s\n' "⚠️ Beta channel: skipping SHA256 verification (no canonical SHA256SUMS available)."
fi

unzip_dir="tmp_unzip_dir_for_rclone"
# there should be an entry in this switch for each element of unzip_tools_list
case "$unzip_tool" in
'unzip')
	unzip "$rclone_zip" -d "$unzip_dir"
	;;
'7z')
	7z x "$rclone_zip" "-o$unzip_dir"
	;;
'busybox')
	mkdir -p "$unzip_dir"
	busybox unzip "$rclone_zip" -d "$unzip_dir"
	;;
esac

shopt -s nullglob
_sub=("${unzip_dir}"/*/)
shopt -u nullglob
if [ "${#_sub[@]}" -eq 1 ]; then
	cd "${_sub[0]}" || exit 1
elif [ -f "${unzip_dir}/rclone" ]; then
	cd "${unzip_dir}" || exit 1
else
	printf '%s\n' 'Unexpected unzip layout: need one subdirectory or rclone in unzip root.' >&2
	exit 1
fi

#mounting rclone to environment

case "$OS" in
'linux')
	#binary
	cp rclone /usr/bin/rclone.new
	chmod 755 /usr/bin/rclone.new
	chown root:root /usr/bin/rclone.new
	mv /usr/bin/rclone.new /usr/bin/rclone
	#manual
	if ! [ -x "$(command -v mandb)" ]; then
		echo 'mandb not found. The rclone man docs will not be installed.'
	else
		mkdir -p /usr/local/share/man/man1
		cp rclone.1 /usr/local/share/man/man1/
		mandb
	fi
	;;
'freebsd' | 'openbsd' | 'netbsd')
	#binary
	cp rclone /usr/bin/rclone.new
	chown root:wheel /usr/bin/rclone.new
	mv /usr/bin/rclone.new /usr/bin/rclone
	#manual
	mkdir -p /usr/local/man/man1
	cp rclone.1 /usr/local/man/man1/
	makewhatis
	;;
'osx')
	#binary
	# shellcheck disable=SC2174  # -m applies to leaf dir only (matches upstream install.sh)
	mkdir -m 0555 -p "${binTgtDir}"
	cp rclone "${binTgtDir}/rclone.new"
	mv "${binTgtDir}/rclone.new" "${binTgtDir}/rclone"
	chmod a=x "${binTgtDir}/rclone"
	#manual
	# shellcheck disable=SC2174
	mkdir -m 0555 -p "${man1TgtDir}"
	cp rclone.1 "${man1TgtDir}"
	chmod a=r "${man1TgtDir}/rclone.1"
	;;
*)
	echo 'OS not supported'
	exit 2
	;;
esac

#update version variable post install
version=$(rclone --version 2>>errors | head -n 1)

#cleanup
rm -rf "$tmp_dir"

printf '\n%s has successfully installed.' "$version"
printf '\nNow run "rclone config" for setup. Check https://rclone.org/docs/ for more details.\n\n'
exit 0
