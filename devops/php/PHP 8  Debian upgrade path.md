# Upgrading PHP 8.1 → 8.2 on Debian (Sury repo)

Runbook for moving a PHP-FPM application from 8.1 to 8.2 using packages from `packages.sury.org`. Sury installs each PHP version side by side under `/etc/php/8.x/`, so the approach is: install 8.2 next to 8.1, migrate config, verify, cut over, then remove 8.1.

> **Note:** PHP 8.2 reaches end of life on **December 31, 2026**. Everything here works the same for 8.3 or 8.4. Swap the version number.

Environment this was written against: HAProxy → PHP-FPM (no Apache in the request path), PostgreSQL, Composer-managed project.

---

## 1. Plan the package set

Refresh the repo and list what's installed for 8.1:

```bash
sudo apt update
dpkg -l | awk '/^ii/ && /php8.1/ {print $2}'
```

Do a dry run of the equivalent 8.2 set. `-s` simulates. Nothing is changed and no `sudo` is needed:

```bash
PKGS=$(dpkg -l | awk '/^ii/ && /php8.1/ {print $2}' | sed 's/php8\.1/php8.2/')
apt -s --no-install-recommends install $PKGS | awk '/^Inst/ {print $2}'
```

- Without `--no-install-recommends`, apt pulls in extra packages (Recommends). The `php8.2` metapackage can drag in `libapache2-mod-php8.2` even on an FPM setup.
- If a mapped package doesn't exist for 8.2, the simulation stops with `Unable to locate package`. Drop it and handle it separately.

### Inspecting packages

```bash
apt policy php8.2-fpm                 # installed vs candidate version, and which repo (Sury vs Debian)
apt show php8.2-fpm                   # version, Depends/Recommends/Suggests, description
apt list --installed 'php8.1*'        # installed versions, wildcards allowed
apt list --upgradable 'php*'          # what has a newer version available
apt-cache search '^php8.2-'           # every 8.2 package the repos offer (find extension names)
apt-cache depends php8.2              # what a package needs (shows Depends "or" alternatives)
apt rdepends --installed php8.1-common  # what installed packages depend on it
dpkg -L php8.2-common                 # files the package installed
dpkg -S /usr/lib/php/20220829/pdo.so  # which package owns a file
apt changelog php8.2-fpm              # changelog for the candidate version
```

- `apt show -a <package>` shows every available version, not just the candidate.
- `dpkg -L` is a quick way to confirm where the module `.ini` sources live (`/usr/share/php8.2-*/`).
- `dpkg -S` returning "no path found" means the file came from PECL or a manual install, not a package.

### Drop what you don't use

- **`libapache2-mod-php8.x`**: not needed if FPM serves PHP. Installing it can enable the module and switch Apache to the prefork MPM.
- **`php8.x-xdebug`**: fine on dev boxes. Leave it off production, because it slows every request.

## 2. Install

```bash
sudo apt install --no-install-recommends php8.2 php8.2-cli php8.2-common php8.2-fpm \
  php8.2-opcache php8.2-readline php8.2-amqp php8.2-bcmath php8.2-curl \
  php8.2-pgsql php8.2-xml php8.2-dev php8.2-xdebug
```

Adjust the list to match your dry run.

## 3. Make sure every module's `.ini` exists

**Gotcha:** after install, `/etc/php/8.2/mods-available/` may be missing most of the `php8.2-common` and `php8.2-pgsql` modules (ctype, pdo, pgsql, tokenizer, and others) even though the packages show as installed.

**Why:** Debian doesn't ship these `.ini` files as ordinary package files. The package's install script copies them from `/usr/share/php8.2-*/` into `mods-available/` using `ucf`, and `ucf` remembers files it has already placed. If 8.2 was installed before and `/etc/php/8.2` was later deleted by hand, `ucf` treats the missing files as deliberate removals and won't restore them.

Compare the two versions:

```bash
ls /etc/php/8.1/mods-available/ /etc/php/8.2/mods-available/
find /usr/share/php8.2-* -type f      # what the packages actually ship
```

Restore the missing files. `cp -n` never overwrites existing ones:

