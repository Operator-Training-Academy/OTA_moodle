#!/usr/bin/env bash
# =============================================================================
# Upgrade Moodle on the HOST code path (bind mount), then run CLI upgrade.
#
# Usage (from the stack repository root):
#   ./scripts/update-moodle.sh                     # interactive version picker
#   ./scripts/update-moodle.sh MOODLE_502_STABLE    # branch
#   ./scripts/update-moodle.sh MOODLE_405_STABLE
#   ./scripts/update-moodle.sh v5.2.1               # tag
#   ./scripts/update-moodle.sh --list               # list remote branches/tags
#
# Flow:
#   1. Choose target version (argument or prompt)  ← before any pull
#   2. Pull that version from https://github.com/moodle/moodle into MOODLE_CODE_PATH
#   3. Preserve config.php
#   4. Update MOODLE_BRANCH in .env
#   5. Rebuild image (optional) + restart
#   6. Run admin/cli/upgrade.php + purge caches
# =============================================================================
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

MOODLE_REMOTE="${MOODLE_REMOTE:-https://github.com/moodle/moodle.git}"

# ---------------------------------------------------------------------------
# Load paths from .env if present
# ---------------------------------------------------------------------------
if [ -f .env ]; then
    while IFS= read -r line || [ -n "$line" ]; do
        case "$line" in
            ''|\#*) continue ;;
            *=*)
                key="${line%%=*}"
                val="${line#*=}"
                key="$(echo "$key" | tr -d '[:space:]')"
                # strip optional surrounding quotes
                val="${val%\"}"
                val="${val#\"}"
                val="${val%\'}"
                val="${val#\'}"
                export "$key=$val" 2>/dev/null || true
                ;;
        esac
    done < .env
fi

