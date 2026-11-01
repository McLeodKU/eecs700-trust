# php-study

Each [apache2-study](../apache2-study/) image, paired with the PHP that Debian shipped in
the same era and an exposed `phpinfo()` page, then scanned with nuclei — the PHP companion
to apache2-study.

Requirements: `podman`, `buildah`, network access, and the `apache2-study` images (this
builds them automatically if they're missing).

## Scan with nuclei

`./scan.sh` does everything — build the PHP layer, run, scan, clean up. This is the normal
entry point.

```sh
./scan.sh                      # 10 versions (the apache2-study set); PHP follows each era
./scan.sh 2.4.49 2.4.59        # or name your own apache2-study version(s)
```

Each version's findings land in `reports/<version>.txt`. [nuclei](https://github.com/projectdiscovery/nuclei)
and its templates are pulled automatically — the official container image, with templates
cached in the shared `apache2-study-nuclei-templates` podman volume.

## How PHP is paired with Apache

A PHP image is built `FROM localhost/apache2-study:<ver>` (see `Containerfile`). That base
still points apt at its own moment on `snapshot.debian.org` and pins every package to that
snapshot, so installing `mod_php` pulls the PHP version from the **same era as the Apache
build** — no version is chosen by hand. The Apache binary and its libraries are reused
unchanged; only PHP is added.

| Apache (apache2-study) | Debian era | PHP (observed) |
|---|---|---|
| 2.4.9  | jessie   | 5.6 |
| 2.4.16 | jessie   | 5.6 |
| 2.4.23 | stretch  | 7.x |
| 2.4.29 | stretch  | 7.x |
| 2.4.37 | buster   | 7.x |
| 2.4.43 | buster   | 7.x |
| 2.4.49 | bullseye | 7.4 |
| 2.4.53 | bullseye | 7.4 |
| 2.4.59 | bookworm | 8.2 |
| 2.4.69 | trixie   | 8.4 |

(The exact PHP version each build pulls is printed during the scan and recorded in the
image at `/etc/php-study-version`. Some eras repeat a PHP version — that's Debian's doing,
not a choice here.)

## What the container serves

- `/` — the html5up website template inherited from the apache2-study base image.
- `/info.php` — `<?php phpinfo();` executed by `mod_php`.

```sh
# Peek at a single version by hand:
podman run --rm -p 127.0.0.1:8080:80 localhost/php-study:2.4.49
curl -s http://127.0.0.1:8080/info.php | grep -o 'PHP Version [0-9.]*' | head -1
```

## How it works (what scan.sh does per version)

Reuse (or build) the apache2-study image, layer PHP on top, run it on a private podman
network with **no published port**, and scan it from the official nuclei container on that
same network:

```sh
podman build --build-arg APACHE_IMAGE=localhost/apache2-study:2.4.49 \
    -f Containerfile -t localhost/php-study:2.4.49 <context with info.php>
podman run -d --rm --name php-study-2-4-49 --network apache2-study-net \
    localhost/php-study:2.4.49

ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' php-study-2-4-49)
podman run --rm --network apache2-study-net \
    -v apache2-study-nuclei-templates:/root/nuclei-templates:Z \
    -v ./reports:/reports:Z \
    docker.io/projectdiscovery/nuclei:latest \
    -u "http://$ip" -o /reports/2.4.49.txt -duc -ni -timeout 5 -retries 0
```

Same scanning choices as apache2-study (see its README for the why): target the container
**IP** (not its DNS name, which flakes under load and silently yields 0 findings); no
published port; `-ni` so the scan doesn't hang polling interactsh; full default template
set. nuclei's exposed-`phpinfo` templates find `/info.php` on their own.

## Notes

- One version failing to build (e.g. the usr-merge transition, apache 2.4.54..2.4.58)
  doesn't abort the batch — it's logged and skipped, same as apache2-study.
- `reports/` is generated. `.build-context.*` are temporary build contexts.
- This shares apache2-study's podman network and template volume, so don't run both
  `scan.sh` scripts at the same time.
