# cannonmg-4200-setup

Canon PIXMA MG4200 USB printing on NixOS — no root, no kernel modules, no
`/usr/lib/bjlib`.

## Why this exists

The MG4200 (2010-era) is only supported by Canon's **cnijfilter 3.80** driver
generation (model id 405). nixpkgs only packages 2.80 and 4.00, neither of
which knows this printer. Canon's 3.80 tarball ships prebuilt amd64 binaries
that hardcode `/usr/lib/bjlib`, `/usr/bin/gs` and `/usr/bin/cifmg4200` — paths
that don't exist on NixOS, and creating them needs root.

On top of that, CUPS 2.4 refuses absolute filter paths from PPDs, so the
Canon filter cannot be plugged into the queue the normal way.

## How it works

```
file ──gs──▶ PS ──pstocanonij──▶ Canon BJL/raster ──lp -o raw──▶ CUPS queue
                (proot fakes the hardcoded paths)        │
                                              stock `usb` backend
                                              usb://Canon/MG4200%20series?...
```

- The **stock CUPS `usb` backend** (shipped with cups, runs as the `cups`
  user which is in group `lp`) talks to the printer's class-07 printer
  interface — no `usblp` kernel module needed.
- **proot** bind-fakes `/usr/lib/bjlib`, `/usr/bin/gs`, `/usr/bin/cifmg4200`
  for Canon's binaries, unprivileged.
- `libtiff.so.4` is shimmed to current `libtiff.so.6` (symbol-compatible for
  the subset `cifmg4200` uses).
- Output is submitted as a **raw** job, bypassing CUPS' filter chain.

## Usage

```sh
# one-time queue creation (needs CUPS admin: wheel/lpadmin group)
nix run .#setup-mg4200-queue

# print anything (PDF, PS, images, text)
nix run .#print-mg4200 -- file.pdf
nix run .#print-mg4200 -- file.pdf -o "PageSize=A4 CNQuality=4"

# or drop into a shell with everything on PATH
nix develop
print-mg4200 file.pdf
```

Queue name is `mg4200`; override with `MG4200_QUEUE` and the device URI with
`MG4200_DEVICE_URI` (e.g. when the USB serial differs — the setup script
auto-detects the URI via `lpinfo -v`).

Useful PPD options (see `lpoptions -p mg4200 -l`): `PageSize`, `MediaType`,
`CNQuality` (1–5), `CNGrayscale`, `Duplex`, `BorderlessPrinting`.

## Packages in the flake

| attr                 | what                                                        |
| -------------------- | ----------------------------------------------------------- |
| `cnijfilter-mg4200`  | Canon 3.80 binaries + bjlib tables + PPD, assembled store path |
| `pstocanonij`        | proot wrapper around Canon's pstocanonij filter             |
| `print-mg4200`       | end-to-end print command (default package)                  |
| `setup-mg4200-queue` | one-time `lpadmin` queue creation                           |

## Notes

- Canon's driver is under an unfree license; the flake sets `allowUnfree`
  only for its own package set and never commits Canon binaries — they are
  fetched from Canon's CDN (`gdlp01.c-wss.com`) at build time.
- The PPD (`canonmg4200.ppd`) is also inside the driver package; the queue
  uses it for option metadata even though the filter chain is bypassed.
- WiFi printing (the MG4200 supports it; `cifmg4200.conf` has
  `supportnetwork MG4200 = 1` and the tarball ships a `cnijnet` backend) is
  deferred; the same raw-job pipeline works over `socket://<ip>:9100`.