MOODLE_CODE_PATH="${MOODLE_CODE_PATH:-./moodle}"
case "${MOODLE_CODE_PATH}" in
    /*) ;;
    *) MOODLE_CODE_PATH="${REPO_ROOT}/${MOODLE_CODE_PATH}" ;;
esac

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }
step() { echo "--> $*"; }

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Required command not found: $1"
}

list_remote_refs() {
    need_cmd git
    echo ""
    echo "Stable branches (MOODLE_*_STABLE):"
    git ls-remote --heads "${MOODLE_REMOTE}" 'MOODLE_*_STABLE' 2>/dev/null \
        | sed 's|.*refs/heads/||' | sort -r | head -20
    echo ""
    echo "Recent tags (latest 15):"
    git ls-remote --tags --refs "${MOODLE_REMOTE}" 'v*' 2>/dev/null \
        | sed 's|.*refs/tags/||' | sort -V -r | head -15
    echo ""
}

choose_version_interactive() {
    echo ""
    echo "Select Moodle version to upgrade to."
    echo "  Examples:  MOODLE_502_STABLE   MOODLE_405_STABLE   v5.2.1"
    echo ""
    echo "  Tip: run  ./scripts/update-moodle.sh --list  to see remote branches/tags"
    echo ""
    read -r -p "Target branch or tag: " TARGET
    TARGET="$(echo "$TARGET" | tr -d '[:space:]')"
    [ -n "$TARGET" ] || die "No version specified"
    printf '%s' "$TARGET"
}

preserve_config() {
    local dest="$1"
    mkdir -p "${dest}"
    if [ -f "${MOODLE_CODE_PATH}/config.php" ]; then
        cp -a "${MOODLE_CODE_PATH}/config.php" "${dest}/config.php"
        step "Preserved config.php"
    fi
}

restore_config() {
    local src="$1"
    if [ -f "${src}/config.php" ]; then
        cp -a "${src}/config.php" "${MOODLE_CODE_PATH}/config.php"
        chmod 440 "${MOODLE_CODE_PATH}/config.php" 2>/dev/null || true
        step "Restored config.php"
    fi
}

update_moodle_code() {
    local target="$1"
    local preserve_dir
    preserve_dir="$(mktemp -d)"
    # shellcheck disable=SC2064
    trap "rm -rf '${preserve_dir}'" RETURN

    preserve_config "${preserve_dir}"
    mkdir -p "${MOODLE_CODE_PATH}"

    if [ -d "${MOODLE_CODE_PATH}/.git" ]; then
        step "Existing git repo at ${MOODLE_CODE_PATH}"
        git -C "${MOODLE_CODE_PATH}" remote get-url origin >/dev/null 2>&1 \
            || git -C "${MOODLE_CODE_PATH}" remote add origin "${MOODLE_REMOTE}"

        step "Fetching from origin (tags + branches)"
        git -C "${MOODLE_CODE_PATH}" fetch --tags --force origin

        step "Checking out ${target}"
        if git -C "${MOODLE_CODE_PATH}" rev-parse --verify "refs/tags/${target}" >/dev/null 2>&1; then
            git -C "${MOODLE_CODE_PATH}" checkout -f "tags/${target}"
        elif git -C "${MOODLE_CODE_PATH}" rev-parse --verify "origin/${target}" >/dev/null 2>&1; then
            git -C "${MOODLE_CODE_PATH}" checkout -f -B "${target}" "origin/${target}"
            git -C "${MOODLE_CODE_PATH}" pull --ff-only origin "${target}" 2>/dev/null || true
        else
            git -C "${MOODLE_CODE_PATH}" checkout -f "${target}" \
                || die "Could not checkout '${target}'. Use --list to see valid refs."
        fi
    else
        # No .git yet (bootstrap copy or empty dir) — clone chosen version
        local tmp
        tmp="$(mktemp -d)"
        step "Cloning ${target} from ${MOODLE_REMOTE}"
        if ! git clone --depth 1 --branch "${target}" "${MOODLE_REMOTE}" "${tmp}/moodle" 2>/dev/null; then
            rm -rf "${tmp}/moodle"
            git clone "${MOODLE_REMOTE}" "${tmp}/moodle"
            git -C "${tmp}/moodle" fetch --depth 1 origin "refs/tags/${target}:refs/tags/${target}" 2>/dev/null \
                || git -C "${tmp}/moodle" fetch origin "${target}"
            git -C "${tmp}/moodle" checkout "${target}"
        fi

        step "Replacing files in ${MOODLE_CODE_PATH}"
        find "${MOODLE_CODE_PATH}" -mindepth 1 -maxdepth 1 -exec rm -rf {} +
        # shellcheck disable=SC2035
        shopt -s dotglob nullglob
        cp -a "${tmp}/moodle"/* "${MOODLE_CODE_PATH}/"
        shopt -u dotglob nullglob
        if [ -d "${tmp}/moodle/.git" ]; then
            cp -a "${tmp}/moodle/.git" "${MOODLE_CODE_PATH}/.git"
        fi
        rm -rf "${tmp}"
    fi

    restore_config "${preserve_dir}"

    # Match container www-data (Debian UID/GID 33)
    if [ "$(id -u)" -eq 0 ]; then
        chown -R 33:33 "${MOODLE_CODE_PATH}" || chown -R www-data:www-data "${MOODLE_CODE_PATH}" || true
    else
        step "If permission errors appear: sudo chown -R www-data:www-data ${MOODLE_CODE_PATH}"
    fi

    [ -f "${MOODLE_CODE_PATH}/version.php" ] \
        || die "Checkout failed — version.php missing in ${MOODLE_CODE_PATH}"

    step "Installed version.php summary:"
    grep -E '\$release|\$version' "${MOODLE_CODE_PATH}/version.php" 2>/dev/null | head -8 || true
}

update_env_branch() {
    local target="$1"
    if [ -f .env ]; then
        if grep -q '^MOODLE_BRANCH=' .env; then
            sed -i "s|^MOODLE_BRANCH=.*|MOODLE_BRANCH=${target}|" .env
        else
            echo "MOODLE_BRANCH=${target}" >> .env
        fi
        step "Set MOODLE_BRANCH=${target} in .env"
    fi
}

run_cli_upgrade() {
    step "Waiting for moodle container..."
    local i=0
    until docker compose exec -T moodle true 2>/dev/null; do
        i=$((i + 1))
        [ "$i" -lt 30 ] || die "moodle container not reachable"
        sleep 2
    done

    info "Running Moodle CLI upgrade (non-interactive)"
    docker compose exec -T moodle php admin/cli/upgrade.php --non-interactive

    info "Purging caches"
    docker compose exec -T moodle php admin/cli/purge_caches.php || true
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
need_cmd git
need_cmd docker

ARG="${1:-}"

if [ "${ARG}" = "--list" ] || [ "${ARG}" = "-l" ]; then
    list_remote_refs
    exit 0
fi

info "Moodle code path: ${MOODLE_CODE_PATH}"

if [ -n "${ARG}" ]; then
    TARGET="${ARG}"
else
    TARGET="$(choose_version_interactive)"
fi

echo ""
info "Target version: ${TARGET}"
echo "  Remote: ${MOODLE_REMOTE}"
echo "  Code:   ${MOODLE_CODE_PATH}"
echo ""
read -r -p "Proceed with upgrade to '${TARGET}'? [y/N] " CONFIRM
case "${CONFIRM}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
esac

# 1) You already chose the version — now pull it from Moodle GitHub
info "Updating Moodle source on host to ${TARGET}"
update_moodle_code "${TARGET}"

# 2) Remember choice
update_env_branch "${TARGET}"

# 3) Rebuild image (PHP/Apache tooling only; code is on the host mount)
if [ "${SKIP_IMAGE_BUILD:-0}" != "1" ]; then
    info "Rebuilding moodle image (tooling only)"
    docker compose build moodle
fi

# 4) Restart
info "Restarting services"
docker compose up -d

# 5) Schema / plugin upgrade inside Moodle
run_cli_upgrade

echo ""
info "Upgrade complete"
echo "    Target:  ${TARGET}"
echo "    Code:    ${MOODLE_CODE_PATH}"
echo "    Logs:    docker compose logs -f moodle"
echo "    Site:    check WWWROOT in .env"
echo ""
echo "    Skip image rebuild next time:"
echo "      SKIP_IMAGE_BUILD=1 ./scripts/update-moodle.sh ${TARGET}"
