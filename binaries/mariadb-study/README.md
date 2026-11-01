# mariadb-study

Each [apache2-study](../apache2-study/) image, paired with the MariaDB server that Debian
shipped in the same era, then scanned with nuclei — the database companion to apache2-study
and [php-study](../php-study/).

Debian has shipped `mariadb-server` in every snapshot this covers — MariaDB 5.5 in the 2014
jessie era through MariaDB 11.x on trixie — so one package name spans the whole range. (In
the oldest eras "MariaDB 5.5" is MariaDB's drop-in fork of MySQL 5.5.)

Requirements: `podman`, `buildah`, network access, and the `apache2-study` images (this
builds them automatically if they're missing).

## Scan with nuclei

`./scan.sh` does everything — build the DB layer, run, scan, clean up.

```sh
./scan.sh                      # 10 versions (the apache2-study set); MariaDB follows each era
./scan.sh 2.4.49 2.4.69        # or name your own apache2-study version(s)
```

Each version's findings land in `reports/<version>.txt`. nuclei and its templates are
pulled automatically — the official container image, with templates cached in the shared
`apache2-study-nuclei-templates` podman volume.

## How MariaDB is paired with Apache

A MariaDB image is built `FROM localhost/apache2-study:<ver>` (see `Containerfile`). That
base still points apt at its own moment on `snapshot.debian.org` and pins every package to
that snapshot, so installing `mariadb-server` pulls the database from the **same era as the
Apache build** — no version is chosen by hand.

| Apache (apache2-study) | Debian era | MariaDB (observed) |
|---|---|---|
| 2.4.9  | jessie   | 5.5  |
| 2.4.16 | jessie   | 5.5  |
| 2.4.23 | stretch  | 10.1 |
| 2.4.29 | stretch  | 10.1 |
| 2.4.37 | buster   | 10.3 |
| 2.4.43 | buster   | 10.3 |
| 2.4.49 | bullseye | 10.5 |
| 2.4.53 | bullseye | 10.5 |
| 2.4.59 | bookworm | 10.11 |
| 2.4.69 | trixie   | 11.x |

(The exact version each build pulls is printed during the scan and recorded in the image at
`/etc/mariadb-study-version`. Some eras repeat a version — that's Debian's doing.)

## Scanning a database (not HTTP)

Unlike apache2-study and php-study, the target is a TCP database on port 3306, so `scan.sh`
points nuclei at the bare IP (no `http://`) and runs only nuclei's **service** templates:

```
-pt javascript,tcp,ssl -ni -nmhe -timeout 5 -retries 0
```

- `-pt javascript,tcp,ssl` — the DB host has no web server, so the full HTTP template set
  would only fail. These protocol types carry the MySQL/MariaDB templates (detection runs
  over nuclei's `javascript` engine).
- `-nmhe` — never skip the host on errors. Without it, the failing HTTP-style probes would
  trip nuclei's max-host-error limit and drop the target before the DB templates run.
- `-ni`, `-timeout 5`, `-retries 0` — same rationale as the other studies.

A typical finding is `mysql-info` reporting the server version over port 3306.

## How it works (what scan.sh does per version)

Reuse (or build) the apache2-study image, layer MariaDB on top, run it on a private podman
network with **no published port**, and scan it from the official nuclei container:

```sh
podman build --build-arg APACHE_IMAGE=localhost/apache2-study:2.4.49 \
    -f Containerfile -t localhost/mariadb-study:2.4.49 <context>
podman run -d --rm --name mariadb-study-2-4-49 --network mariadb-study-net \
    localhost/mariadb-study:2.4.49            # starts mariadbd on 0.0.0.0:3306

ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' mariadb-study-2-4-49)
podman run --rm --network mariadb-study-net \
    -v apache2-study-nuclei-templates:/root/nuclei-templates:Z \
    -v ./reports:/reports:Z \
    docker.io/projectdiscovery/nuclei:latest \
    -u "$ip" -o /reports/2.4.49.txt -pt javascript,tcp,ssl -duc -ni -nmhe -timeout 5 -retries 0
```

## Notes

- One version failing to build doesn't abort the batch — it's logged and skipped, same as
  the other studies.
- Uses its own podman network (`mariadb-study-net`) but shares the template volume, so it
  can run without colliding with apache2-study/php-study.
- `reports/` is generated; `.build-context.*` are temporary build contexts.
