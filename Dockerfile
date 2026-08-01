# syntax=docker/dockerfile:1.7
# Hardened Moodle container — future-proof, CLI-updatable via GitHub
# Default: Moodle 5.2 (MOODLE_502_STABLE) on PHP 8.3 Apache (Bookworm)

ARG PHP_VERSION=8.3
FROM php:${PHP_VERSION}-apache-bookworm

LABEL org.opencontainers.image.title="Hardened Moodle"
LABEL org.opencontainers.image.description="Secure, updateable Moodle LMS container with essential tools"
LABEL org.opencontainers.image.source="https://github.com/YOUR_ORG/moodle-hardened"
LABEL maintainer="you@example.com"

ENV DEBIAN_FRONTEND=noninteractive \
    APACHE_DOCUMENT_ROOT=/var/www/html \
    MOODLE_DATA=/var/moodledata \
    PHP_MEMORY_LIMIT=256M \
    PHP_MAX_EXECUTION_TIME=300 \
    PHP_UPLOAD_MAX_FILESIZE=128M \
    PHP_POST_MAX_SIZE=128M \
    PHP_MAX_INPUT_VARS=5000

# ---------------------------------------------------------------------------
# 1. System packages + tools (nano, git, curl, etc.)
#    Cron is handled by Ofelia sidecar — not installed in this image.
# ---------------------------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        # Core tools requested / useful
        nano git curl wget unzip zip \
        # Locale & timezone
        locales tzdata \
        # PHP extension build deps (purged later)
        $PHPIZE_DEPS \
        libzip-dev libpng-dev libjpeg62-turbo-dev libfreetype6-dev \
        libicu-dev libxml2-dev libldap2-dev libpq-dev \
        libonig-dev libcurl4-openssl-dev libssl-dev \
        # Runtime libs kept
        libzip4 libpng16-16 libjpeg62-turbo libfreetype6 \
        libicu72 libxml2 libldap-2.5-0 libpq5 \
    && sed -i '/en_US.UTF-8/s/^# //g' /etc/locale.gen \
    && locale-gen \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=en_US.UTF-8 \
    LC_ALL=en_US.UTF-8

# ---------------------------------------------------------------------------
# 2. PHP extensions required by Moodle
# ---------------------------------------------------------------------------
RUN docker-php-ext-configure gd --with-freetype --with-jpeg \
    && docker-php-ext-install -j"$(nproc)" \
        gd intl zip soap mysqli pdo_mysql pdo_pgsql opcache \
        ldap exif mbstring curl xml \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apt-get purge -y --auto-remove $PHPIZE_DEPS \
    && rm -rf /tmp/pear /var/cache/apt/* /var/lib/apt/lists/*

# ---------------------------------------------------------------------------
# 3. Apache hardening & document root
# ---------------------------------------------------------------------------
RUN a2enmod rewrite headers expires remoteip \
    && sed -ri -e 's!/var/www/html!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/sites-available/*.conf \
    && sed -ri -e 's!/var/www/!${APACHE_DOCUMENT_ROOT}!g' /etc/apache2/apache2.conf /etc/apache2/conf-available/*.conf \
    && echo "ServerTokens Prod" >> /etc/apache2/conf-available/security.conf \
    && echo "ServerSignature Off" >> /etc/apache2/conf-available/security.conf \
    && a2enconf security

# ---------------------------------------------------------------------------
# 4. Runtime user = www-data (Debian/Apache default, typically UID/GID 33)
#    Matches common existing Moodle host permissions for a drop-in cutover.
#    Apache in this image already runs as www-data; CLI uses the same user.
# ---------------------------------------------------------------------------
# www-data is provided by the base image — ensure home exists for CLI/cron
RUN mkdir -p /var/www && chown www-data:www-data /var/www

# ---------------------------------------------------------------------------
# 5. Workdirs (Moodle code + data are bind-mounted from the host)
#    First-start bootstrap clones Moodle into the host path via entrypoint.
# ---------------------------------------------------------------------------
ARG MOODLE_BRANCH=MOODLE_502_STABLE
ENV MOODLE_BRANCH=${MOODLE_BRANCH}

WORKDIR /var/www/html
RUN mkdir -p ${MOODLE_DATA} \
    && chown www-data:www-data /var/www/html ${MOODLE_DATA} \
    && chmod 770 ${MOODLE_DATA}

# ---------------------------------------------------------------------------
# 6. Config, entrypoint, custom PHP
# ---------------------------------------------------------------------------
COPY --chown=root:root config/php-moodle.ini $PHP_INI_DIR/conf.d/99-moodle.ini
COPY --chown=root:root config/apache-moodle.conf /etc/apache2/conf-available/moodle.conf
RUN a2enconf moodle

COPY --chown=root:root scripts/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod 755 /usr/local/bin/entrypoint.sh

# Healthcheck
HEALTHCHECK --interval=30s --timeout=10s --start-period=120s --retries=3 \
    CMD curl -f http://localhost/ || exit 1

EXPOSE 80

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["apache2-foreground"]
