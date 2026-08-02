#!/usr/bin/env bash
# Update Moodle code in a running Docker container.
# Usage: moodle-update [MOODLE_BRANCH_OR_TAG]
set -euo pipefail

MOODLE_REMOTE="${MOODLE_REMOTE:-https://github.com/moodle/moodle.git}"
MOODLE_CONTAINER="${MOODLE_CONTAINER:-moodle_app}"
MAX_TAGS=30
MAINTENANCE_ENABLED=false

die() {
    echo "ERROR: $*" >&2
    exit 1
}

need_docker() {
    command -v docker >/dev/null 2>&1 || die "docker is required"
    docker inspect --format '{{.State.Running}}' "${MOODLE_CONTAINER}" 2>/dev/null | grep -qx true \
        || die "the ${MOODLE_CONTAINER} container must be running before an update"
}

leave_in_maintenance() {
    if [ "${MAINTENANCE_ENABLED}" = true ]; then
        echo "ERROR: Update failed; Moodle remains in maintenance mode." >&2
    fi
}

trap leave_in_maintenance EXIT

load_refs() {
    mapfile -t BRANCHES < <(
        docker exec "${MOODLE_CONTAINER}" git ls-remote --heads "${MOODLE_REMOTE}" 'MOODLE_*_STABLE' \
            | while IFS=$'\t' read -r _ ref; do printf '%s\n' "${ref#refs/heads/}"; done \
            | sort -r
    )
    mapfile -t TAGS < <(
        docker exec "${MOODLE_CONTAINER}" git ls-remote --tags --refs "${MOODLE_REMOTE}" 'v*' \
            | while IFS=$'\t' read -r _ ref; do printf '%s\n' "${ref#refs/tags/}"; done \
            | sort -Vr
    )
    TAGS=("${TAGS[@]:0:${MAX_TAGS}}")

    ((${#BRANCHES[@]})) || die "no stable Moodle branches were returned from ${MOODLE_REMOTE}"
}

list_refs() {
    load_refs
    printf '%s\n' "Stable branches:"
    printf '  %s\n' "${BRANCHES[@]}"
    printf '%s\n' ""
    printf '%s\n' "Recent release tags:"
    printf '  %s\n' "${TAGS[@]}"
}

choose_ref() {
    load_refs
    local options=("${TAGS[@]}" "${BRANCHES[@]}" "Enter a branch or tag manually" "Quit")
    local choice

    echo "Select the Moodle release to install on the persistent code mount."
    echo "Production sites should prefer a specific v* release tag."
    echo "The container image will not be pulled or rebuilt."
    PS3="Version number: "
    select choice in "${options[@]}"; do
        case "${choice}" in
            "Enter a branch or tag manually")
                read -r -p "Moodle branch or tag: " TARGET
                [ -n "${TARGET}" ] || { echo "A version is required."; continue; }
                break
                ;;
            "Quit") exit 0 ;;
            "") echo "Enter a number from the menu." ;;
            *) TARGET="${choice}"; break ;;
        esac
    done
}

