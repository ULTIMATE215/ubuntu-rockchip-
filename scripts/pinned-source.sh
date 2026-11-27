# shellcheck shell=bash

fetch_pinned_source() {
    local url="$1"
    local dest="$2"
    local sha256="$3"
    local temporary

    if [ -f "${dest}" ] && printf '%s  %s\n' "${sha256}" "${dest}" | sha256sum --check --status; then
        return 0
    fi

    temporary=$(mktemp "${dest}.XXXXXX")
    if ! curl --fail --silent --show-error --location --retry 3 --max-time 300 -o "${temporary}" "${url}" \
        || ! printf '%s  %s\n' "${sha256}" "${temporary}" | sha256sum --check --status; then
        unlink "${temporary}"
        echo "Download or checksum verification failed for ${url}" >&2
        return 1
    fi
    mv -T "${temporary}" "${dest}"
}