```bash
for f in /usr/share/php8.2-*/*/*.ini; do
    sudo cp -n "$f" /etc/php/8.2/mods-available/
done
```

### Enable them (conf.d symlinks)

**Option A:** let `phpenmod` create the links. It reads the `; priority=` line in each `.ini` to set the numeric prefix:

```bash
for f in /usr/share/php8.2-*/*/*.ini; do
    sudo phpenmod -v 8.2 -s ALL "$(basename "$f" .ini)"
done
```

**Option B:** mirror 8.1's enabled set exactly. Run this from the target `conf.d` directory, once for `fpm` and once for `cli`:

```bash
cd /etc/php/8.2/fpm/conf.d
find /etc/php/8.1/fpm/conf.d/ -type l | while read l; do
    ln -s /etc/php/8.2/mods-available/$(basename $l | sed -r 's/^[0-9]+-//') $(basename $l)
done
```

The `sed` matters: link names carry a priority prefix (`20-calendar.ini`), but the targets don't (`calendar.ini`). Without stripping the prefix, every new link is broken.

### Verify

```bash
find /etc/php/8.2 -xtype l                  # broken symlinks; should list nothing
find /etc/php/8.2 -type l -printf '%p -> %l\n'
diff <(php8.1 -m) <(php8.2 -m)              # should be empty when done
```

### Modules not provided by packages

Anything installed with PECL or by hand for 8.1 won't carry over. In this setup that was `openswoole` and `psr`:

```bash
dpkg -S /etc/php/8.1/mods-available/psr.ini   # "no path found" = not from a package
apt policy php8.2-psr                         # Sury may package it
sudo pecl install openswoole                  # otherwise build against 8.2 (needs php8.2-dev)
```

Remove any `conf.d` links to them until the modules exist for 8.2, or FPM will log warnings.

Also diff any customized module config, e.g. `xdebug.ini`:

```bash
diff /etc/php/8.1/mods-available/xdebug.ini /etc/php/8.2/mods-available/xdebug.ini
```

## 4. Migrate FPM configuration

Three places to check under `/etc/php/8.x/fpm/`:

| File | Holds | Approach |
|---|---|---|
| `pool.d/*.conf` | Listen address, user, pm tuning, per-pool settings | Copy, then fix version-specific paths |
| `php.ini` | PHP settings for FPM | Re-apply only your changes onto the 8.2 file |
| `php-fpm.conf` | Global daemon settings | Usually stock; check, keep 8.2 default |

This helper compares files with comments and blank lines stripped and `8.1` rewritten to `8.2`, so only real customizations remain:

```bash
cmp_conf() { diff <(grep -Ev '^\s*(;|$)' "$1" | sed 's/8\.1/8.2/g') <(grep -Ev '^\s*(;|$)' "$2"); }

cmp_conf /etc/php/8.1/fpm/php-fpm.conf   /etc/php/8.2/fpm/php-fpm.conf
cmp_conf /etc/php/8.1/fpm/php.ini        /etc/php/8.2/fpm/php.ini
cmp_conf /etc/php/8.1/cli/php.ini        /etc/php/8.2/cli/php.ini
cmp_conf /etc/php/8.1/fpm/pool.d/www.conf /etc/php/8.2/fpm/pool.d/www.conf
```

`<` lines are your 8.1 settings, and `>` lines are 8.2 defaults.

### `php.ini` differences you can expect

| Line | Meaning | Action |
|---|---|---|
| `> mail.mixed_lf_and_crlf = Off` | New in 8.2, `Off` keeps old behavior | None |
| `< mysqli.reconnect = Off` | Removed in 8.2 | None |
| `< session.upload_progress.enabled = Off` | Local customization (default is `On`) | Re-apply |

```bash
sudo sed -i 's/^;\?\s*session.upload_progress.enabled\s*=.*/session.upload_progress.enabled = Off/' /etc/php/8.2/fpm/php.ini
```

**Tip:** put local overrides in `/etc/php/8.2/fpm/conf.d/99-local.ini` instead of editing `php.ini`. The next upgrade is then a one-file copy.

### `php-fpm.conf`: the pid file

