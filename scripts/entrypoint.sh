#!/bin/bash
set -euo pipefail

MOODLE_DIR=/var/www/html
DATA_DIR=${MOODLE_DATA:-/var/moodledata}
CONFIG_FILE="${MOODLE_DIR}/config.php"
BRANCH="${MOODLE_BRANCH:-MOODLE_502_STABLE}"

echo "==> Hardened Moodle entrypoint"

# ---------------------------------------------------------------------------
# Host bind mounts: ensure directories exist and are owned correctly
# ---------------------------------------------------------------------------
mkdir -p "${DATA_DIR}"
# Code dir may be empty on first start (host mount)
mkdir -p "${MOODLE_DIR}"

# Fix ownership for www-data (UID 33 on Debian) — matches typical host Moodle installs
chown -R www-data:www-data "${DATA_DIR}" || true
chmod 770 "${DATA_DIR}" || true

# ---------------------------------------------------------------------------
# Bootstrap Moodle source if host directory is empty
# ---------------------------------------------------------------------------
if [ ! -f "${MOODLE_DIR}/version.php" ]; then
    echo "==> Host Moodle directory is empty — cloning ${BRANCH}"
    # Clone into a temp dir then move, so we don't leave a partial tree on failure
    TMPCLONE=$(mktemp -d)
    git clone --depth 1 --branch "${BRANCH}" https://github.com/moodle/moodle.git "${TMPCLONE}"
    # Copy contents (including hidden files) into the bind-mounted path
    shopt -s dotglob
    cp -a "${TMPCLONE}"/* "${MOODLE_DIR}/"
    shopt -u dotglob
    rm -rf "${TMPCLONE}"
    chown -R www-data:www-data "${MOODLE_DIR}"
    find "${MOODLE_DIR}" -type d -exec chmod 755 {} \;
    find "${MOODLE_DIR}" -type f -exec chmod 644 {} \;
    echo "==> Moodle ${BRANCH} cloned into host path"
else
    echo "==> Moodle source found on host mount"
fi

# ---------------------------------------------------------------------------
# Generate config.php if missing
# ---------------------------------------------------------------------------
if [ ! -f "${CONFIG_FILE}" ]; then
    echo "==> Generating config.php from environment variables"
    cat > "${CONFIG_FILE}" <<EOF
<?php
unset(\$CFG);
global \$CFG;
\$CFG = new stdClass();

\$CFG->dbtype    = getenv('DB_TYPE') ?: 'pgsql';
\$CFG->dblibrary = 'native';
\$CFG->dbhost    = getenv('DB_HOST') ?: 'postgres';
\$CFG->dbname    = getenv('DB_NAME') ?: 'moodle';
\$CFG->dbuser    = getenv('DB_USER') ?: 'moodle';
\$CFG->dbpass    = getenv('DB_PASSWORD') ?: '';
\$CFG->prefix    = getenv('DB_PREFIX') ?: 'mdl_';
\$CFG->dboptions = [
    'dbpersist' => false,
    'dbsocket'  => false,
    'dbport'    => (int)(getenv('DB_PORT') ?: 5432),
];

\$CFG->wwwroot   = rtrim(getenv('WWWROOT') ?: 'https://moodle.example.com', '/');
\$CFG->dataroot  = '${DATA_DIR}';
\$CFG->admin     = 'admin';
\$CFG->directorypermissions = 02770;

// Redis / Valkey for sessions
\$redis_host = getenv('REDIS_HOST') ?: 'cache';
\$redis_port = (int)(getenv('REDIS_PORT') ?: 6379);
\$redis_prefix = getenv('REDIS_PREFIX') ?: 'moodle_';

\$CFG->session_handler_class = '\\core\\session\\redis';
\$CFG->session_redis_host = \$redis_host;
\$CFG->session_redis_port = \$redis_port;
\$CFG->session_redis_prefix = \$redis_prefix . 'sess_';
\$CFG->session_redis_acquire_lock_timeout = 120;
\$CFG->session_redis_lock_expire = 7200;

\$CFG->alternative_file_system_class = null;

if (filter_var(getenv('REVERSE_PROXY') ?: 'true', FILTER_VALIDATE_BOOLEAN)) {
    \$CFG->reverseproxy = true;
}
if (filter_var(getenv('SSL_PROXY') ?: 'true', FILTER_VALIDATE_BOOLEAN)) {
    \$CFG->sslproxy = true;
}

\$CFG->passwordsaltmain = bin2hex(random_bytes(32));

require_once(__DIR__ . '/lib/setup.php');
EOF
    chown www-data:www-data "${CONFIG_FILE}"
    chmod 440 "${CONFIG_FILE}"
    echo "==> config.php created on host mount"
else
    echo "==> config.php already present — skipping generation"
fi

# ---------------------------------------------------------------------------
# Wait for external PostgreSQL
# ---------------------------------------------------------------------------
echo "==> Waiting for PostgreSQL at ${DB_HOST:-postgres}:${DB_PORT:-5432}..."
MAX_TRIES=60
TRIES=0
until php -r "
\$h = getenv('DB_HOST') ?: 'postgres';
\$p = (int)(getenv('DB_PORT') ?: 5432);
\$u = getenv('DB_USER') ?: 'moodle';
\$pw = getenv('DB_PASSWORD') ?: '';
\$n = getenv('DB_NAME') ?: 'moodle';
try {
    \$dsn = \"pgsql:host=\$h;port=\$p;dbname=\$n\";
    new PDO(\$dsn, \$u, \$pw, [PDO::ATTR_TIMEOUT => 3]);
    exit(0);
} catch (Throwable \$e) {
    exit(1);
}
" 2>/dev/null; do
    TRIES=$((TRIES+1))
    if [ $TRIES -ge $MAX_TRIES ]; then
        echo "ERROR: PostgreSQL not reachable after ${MAX_TRIES} attempts"
        echo "       Check DB_HOST, DB_NETWORK, and that Postgres is running."
        exit 1
    fi
    echo "  ... still waiting (${TRIES}/${MAX_TRIES})"
    sleep 2
done
echo "==> PostgreSQL is ready"

# ---------------------------------------------------------------------------
# First-time install
# ---------------------------------------------------------------------------
if ! php -r "
define('CLI_SCRIPT', true);
require('${MOODLE_DIR}/config.php');
require_once(\$CFG->libdir.'/adminlib.php');
echo empty(\$CFG->version) ? 'notinstalled' : 'installed';
" 2>/dev/null | grep -q installed; then
    echo "==> Running Moodle CLI install (first start)"
    su -s /bin/bash www-data -c "php ${MOODLE_DIR}/admin/cli/install_database.php \
        --agree-license \
        --fullname='${SITE_FULLNAME:-Hardened Moodle}' \
        --shortname='${SITE_SHORTNAME:-Moodle}' \
        --adminuser='${ADMIN_USER:-admin}' \
        --adminpass='${ADMIN_PASS}' \
        --adminemail='${ADMIN_EMAIL:-admin@example.com}' \
        --lang=en" || {
            echo "WARNING: install_database.php returned non-zero (may already be partially installed)"
        }
    echo "==> Install finished"
else
    echo "==> Moodle already installed — skipping install"
fi

echo "==> Starting Apache (cron via Ofelia)"
exec "$@"
