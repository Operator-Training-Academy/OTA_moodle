# Hardened Moodle Container

This repository publishes a hardened PHP/Apache Moodle base image to GitHub Container Registry (GHCR). The image contains a Composer-built Moodle source seed for first start. Moodle code and its `vendor/` directory then persist on the host and are updated interactively from Moodle's GitHub repository.

## Architecture

| Component | Choice |
|---|---|
| Application base | GHCR image: PHP 8.4, Apache, extensions, Composer, Moodle source seed |
| Database | External PostgreSQL on an external Docker network |
| Cache | Valkey sidecar on an internal Docker network |
| Cron | Ofelia sidecar, executing Moodle cron every minute |
| Persistent files | Host-mounted Moodle code (including `vendor/`) and `moodledata` |

`systemctl` is deliberately not provided. Running systemd in a container requires privileged access and weakens the container boundary. Ofelia is the dedicated scheduler.

The in-container layout follows Moodle 5.2's public-directory model:

```text
/var/www/moodle         Moodle source and config.php
/var/www/moodle/public  Apache document root
/moodledata             Moodle writable data
```

## Publishing

GitHub Actions publishes `linux/amd64` and `linux/arm64` images to:

```text
ghcr.io/operator-training-academy/ota_moodle
```

Pushes to `main` publish `latest` and a commit-SHA tag. Git tags such as `v5.2.1` publish versioned tags. The workflow also creates provenance and SBOM attestations.

The first GHCR publish may create a private package. Make it public in the package settings if anonymous image pulls are required. For a private package, authenticate on each deployment host:

```bash
echo "$GHCR_TOKEN" | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

The workflow's manual trigger accepts a Moodle branch or tag for the source seed. Rebuild and publish the image when its OS, PHP, Apache, PHP extensions, or hardening configuration needs an update. Routine Moodle upgrades use the interactive CLI updater below.

## Deploy

Create the external networks once, using the values configured in `.env`:

```bash
docker network create nginx-proxy-manager
docker network create postgres-net
mkdir -p ./moodle ./moodledata
sudo chown -R 33:33 ./moodledata
```

Valkey recommends enabling memory overcommit on the Docker host:

```bash
sudo sysctl -w vm.overcommit_memory=1
```

Persist this setting using your host operating system's sysctl configuration.

Create `.env` with at least these values:

```dotenv
OTA_IMAGE_TAG=latest
WWWROOT=https://moodle.example.com
DB_HOST=postgres
DB_PORT=5432
DB_NAME=moodle
DB_USER=moodle
DB_PASSWORD=replace-with-a-database-secret
ADMIN_PASS=replace-with-a-strong-admin-password
MOODLE_PASSWORD_SALT_MAIN=replace-with-a-persistent-random-secret
PROXY_NETWORK=nginx-proxy-manager
DB_NETWORK=postgres-net
```

### Host Deployment Access

Moodle code is writable by a trusted host deployment group, while Apache's `www-data`
user can only read it. Create the group and add the host user that deploys Moodle:

```bash
sudo groupadd --force moodle-deploy
sudo usermod --append --groups moodle-deploy "$USER"
getent group moodle-deploy
```

Set `MOODLE_DEPLOY_GID` in `.env` to the numeric GID printed by the last command,
then sign out and back in before editing code as that user. For example, if the
group is GID `1001`, add this to `.env`:

```dotenv
MOODLE_DEPLOY_GID=1001
```

For an existing deployment, or before the first start, set the code mount's
ownership and permissions. Substitute the values of `MOODLE_CODE_PATH` and
`MOODLEDATA_PATH`; for example, this deployment uses `/moodle/moodle` and
`/moodle/moodle_data`:

```bash
sudo chown -R root:moodle-deploy /moodle/moodle
sudo find /moodle/moodle -type d -exec chmod 2775 {} +
sudo find /moodle/moodle -type f -exec chmod 664 {} +
sudo apt-get install -y acl
sudo setfacl -R -m u:ubuntu:rwX /moodle/moodle_data
sudo find /moodle/moodle_data -type d -exec setfacl -m d:u:ubuntu:rwx {} +
```

The ACL gives `ubuntu` persistent access to `moodledata` without adding it to
numeric GID `33`, which is the container's `www-data` identity. Startup and
`moodle-update` preserve the code deployment group; Moodle continues to own
`moodledata` as UID/GID `33`.

Generate `MOODLE_PASSWORD_SALT_MAIN` once, retain it securely, and use the same value on every replacement container:

```bash
openssl rand -hex 32
```

Start the stack:

```bash
docker compose pull
docker compose up -d
docker compose logs -f moodle
```

Point Nginx Proxy Manager at `moodle_app:80` on the shared proxy network. No host port is published by default.

### Image Processing

The image includes ImageMagick and PHP's `imagick` extension for plugins such as
Offline Quiz. After Portainer pulls a newly published image and redeploys the
stack, verify both interfaces from the Docker host:

```bash
docker exec --user www-data moodle_app php -m | grep -x imagick
docker exec --user www-data moodle_app php --ri imagick
docker exec moodle_app convert -version
```

### Existing Deployment Migration

If upgrading an existing deployment that used `/var/moodledata`, stop the stack and update the persisted Moodle `config.php` before starting this version:

```bash
docker compose down
sed -i "s|/var/moodledata|/moodledata|g" ./moodle/config.php
docker compose up -d
```

The host directories themselves do not move: `./moodle` is now mounted at `/var/www/moodle`, and `./moodledata` is now mounted at `/moodledata`. Adjust the command if `MOODLE_CODE_PATH` uses a different host directory.

## Update Moodle

The image tag controls the PHP/Apache base. It does not select Moodle's running version. To update Moodle, first back up PostgreSQL and both persistent directories. Install the standalone host updater outside the writable Moodle mounts:

```bash
sudo install -o root -g root -m 0750 scripts/update-moodle.sh /usr/local/sbin/moodle-update
sudo moodle-update --list
```

Alternatively, download only the script from a reviewed, pinned repository commit:

```bash
UPDATE_SCRIPT_REV=<reviewed-commit-sha>
curl -fsSLo /tmp/moodle-update "https://raw.githubusercontent.com/Operator-Training-Academy/OTA_moodle/${UPDATE_SCRIPT_REV}/scripts/update-moodle.sh"
sudo install -o root -g root -m 0750 /tmp/moodle-update /usr/local/sbin/moodle-update
rm /tmp/moodle-update
```

Run `moodle-update` from the Docker host, not inside `moodle_app`. It targets the `moodle_app` container by default; set `MOODLE_CONTAINER` if your deployment uses a different container name. The host requires Bash and Docker CLI access, while Git and Composer run inside Moodle's container. The updater enables maintenance mode before changing code and leaves it enabled if an update fails.

The menu lists stable branches and recent release tags directly from `moodle/moodle`. Production sites should select a specific `v*` release tag rather than tracking a stable branch. The updater follows Moodle's Git administrator workflow: it fetches and checks out the selected tag, or rebases the selected stable branch. It does not delete untracked files, so custom plugins and themes remain in place.

The updater requires the persistent Moodle code directory to already be a Git checkout with an `origin` remote. It refuses to overwrite tracked Moodle core modifications or to downgrade the installed database version. It reports untracked plugins and themes that it will preserve, but refuses untracked paths outside approved plugin/theme locations so they can be reviewed first. It also reports nested Git repositories for plugins and themes without updating them; review each plugin's Moodle-version compatibility and update it separately.

To select a known ref without the menu:

```bash
sudo moodle-update MOODLE_502_STABLE
sudo moodle-update v5.2.1
```

List the available menu entries without updating:

```bash
sudo moodle-update --list
```

The updater does not pull or rebuild the GHCR image. To update the base image after it is published, set `OTA_IMAGE_TAG` to the desired infrastructure image version and run `docker compose pull && docker compose up -d`.

Rolling back Moodle code after a completed schema upgrade is not generally safe; restore the matching PostgreSQL and persistent-directory backups instead.

## Security Properties

- The root filesystem is read-only. Apache can read Moodle code but only writes to `moodledata`; a trusted host deployment group can modify code.
- The first start seeds the code mount with Moodle and its production Composer dependencies.
- Interactive updates install Composer dependencies from the selected Moodle ref's lock file.
- `moodledata` is outside the web root.
- Apache blocks dependency, VCS, test, and metadata paths from HTTP access.
- The application drops all Linux capabilities except those needed by Apache and data ownership, and uses `no-new-privileges`.
- Valkey is internal-only. PostgreSQL and the reverse proxy are attached through explicit external networks.

## Useful Commands

```bash
docker compose exec moodle php admin/cli/cron.php
docker compose exec moodle php admin/cli/upgrade.php --non-interactive
docker compose exec moodle php admin/cli/purge_caches.php
docker compose logs -f moodle ofelia
```

## Reusable Test Instance

`docker-compose.test.yml` runs a persistent Moodle 5.2 test instance using the local `ota-moodle` image. It has dedicated PostgreSQL, Valkey, Moodle-code, and Moodle-data volumes. Any plugin can be tested by mounting its repository through `.test.env`; no files are added to that plugin repository.

```bash
docker build -t ota-moodle:test .
cp .test.env.example .test.env
# Set TEST_PLUGIN_PATH to the plugin repository's absolute path.
# Set TEST_PLUGIN_TARGET to its Moodle destination, for example:
# public/blocks/quiz_assistant
docker compose --env-file .test.env -f docker-compose.test.yml up -d
docker compose --env-file .test.env -f docker-compose.test.yml exec --user www-data moodle \
  php admin/cli/upgrade.php --non-interactive
docker compose --env-file .test.env -f docker-compose.test.yml exec --user www-data moodle \
  php admin/cli/cfg.php --name=enablemobilewebservice --set=1
```

Open <http://localhost:8082> and sign in with the admin credentials in `.test.env`. Restarting the stack preserves its Moodle installation and database. To reset all test data, run `docker compose --env-file .test.env -f docker-compose.test.yml down --volumes`.

To load later source changes into the mounted plugin destination, run the plugin copy service followed by Moodle's upgrade and cache purge:

```bash
docker compose --env-file .test.env -f docker-compose.test.yml run --rm plugin
docker compose --env-file .test.env -f docker-compose.test.yml exec --user www-data moodle \
  php admin/cli/upgrade.php --non-interactive
docker compose --env-file .test.env -f docker-compose.test.yml exec --user www-data moodle \
  php admin/cli/purge_caches.php
```

For Moodle App testing, start the quick tunnel before the first Moodle start, copy its `https://...trycloudflare.com` URL from the logs into `WWWROOT` in `.test.env`, then start Moodle:

```bash
docker compose --env-file .test.env -f docker-compose.test.yml --profile tunnel up -d tunnel
docker compose --env-file .test.env -f docker-compose.test.yml logs tunnel
docker compose --env-file .test.env -f docker-compose.test.yml up -d
```

The Moodle App must use the HTTPS tunnel URL. Reset the test volumes before changing `WWWROOT`, because Moodle stores that URL in its generated `config.php`.

## License

This repository is MIT. Moodle is GPLv3+.