- FPM writes its master PID to the `pid =` path at startup and deletes it on clean shutdown. FPM itself never reads the file back.
- Under systemd (Debian runs FPM with `--nodaemonize`, `Type=notify`), systemd tracks the PID itself. The file only matters to external tools, mainly the logrotate hook that sends `USR1` to reopen logs.
- Check whether anything references it, and add `pid = /run/php/php8.2-fpm.pid` under `[global]` if so. It's harmless either way.

```bash
grep -n pid /etc/php/8.2/fpm/php-fpm.conf /usr/lib/php/php8.2-fpm-reopenlogs /lib/systemd/system/php8.2-fpm.service
```

`log_level = notice` is the default, so omitting it changes nothing.

### Pools

For each pool, check:

- **`listen`**: give 8.2 its own address so both versions can run during cutover. Socket: `/run/php/php8.2-fpm.sock`. TCP: a different port (e.g. 9001 vs 9000). Two pools on the same port means the second fails to start.
- **`listen.owner` / `listen.group` / `listen.mode`**: copy exactly. HAProxy's user must be able to reach the socket.
- **`user` / `group`**, **`pm.*`**: copy as-is.
- **Paths containing `8.1`**: the `sed` in `cmp_conf` hides these, so search directly:
  ```bash
  grep -rn '8\.1' /etc/php/8.2/fpm/
  ```
- Don't leave stray copies ending in `.conf` (e.g. `www.conf.bak.conf`). Duplicate pool names stop FPM from starting.

### Validate and start

```bash
sudo php-fpm8.2 -t
sudo systemctl restart php8.2-fpm
systemctl status php8.2-fpm
ls -l /run/php/
```

## 5. Check code compatibility

No single tool catches everything. Use them together:

| Tool | Method | Catches | Misses |
|---|---|---|---|
| `php8.2 -l` | Compiles each file | Parse errors, `${var}` interpolation | Anything at runtime |
| PHPCompatibility | Token patterns (static) | Removed/deprecated functions, `${}`, version-specific syntax | Most dynamic properties (no type info) |
| PHPStan | Type inference (static) | Dynamic properties, deprecated calls | `${}` interpolation (syntax only) |
| Deprecation log under 8.2 | Real execution | Everything that runs | Code paths not exercised |

What changed in 8.2 (all deprecations, nothing removed outright):

- Dynamic properties (setting an undeclared property)
- `"${var}"` and `"${expr}"` string interpolation; use `"{$var}"`
- `utf8_encode()` / `utf8_decode()`
- `'self::method'`, `'static::method'`, `'parent::method'` string callables

### Lint

```bash
find src -name '*.php' -print0 \
  | xargs -0 -n1 php8.2 -d error_reporting=E_ALL -d display_errors=1 -l 2>&1 \
  | grep -v 'No syntax errors'
```

### PHPCompatibility