update_code() {
    local target="$1"

    docker exec -i -u root "${MOODLE_CONTAINER}" bash -s -- "${MOODLE_REMOTE}" "${target}" <<'EOF'
set -euo pipefail

remote="$1"
target="$2"
code_dir=/var/www/moodle
preserve_dir="$(mktemp -d)"
trap 'rm -rf "${preserve_dir}"' EXIT

if [ -f "${code_dir}/config.php" ]; then
    cp -a "${code_dir}/config.php" "${preserve_dir}/config.php"
fi

    update_git_checkout() {
        if ! git -C "${code_dir}" diff --quiet || ! git -C "${code_dir}" diff --cached --quiet; then
            echo "ERROR: Moodle core has tracked local modifications." >&2
            echo "       Commit, stash, or revert them before updating." >&2
            git -C "${code_dir}" status --short >&2
            exit 1
        fi

        git -C "${code_dir}" fetch --tags origin
        if ! git -C "${code_dir}" show-ref --verify --quiet "refs/tags/${target}"; then
            git -C "${code_dir}" fetch origin "refs/heads/${target}:refs/remotes/origin/${target}" || {
                echo "ERROR: Moodle ref '${target}' was not found" >&2
                exit 1
            }
        fi

        if git -C "${code_dir}" show-ref --verify --quiet "refs/tags/${target}"; then
            git -C "${code_dir}" checkout "${target}"
        elif git -C "${code_dir}" show-ref --verify --quiet "refs/remotes/origin/${target}"; then
            if git -C "${code_dir}" show-ref --verify --quiet "refs/heads/${target}"; then
                git -C "${code_dir}" checkout "${target}"
            else
                git -C "${code_dir}" checkout --track -b "${target}" "origin/${target}"
            fi
            git -C "${code_dir}" rebase "origin/${target}"
        else
            echo "ERROR: Moodle ref '${target}' was not found" >&2
            exit 1
        fi
    }

    if git -C "${code_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
        git -C "${code_dir}" remote get-url origin >/dev/null 2>&1 \
            || git -C "${code_dir}" remote add origin "${remote}"
        update_git_checkout
    else
        echo "==> Adopting the existing Moodle code as a Git checkout"
        git -C "${code_dir}" init
        git -C "${code_dir}" remote add origin "${remote}"
        git -C "${code_dir}" fetch --tags origin

        if git -C "${code_dir}" show-ref --verify --quiet "refs/tags/${target}"; then
            git -C "${code_dir}" reset --hard "${target}"
        else
            git -C "${code_dir}" fetch origin "refs/heads/${target}:refs/remotes/origin/${target}" || {
                echo "ERROR: Moodle ref '${target}' was not found" >&2
                exit 1
            }
        fi

        if git -C "${code_dir}" show-ref --verify --quiet "refs/remotes/origin/${target}"; then
            git -C "${code_dir}" reset --hard "origin/${target}"
            git -C "${code_dir}" checkout -B "${target}" "origin/${target}"
        elif ! git -C "${code_dir}" show-ref --verify --quiet "refs/tags/${target}"; then
            echo "ERROR: Moodle ref '${target}' was not found" >&2
            exit 1
        fi
    fi

if [ -f "${preserve_dir}/config.php" ]; then
    cp -a "${preserve_dir}/config.php" "${code_dir}/config.php"
fi

    chown -R www-data:www-data "${code_dir}"
    su -s /bin/bash www-data -c "cd '${code_dir}' && COMPOSER_CACHE_DIR=/tmp/composer-cache composer install --no-dev --prefer-dist --optimize-autoloader --no-interaction --no-progress"
    chmod 440 "${code_dir}/config.php" 2>/dev/null || true

    mapfile -t plugin_repositories < <(find "${code_dir}" -type d -name .git ! -path "${code_dir}/.git" -printf '%h\n')
    if ((${#plugin_repositories[@]})); then
        echo "==> Plugin/theme Git repositories were preserved and not updated:"
        printf '    %s\n' "${plugin_repositories[@]}"
        echo "    Update each repository separately after checking Moodle-version compatibility."
    fi
EOF
}

run_upgrade() {
    echo "==> Restarting Moodle to load the selected source"
    docker restart "${MOODLE_CONTAINER}" >/dev/null

    local attempts=0
    until docker exec "${MOODLE_CONTAINER}" true >/dev/null 2>&1; do
        attempts=$((attempts + 1))
        [ "${attempts}" -lt 30 ] || die "moodle did not become ready after restart"
        sleep 2
    done

    echo "==> Running Moodle database upgrade"
    docker exec -u www-data "${MOODLE_CONTAINER}" php /var/www/moodle/admin/cli/upgrade.php --non-interactive
    echo "==> Purging Moodle caches"
    docker exec -u www-data "${MOODLE_CONTAINER}" php /var/www/moodle/admin/cli/purge_caches.php
}

need_docker

case "${1:-}" in
    --list|-l)
        list_refs
        exit 0
        ;;
    "") choose_ref ;;
    *) TARGET="$1" ;;
esac

echo "==> Selected Moodle ref: ${TARGET}"
read -r -p "Update the persistent code mount and run the database upgrade? [y/N] " confirm
case "${confirm}" in
    y|Y|yes|YES) ;;
    *) echo "Aborted."; exit 0 ;;
esac

echo "==> Enabling Moodle maintenance mode"
docker exec -u www-data "${MOODLE_CONTAINER}" php /var/www/moodle/admin/cli/maintenance.php --enable
MAINTENANCE_ENABLED=true

echo "==> Updating Moodle source and Composer dependencies"
update_code "${TARGET}"
run_upgrade
echo "==> Disabling Moodle maintenance mode"
docker exec -u www-data "${MOODLE_CONTAINER}" php /var/www/moodle/admin/cli/maintenance.php --disable
MAINTENANCE_ENABLED=false
echo "==> Moodle update complete: ${TARGET}"
