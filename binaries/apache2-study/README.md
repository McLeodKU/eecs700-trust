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

## Notes

- Debian didn't package every upstream release (no 2.4.3, 2.4.5, 2.4.8, 2.4.11, ...);
  check `./fetch.sh list`.
- These are Debian's builds: they include Debian's patches.
- Versions from before 2015 run on jessie, not wheezy: wheezy's glibc crashes on this
  host's kernel.
- `./fetch.sh clean` removes `build/` and the images.
