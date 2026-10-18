{
  description = ''
    Canon PIXMA MG4200 USB printing on NixOS without root.

    Canon's official cnijfilter 3.80 driver (the only generation that supports
    the MG4200 series) ships prebuilt amd64 binaries that hardcode
    /usr/lib/bjlib, /usr/bin/gs and /usr/bin/cifmg4200. This flake assembles
    those binaries into a self-contained store path and wraps pstocanonij with
    proot so the hardcoded paths resolve without root.

    CUPS 2.4 refuses absolute filter paths from PPDs, so printing goes through
    the print-mg4200 script: file -> pstocanonij -> raw CUPS job -> stock usb
    backend (usb://Canon/MG4200%20series?...).
  '';

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = import nixpkgs {
        inherit system;
        config.allowUnfree = true; # Canon's driver license is unfree
      };

      # ------------------------------------------------------------------
      # libtiff.so.4 shim: Canon binaries were linked against the libtiff 4
      # ABI (so.4); current libtiff provides so.6, symbol-compatible for the
      # subset cif uses.
      # ------------------------------------------------------------------
      shim = pkgs.runCommand "libtiff-so4-shim" { } ''
        mkdir -p $out/lib
        ln -s ${pkgs.libtiff.out or pkgs.libtiff}/lib/libtiff.so.6 $out/lib/libtiff.so.4
      '';

      # ------------------------------------------------------------------
      # The Canon driver: unpack the official deb tarball, assemble a
      # self-contained root. No compilation; the .so files are Canon's
      # prebuilt amd64 libraries (model id 405).
      #
      # Source preference: the tarball vendored in ./vendor (survives Canon
      # deadlinking their CDN); falls back to fetching from Canon if the
      # vendor file is absent. Both paths pin the same sha256.
      # ------------------------------------------------------------------
      driverTarballHash = "sha256-Iw8b8QBPKjcoYW4amudjryI7XNK2h+zhuMzHxQtYxYo=";
      driverTarballName = "cnijfilter-mg4200series-3.80-1-deb.tar.gz";

      cnijfilter-mg4200 = pkgs.stdenv.mkDerivation {
        pname = "cnijfilter-mg4200";
        version = "3.80-1";

        src =
          if pkgs.lib.pathExists ./vendor/${driverTarballName} then
            ./vendor/${driverTarballName}
          else
            pkgs.fetchurl {
              url = "https://gdlp01.c-wss.com/gds/8/0100004668/01/${driverTarballName}";
              sha256 = driverTarballHash;
            };

        nativeBuildInputs = [ pkgs.binutils ]; # ar

        unpackPhase = ''
          runHook preUnpack
          tar xzf $src
          cd cnijfilter-mg4200series-3.80-1-deb/packages
          for d in cnijfilter-common_3.80-1_amd64 cnijfilter-mg4200series_3.80-1_amd64; do
            mkdir -p "x_$d"
            ( cd "x_$d" && ar x "../$d.deb" && tar xzf data.tar.gz )
          done
          runHook postUnpack
        '';

        dontConfigure = true;
        dontBuild = true;
        # Canon libs dlopen each other without DT_NEEDED entries;
        # shrinking the rpath would break them (same reasoning as nixpkgs'
        # cnijfilter_* packages).
        dontPatchELF = true;

        installPhase = ''
          runHook preInstall

          mkdir -p $out/bin $out/filter $out/lib/bjlib $out/ppd

          # model-specific + common prebuilt libraries
          cp -a x_cnijfilter-mg4200series_3.80-1_amd64/usr/lib/libcnbp* $out/lib/
          cp -a x_cnijfilter-common_3.80-1_amd64/usr/lib/libcnnet* $out/lib/

          # model tables (cifmg4200.conf, cnb_4050.tbl, ...)
          cp -a x_cnijfilter-mg4200series_3.80-1_amd64/usr/lib/bjlib/* $out/lib/bjlib/
          cp -a x_cnijfilter-common_3.80-1_amd64/usr/lib/bjlib/* $out/lib/bjlib/

          cp x_cnijfilter-mg4200series_3.80-1_amd64/usr/bin/cifmg4200 $out/bin/
          cp x_cnijfilter-common_3.80-1_amd64/usr/lib/cups/filter/pstocanonij $out/filter/pstocanonij.bin
          cp x_cnijfilter-common_3.80-1_amd64/usr/lib/cups/backend/cnijusb $out/bin/ || true
          cp x_cnijfilter-mg4200series_3.80-1_amd64/usr/share/ppd/canonmg4200.ppd $out/ppd/

          # unversioned .so symlinks (the binaries link against these)
          ( cd $out/lib
            for f in *.so.*; do ln -s "$f" "''${f%%.so.*}.so"; done )

          runHook postInstall
        '';

        meta = {
          description = "Canon IJ Printer Driver 3.80 (MG4200 series, prebuilt amd64)";
          homepage = "https://www.canon.com/support/";
          license = pkgs.lib.licenses.unfree;
          sourceProvenance = with pkgs.lib.sourceTypes; [ binaryNativeCode ];
          platforms = [ "x86_64-linux" ];
        };
      };

      # ------------------------------------------------------------------
      # pstocanonij wrapper: proot fakes the hardcoded /usr/lib/bjlib,
      # /usr/bin/gs and /usr/bin/cifmg4200 paths. Runs unprivileged.
      # ------------------------------------------------------------------
      pstocanonij = pkgs.writeShellScriptBin "pstocanonij-mg4200" ''
        D=${cnijfilter-mg4200}
        export LD_LIBRARY_PATH="$D/lib:${shim}/lib:${pkgs.libpng12}/lib:${pkgs.libtiff.out or pkgs.libtiff}/lib:${pkgs.popt}/lib:${pkgs.cups.lib}/lib"
        export TMPDIR=''${TMPDIR:-/tmp}
        exec ${pkgs.proot}/bin/proot -r / -0 \
          -b "${pkgs.ghostscript}/bin/gs:/usr/bin/gs" \
          -b "$D/bin/cifmg4200:/usr/bin/cifmg4200" \
          -b "$D/lib/bjlib:/usr/lib/bjlib" \
          "$D/filter/pstocanonij.bin" "$@"
      '';

      # ------------------------------------------------------------------
      # print-mg4200: the whole pipeline in one command.
      #   print-mg4200 file.pdf [-o "CUPS options"]
      # ------------------------------------------------------------------
      print-mg4200 = pkgs.writeShellScriptBin "print-mg4200" ''
        set -e
        D=${cnijfilter-mg4200}
        GS=${pkgs.ghostscript}/bin/gs
        QUEUE=''${MG4200_QUEUE:-mg4200}
        URI=''${MG4200_DEVICE_URI:-"usb://Canon/MG4200%20series?serial=943468&interface=1"}

        if [ $# -lt 1 ]; then
          echo "usage: print-mg4200 file.(ps|pdf|txt|png...) [-o 'opt=val ...']" >&2
          exit 1
        fi
        IN=$1; shift
        OPTS=""
        if [ "''${1:-}" = "-o" ]; then OPTS=$2; shift 2; fi

        PS=$(mktemp "''${TMPDIR:-/tmp}/mg4200.XXXXXX.ps")
        JOB=$(mktemp "''${TMPDIR:-/tmp}/mg4200.XXXXXX.bin")
        trap 'rm -f "$PS" "$JOB"' EXIT

        case "$IN" in
          *.ps) cp "$IN" "$PS" ;;
          *) "$GS" -q -dNOPROMPT -dBATCH -dSAFER -sDEVICE=ps2write -sOutputFile="$PS" "$IN" ;;
        esac

        PPD="$D/ppd/canonmg4200.ppd" DEVICE_URI="$URI" \
          ${pstocanonij}/bin/pstocanonij-mg4200 1 "''${USER:-user}" "''${IN##*/}" 1 "$OPTS" "$PS" > "$JOB"

        echo "generated $(stat -c%s "$JOB") bytes of Canon BJL data" >&2
        lp -d "$QUEUE" -o raw -T 300 "$JOB"
      '';

      # ------------------------------------------------------------------
      # setup-mg4200-queue: create the CUPS queue (run once, needs CUPS
      # admin rights — on NixOS that means the wheel/lpadmin group).
      # ------------------------------------------------------------------
      setup-mg4200-queue = pkgs.writeShellScriptBin "setup-mg4200-queue" ''
        D=${cnijfilter-mg4200}
        URI=''${MG4200_DEVICE_URI:-"usb://Canon/MG4200%20series?serial=943468&interface=1"}
        # find the real URI if the serial differs:
        if ! lpinfo -v 2>/dev/null | grep -qF "$URI"; then
          found=$(lpinfo -v 2>/dev/null | grep -i "usb://Canon/MG4200" | head -1 | awk '{print $3}')
          [ -n "$found" ] && URI="$found"
        fi
        echo "device URI: $URI"
        lpadmin -p mg4200 -E -v "$URI" -P "$D/ppd/canonmg4200.ppd" \
          -o printer-is-shared=false
        echo "queue 'mg4200' ready. Print with: print-mg4200 file.pdf"
      '';
    in
    {
      packages.${system} = {
        inherit cnijfilter-mg4200 pstocanonij print-mg4200 setup-mg4200-queue;
        default = print-mg4200;
      };

      devShells.${system}.default = pkgs.mkShell {
        packages = [
          print-mg4200
          setup-mg4200-queue
          cnijfilter-mg4200
          pkgs.cups
          pkgs.ghostscript
        ];
        shellHook = ''
          echo "Canon MG4200 setup. Queue: mg4200. Print: print-mg4200 file.pdf"
          echo "Driver root: ${cnijfilter-mg4200}"
        '';
      };
    };
}