Recommended install, from the project root (per the [PHPCompatibility README](https://github.com/PHPCompatibility/PHPCompatibility)):

```bash
composer config allow-plugins.dealerdirect/phpcodesniffer-composer-installer true
composer require --dev phpcompatibility/php-compatibility:"^10.0.0@dev"
```

Verify:

```bash
vendor/bin/phpcs -i     # PHPCompatibility and PHPCSUtils should both be listed
```

> **Check for newer instructions:** installation steps and version constraints change between releases. Before installing, check the [PHPCompatibility README](https://github.com/PHPCompatibility/PHPCompatibility#installation) and, if upgrading from 9.x, the [Upgrading to PHPCompatibility 10.0](https://github.com/PHPCompatibility/PHPCompatibility/wiki/Upgrading-to-PHPCompatibility-10.0) guide.

- The `allow-plugins` line pre-approves the Composer plugin that registers the standard with phpcs, so the install also works non-interactively.
- PHP_CodeSniffer (4.0.2+) and PHPCSUtils are pulled in automatically as dependencies. Don't add `squizlabs/php_codesniffer` yourself; that's the old package name, and 10.x needs the newer phpcs.
- 10.x requires PHP 7.2+ to *run* phpcs.
- Keep the `^10.0.0@dev` constraint while 10.x is pre-release. Without it, Composer installs 9.3.5 (2019), which lacks most PHP 8 checks.
- To update later: `composer update phpcompatibility/php-compatibility --with-dependencies`

`phpcs.xml` in the project root (auto-discovered when run from there):

```xml
<?xml version="1.0"?>
<ruleset name="PHP 8.2 compat">
    <file>src</file>
    <exclude-pattern>*/vendor/*</exclude-pattern>
    <arg name="extensions" value="php"/>
    <arg name="parallel" value="1"/>
    <arg value="ps"/>
    <config name="testVersion" value="8.1-8.2"/>
    <rule ref="PHPCompatibility"/>
</ruleset>
```

- `testVersion 8.1-8.2` flags code that fails on *either* version, so it also catches 8.2-only syntax while you still run 8.1.
- Keep `parallel` low. A high value plus a `vendor/` scan crashed the container.
- A path on the command line replaces `<file>`, and everything else in the ruleset still applies. Command-line `--runtime-set` overrides `<config>`.
- Which PHP binary runs phpcs doesn't matter. Results depend on `testVersion`.

Run:

```bash
vendor/bin/phpcs --report=source      # overview, grouped by sniff
vendor/bin/phpcs --report=full --report-file=compat-8.2.txt
```

ERROR = breaks on a target version. WARNING = deprecated.

#### Scanning file by file

```bash
cd /var/www/html
find . -type f | grep '\.php$' | grep -v '^\./vendor/' | grep -v stubs | grep -v composer \
  | while read -r f; do
      echo "== $f"
      nice -n 19 /usr/bin/php8.2 vendor/bin/phpcs --parallel=1 \
        --runtime-set testVersion 8.2 "$f" < /dev/null
    done
```

**Gotcha:** without `< /dev/null`, the loop stops after the first file. phpcs reads stdin, which inside `cmd | while read` is the pipe carrying the rest of the file list.

`vendor/bin/phpcs -v` also prints each file as it's processed, with token counts, which helps spot huge generated files.

#### Why exclude `vendor/`

- You can't fix it there. The fix is updating the package.
- Libraries contain polyfills and version-conditional code that produce false positives.
- It's often far larger than your own code.

Check dependencies through Composer instead:

```bash
composer why-not php 8.2
composer outdated --direct
```

Scan a specific abandoned package only if it has a loose constraint and no recent releases.

### PHPStan

```bash
composer require --dev phpstan/phpstan phpstan/phpstan-deprecation-rules phpstan/extension-installer
composer config allow-plugins.phpstan/extension-installer true
```

**`extension-installer`:** a Composer plugin. Extensions declare their config files in their own `composer.json` (`extra.phpstan.includes`). After each install or update, the plugin writes a generated list that PHPStan loads at startup, so installed extensions are active without `includes:` lines. Composer 2.2+ blocks plugins unless they're allowed. In non-interactive runs (CI, deploys), an un-allowed plugin is silently skipped, so set `allow-plugins` ahead of time and commit it. Confirm with `vendor/bin/phpstan diagnose`.

`phpstan.neon`:

```neon
parameters:
    level: 0
    phpVersion: 80200
    paths:
        - src
    scanDirectories:
        - src
        - stubs
    parallel:
        maximumNumberOfProcesses: 2
```

- **`paths`**: what gets analyzed and reported. `vendor/` is excluded automatically unless `paths` covers the project root (e.g. `.`), in which case add `excludePaths: [vendor]`.
- **`scanDirectories`**: read for class definitions, never reported on. Command-line paths don't replace it, which fixes "unknown class" errors when analyzing single files for classes Composer's autoloader can't find. The underlying fix is a `classmap` entry in `composer.json` plus `composer dump-autoload`.
- **`level`**: can be overridden with `--level=N`.
- **`phpVersion`**: config only, no command-line flag. Use a small override file per target:
  ```neon
  # phpstan-82.neon
  includes:
      - phpstan.neon
  parameters:
      phpVersion: 80200
  ```
  `vendor/bin/phpstan analyse -c phpstan-82.neon`
- **Memory limit**: command line only, not in neon.

Run:

```bash
nice -n 19 php8.2 vendor/bin/phpstan analyse --memory-limit=512M
php8.2 vendor/bin/phpstan analyse --memory-limit=512M src/Some/File.php   # single file
```

**Sizing memory:** the limit applies to *each* process. Total use can reach `(maximumNumberOfProcesses + 1) × memory-limit`. Keep that below the container's memory or the OOM killer may step in.

For the 8.2 pass, look for **"Access to an undefined property"** (dynamic properties) and **"Call to deprecated function"**. After those are handled, generate a baseline for the remaining legacy noise:

```bash
php8.2 vendor/bin/phpstan analyse --memory-limit=512M --generate-baseline
```

```neon
includes:
    - phpstan-baseline.neon
```

### Runtime check: log deprecations under 8.2

Enable deprecation logging for 8.2 with a drop-in file (easy to remove later). Create it in both `fpm/conf.d` and `cli/conf.d`:

```ini
; /etc/php/8.2/{fpm,cli}/conf.d/99-deprecations.ini
error_reporting = E_ALL
log_errors = On
display_errors = Off
error_log = /var/log/php8.2-deprecations.log
```

```bash
sudo touch /var/log/php8.2-deprecations.log
sudo chown www-data: /var/log/php8.2-deprecations.log   # your pool's user
sudo systemctl restart php8.2-fpm
```

Then run the tests or exercise the app under 8.2 and grep the log for `Deprecated`.

- Debian's production default (`E_ALL & ~E_DEPRECATED & ~E_STRICT`) hides exactly these warnings, so `E_ALL` is required.
- `php_admin_value[error_log]` / `[error_reporting]` in a pool config overrides `conf.d`.
- A custom `set_error_handler()` that returns anything other than `false` stops PHP's own logging. Deprecations then appear only wherever the app's handler sends them.

## 6. Cut over

HAProxy talks to FPM directly. Point the backend `server` line at the 8.2 socket or port:

```bash
sudo haproxy -c -f /etc/haproxy/haproxy.cfg && sudo systemctl reload haproxy
```

With both FPM versions running, rollback is a one-line change. With `fcgi-app`, `docroot` and `path-info` stay the same; only the `server` address changes.

Switch the CLI (cron jobs, Composer):

```bash
sudo update-alternatives --set php /usr/bin/php8.2
php -v
```

## 7. Clean up

Once 8.2 has been stable for a while:

```bash
sudo systemctl disable --now php8.1-fpm
sudo apt purge 'php8.1*'
sudo apt autoremove
```

### Apache and mod_php

If FPM serves PHP, `libapache2-mod-php8.1` is unused. If HAProxy talks to FPM directly, Apache was likely only installed as its dependency:

```bash
systemctl is-active apache2
apt -s remove libapache2-mod-php8.1 apache2     # simulate first
```

If Apache stays, check `a2query -M`. mod_php forces `prefork`, and FPM works better with `event`.

### `ssl-cert`

Provides the self-signed "snakeoil" certificate, the `ssl-cert` group (read access to `/etc/ssl/private/`), and `make-ssl-cert`. Apache pulls it in, but **PostgreSQL's default config uses the snakeoil cert** for SSL. Check before removing:

```bash
apt rdepends --installed ssl-cert
getent group ssl-cert
grep -rl snakeoil /etc 2>/dev/null
sudo apt-mark manual ssl-cert     # keep it out of autoremove
```

---

## Quick reference: gotchas

| Symptom | Cause | Fix |
|---|---|---|
| Dry run installs more than 8.1 had | Recommends | `--no-install-recommends` |
| Modules missing from `mods-available` | `ucf` won't restore files it thinks you deleted | Copy from `/usr/share/php8.2-*/` |
| New conf.d links are broken | Link names have a priority prefix, targets don't | Strip `^[0-9]+-`, or use `phpenmod` |
| `while read` loop stops after one file | Command inside loop reads stdin | `< /dev/null` |
| Container crashes during scan | High parallelism, scanning `vendor/` | Limit workers, scope paths, `nice` |
| PHPStan misses `${var}` | It's a syntax deprecation, not a deprecated symbol | phpcs or `php8.2 -l` |
| Unknown classes when analyzing one file | Classes only found by scanning `paths` | `scanDirectories` or Composer `classmap` |
| 2nd FPM fails to start | Both pools on the same port | Separate port/socket per version |