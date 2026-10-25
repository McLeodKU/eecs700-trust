# apache2-study

Debian's prebuilt Apache httpd binaries for any 2.4.x version Debian shipped, pulled from
[snapshot.debian.org](https://snapshot.debian.org): the files for Ghidra, and a container
image to run each version.

Requirements: `buildah`, `podman`, `python3`, network access.

## Fetch binaries (for analysis)

```sh
./fetch.sh list            # versions available, with their Debian revisions
./fetch.sh 2.4.9 2.4.49    # download and extract
```

Each version lands in `build/<version>/`:

| Path | Contents |
|---|---|
| `rootfs/usr/sbin/apache2` | the server binary |
| `rootfs/usr/lib/apache2/modules/` | modules (`mod_*.so`) |
| `rootfs/usr/lib/x86_64-linux-gnu/`, `rootfs/lib/` | shared libraries it links against |
| `rootfs/usr/lib/debug/` | debug symbols |
| `debs/` | the original `.deb` packages |
| `MANIFEST` | Debian version, snapshot date, every package and version |

Options: `--no-dbg` skips debug symbols; `--pkgs "apache2 apache2-utils"` also fetches
the config files and support tools.

## Run a version

```sh
./fetch.sh image 2.4.9                                   # builds localhost/apache2-study:2.4.9
podman run --rm -p 8080:80 localhost/apache2-study:2.4.9
curl -I http://127.0.0.1:8080/                           # Server: Apache/2.4.9 (Debian)
```

The image is built from `Containerfile` on the Debian release of that version's era,
with the same binary and library versions as `build/<version>/`.

## Scan with nuclei

`./scan.sh` does everything — build, run, scan, clean up. This is the normal entry point;
you shouldn't need the manual steps below.

```sh
./scan.sh                      # 10 versions spread from 2.4.9 to 2.4.69
./scan.sh 2.4.49 2.4.58        # or name your own
```

Each version's findings land in `reports/<version>.txt`. Requirements: `podman`,
`buildah`, `unzip`, network access. [nuclei](https://github.com/projectdiscovery/nuclei)
and its templates are pulled automatically — the official container image, with templates
cached in the `apache2-study-nuclei-templates` podman volume, so nothing depends on a
nuclei install or templates in your home directory. The template under
`resources/html5up-verti.zip` is served as the site at `/var/www/html/`.

Example `reports/2.4.49.txt` (abridged):

```
[waf-detect:apachegeneric]          [http] [info] http://10.89.0.2
[http-missing-security-headers:...] [http] [info] http://10.89.0.2   (one per missing header)
[apache-detect]                     [http] [info] http://10.89.0.2 ["Apache/2.4.49 (Debian)"]
[options-method]                    [http] [info] http://10.89.0.2 ["GET,POST,OPTIONS,HEAD"]
```

### How it works (what scan.sh does per version)

Build the image, run it on a private podman network with **no published port**, and scan
it from the official nuclei container on that same network:

```sh
podman network create apache2-study-net
podman run -d --rm --name apache2-study-2-4-49 --network apache2-study-net \
    localhost/apache2-study:2.4.49

# Target the container's IP, resolved from the scanner's side of the network.
ip=$(podman inspect -f '{{range .NetworkSettings.Networks}}{{.IPAddress}}{{end}}' apache2-study-2-4-49)
podman run --rm --network apache2-study-net \
    -v apache2-study-nuclei-templates:/root/nuclei-templates:Z \
    -v ./reports:/reports:Z \
    docker.io/projectdiscovery/nuclei:latest \
    -u "http://$ip" -o /reports/2.4.49.txt -duc

podman stop apache2-study-2-4-49
podman network rm apache2-study-net
```

- **No `-p`**: the container is reachable only from the network, never the host or LAN —
  these builds have known CVEs. In rootless podman (the default) the container's IP is
  unreachable from the host anyway, but the scanner shares the network and can reach it.
- **Target the IP, not the container name.** Under a full-template scan's concurrency,
  rootless podman's DNS flakes; nuclei then marks the target "unresponsive permanently"
  and silently reports **0 findings** — a false negative. The IP keeps DNS off the hot path.
- No `-tags`/`-pt` filter: the full default template set runs. There is no "scan only this
  port" flag — HTTP templates stay on the URL's port, so an isolated container is what
  keeps the scan off the host's own services (SSH, MySQL, ...).
- Templates mount at nuclei's default path (`/root/nuclei-templates`) or helper-file loads
  are denied; `-duc` skips the per-scan update check (scan.sh refreshes the volume once up front).
- The official image is pinned to its own nuclei version; a host `go install` binary is
  dynamically linked and won't run inside an arbitrary container.

## Notes

- Debian didn't package every upstream release (no 2.4.3, 2.4.5, 2.4.8, 2.4.11, ...);
  check `./fetch.sh list`.
- These are Debian's builds: they include Debian's patches.
- Versions from before 2015 run on jessie, not wheezy: wheezy's glibc crashes on this
  host's kernel.
- `./fetch.sh clean` removes `build/` and the images.
