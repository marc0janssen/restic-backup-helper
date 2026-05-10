#!/bin/sh
set -eu

log_usage() {
	echo "Usage: $0 <Dockerfile> <restic-tag>" >&2
	echo "  Bumps VERSION (patch), updates Dockerfile FROM, README release lines," >&2
	echo "  CHANGELOG stub, and VERSION_RESTIC defaults (build-common, examples)." >&2
	echo "  Example: $0 ./Dockerfile 0.18.2" >&2
}

if [ "$#" -ne 2 ]; then
	log_usage
	exit 1
fi

dockerfile_arg="$1"
tag="$2"
repo_root="$(cd "$(dirname "$0")/.." && pwd)"

case "${dockerfile_arg}" in
/*) dockerfile="${dockerfile_arg}" ;;
*) dockerfile="${repo_root}/${dockerfile_arg}" ;;
esac

VERSION_FILE="${repo_root}/VERSION"

if [ ! -f "${dockerfile}" ]; then
	echo "Not a file: ${dockerfile}" >&2
	exit 1
fi
if [ ! -f "${VERSION_FILE}" ]; then
	echo "Missing VERSION: ${VERSION_FILE}" >&2
	exit 1
fi

old_tag="$(sed -n 's/^FROM restic\/restic://p' "${dockerfile}" | head -n1)"
if [ -z "${old_tag}" ]; then
	echo "Could not read FROM restic/restic tag in ${dockerfile}" >&2
	exit 1
fi

if [ "${old_tag}" = "${tag}" ]; then
	echo "[update-restic-base] Already on restic/restic:${tag}; no changes."
	exit 0
fi

old_version="$(sed -n '1{s/^[[:space:]]*//;s/[[:space:]]*$//;p;}' "${VERSION_FILE}")"
if ! echo "${old_version}" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
	echo "VERSION must be semver x.y.z (got '${old_version}')" >&2
	exit 1
fi

major="${old_version%%.*}"
rest="${old_version#*.}"
minor="${rest%%.*}"
patch="${rest#*.}"
patch=$((patch + 1))
new_version="${major}.${minor}.${patch}"

old_rel="${old_version}-${old_tag}"
new_rel="${new_version}-${tag}"

echo "[update-restic-base] restic/restic ${old_tag} -> ${tag}"
echo "[update-restic-base] helper semver ${old_version} -> ${new_version} (release ${old_rel} -> ${new_rel})"

printf '%s\n' "${new_version}" >"${VERSION_FILE}"

sed -i.bak "s#^FROM restic/restic:.*#FROM restic/restic:${tag}#" "${dockerfile}"
rm -f "${dockerfile}.bak"

for readme in "${repo_root}/README.md" "${repo_root}/README-containers.md"; do
	[ -f "${readme}" ] || continue
	sed -i.bak "s|${old_rel}|${new_rel}|g" "${readme}"
	rm -f "${readme}.bak"
done

date_str="$(date +%Y-%m-%d)"
changelog_tmp="$(mktemp)"
trap 'rm -f "${changelog_tmp}"' EXIT INT TERM
awk -v new_rel="${new_rel}" -v date_str="${date_str}" -v new_tag="${tag}" '
	/^## Restic Backup Helper$/ {
		print
		print ""
		print "### " new_rel " (" date_str ")"
		print ""
		print "#### Changed"
		print ""
		print "- Bump Docker base image to `restic/restic:" new_tag "`."
		print ""
		next
	}
	{ print }
' "${repo_root}/CHANGELOG.md" >"${changelog_tmp}"
mv "${changelog_tmp}" "${repo_root}/CHANGELOG.md"
trap - EXIT INT TERM

sync_version_restic_defaults() {
	f="$1"
	[ -f "${f}" ] || return 0
	sed -i.bak \
		-e "s|VERSION_RESTIC:-${old_tag}|VERSION_RESTIC:-${tag}|g" \
		-e "s|^VERSION_RESTIC=${old_tag}|VERSION_RESTIC=${tag}|g" \
		-e "s|^# VERSION_RESTIC=${old_tag}|# VERSION_RESTIC=${tag}|g" \
		-e "s|default ${old_tag}|default ${tag}|g" \
		"${f}"
	rm -f "${f}.bak"
}

for f in \
	"${repo_root}/scripts/build-common.sh" \
	"${repo_root}/build-testing-local.sh" \
	"${repo_root}/build.env.example" \
	"${repo_root}/build-testing.env.example" \
	"${repo_root}/build-testing-local.env.example"; do
	sync_version_restic_defaults "${f}"
done

echo "[update-restic-base] Done. Review diff, especially CHANGELOG wording, before commit."
