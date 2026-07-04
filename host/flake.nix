{
  description = "BuranBrew host, contains CHIP Tool, control model, and telemetry stack";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-25.11";

  outputs = { self, nixpkgs }:
    let
      systems = [ "aarch64-linux" "x86_64-linux" ];
      forAll = f: nixpkgs.lib.genAttrs systems f;

      # ------------------------------------------------------------------
      # CHIP Tool release assets
      #
      # chip-tool shall match the NCS release used to build the firmware.
      # The prebuilt binaries are downloaded from the corresponding
      # nrfconnect/sdk-connectedhomeip release and pinned by content hash.
      # ------------------------------------------------------------------
      ncsTag = "v3.3.0";
      chipToolAssets = {
        aarch64-linux = {
          name = "chip-tool_arm64";
          hash = "sha256-pl7UVlv883dZhc9vgmAYSUT6lLzBJt1p7jCITx+4bhs=";
        };
        x86_64-linux = {
          name = "chip-tool_x64";
          hash = "sha256-mlsf5j/FRQ4xeE1itjv0awvINjD/L+IXNblnUxIBfbk=";
        };
      };

      perSystem = system:
        let
          # timescaledb's advanced features are under the source-available
          # TSL license, which nixpkgs marks "unfree".
          pkgs = import nixpkgs {
            inherit system;
            config.allowUnfreePredicate = p:
              builtins.elem (nixpkgs.lib.getName p) [ "timescaledb" ];
          };
          asset = chipToolAssets.${system};

          pythonEnv = pkgs.python3.withPackages (ps: [
            ps.pyyaml
            ps.redis
          ]);

          # ------------------------------------------------------------------
          # CHIP Tool
          #
          # Packages Nordic Semiconductor's prebuilt Matter controller binary
          # and patches its dynamic-library paths for the Nix environment.
          # ------------------------------------------------------------------
          chip-tool = pkgs.stdenv.mkDerivation {
            pname = "chip-tool";
            version = ncsTag;

            src = pkgs.fetchurl {
              url = "https://github.com/nrfconnect/sdk-connectedhomeip/releases/download/${ncsTag}/${asset.name}";
              inherit (asset) hash;
            };

            dontUnpack = true;
            # autoPatchelfHook prepares prebuilt ELF binaries for use inside the Nix environment.
            nativeBuildInputs = [ pkgs.autoPatchelfHook ];
            buildInputs = [
              pkgs.avahi # for mDNS
              pkgs.glib
              pkgs.stdenv.cc.cc.lib # libstdc++, libgcc_s
            ];

            installPhase = ''
              runHook preInstall
              install -Dm755 $src $out/bin/chip-tool
              runHook postInstall
            '';

            meta = {
              description = "Matter controller (prebuilt, nrfconnect/sdk-connectedhomeip ${ncsTag})";
              platforms = systems;
              sourceProvenance = [ pkgs.lib.sourceTypes.binaryNativeCode ];
            };
          };
          # ------------------------------------------------------------------
          # BuranBrew control model
          #
          # The fermentation control model and its default
          # configuration, then exposes it through the buranbrew-model wrapper.
          # CHIP Tool is added to PATH for Matter device communication.
          # ------------------------------------------------------------------
          buranbrew-model = pkgs.stdenvNoCC.mkDerivation {
            pname = "buranbrew-model";
            version = "1.0.0";
            src = ./models;

            nativeBuildInputs = [ pkgs.makeWrapper ];

            installPhase = ''
              runHook preInstall
              install -Dm755 run.py $out/share/buranbrew/run.py
              install -Dm644 config.yaml $out/share/buranbrew/config.yaml
              # Extra args (e.g. a config path) pass through to run.py;
              # with no args run.py falls back to the packaged config.yaml.
              makeWrapper ${pythonEnv}/bin/python3 $out/bin/buranbrew-model \
                --add-flags $out/share/buranbrew/run.py \
                --prefix PATH : ${chip-tool}/bin
              runHook postInstall
            '';

            meta.description = "BuranBrew fermentation control model";
          };

          # ------------------------------------------------------------------
          # Telemetry stack:
          # Redis -> Go consumer -> TimescaleDB -> Grafana
          # Orchestration done by process-compose
          # ------------------------------------------------------------------

          # Postgres with the timescaledb extension loaded
          postgresqlTs = pkgs.postgresql_16.withPackages (p: [ p.timescaledb ]);

          # The Go consumer. Dependencies are fetched at build time and pinned by
          # vendorHash (no vendor dir in the repo).
          buranbrew-consumer = pkgs.buildGoModule {
            pname = "buranbrew-consumer";
            version = "1.0.0";
            src = ./telemetry/consumer;
            # Deps are fetched at build time and pinned by this hash
            # If deps change: set to pkgs.lib.fakeHash, run
            # `nix build .#buranbrew-consumer`, and paste the printed got: <hash>.
            vendorHash = "sha256-sHf6Eg2MCX6DjyeHdEf/vRWB5lvpM+neNRU9tce3vQM=";
            postInstall = ''
              mv $out/bin/consumer $out/bin/buranbrew-consumer
            '';
            meta.description = "Drain Redis telemetry streams into TimescaleDB";
          };

          telemetrySrc = ./telemetry;

          telemetry-stack = pkgs.writeShellApplication {
            name = "telemetry-stack";
            runtimeInputs = [
              pkgs.redis            # redis server
              postgresqlTs          # postgres/initdb/psql/pg_isready
              pkgs.grafana          # dashboard
              pkgs.process-compose  # orchestration
              buranbrew-consumer    # Go consumer
              pkgs.gawk             # simulate.sh
            ];
            text = ''
              export TELEMETRY_SRC=${telemetrySrc}
              export GRAFANA_HOME=${pkgs.grafana}/share/grafana
              export TELEMETRY_DATA="''${TELEMETRY_DATA:-$HOME/buranbrew/telemetry}"
              export BURANBREW_HOST_ENV="''${BURANBREW_HOST_ENV:-$PWD/host.env}"
              # shellcheck disable=SC1091
              . "$TELEMETRY_SRC/scripts/env.sh"
              mkdir -p "$TELEMETRY_DATA"
              echo "telemetry data dir: $TELEMETRY_DATA   (grafana on :$GRAFANA_PORT, pg on :$POSTGRES_PORT, redis on :$REDIS_PORT)"
              exec process-compose -f "$TELEMETRY_SRC/process-compose.yaml" "$@"
            '';
          };
          # ------------------------------------------------------------------
          # Telemetry simulator
          #
          # Runs the telemetry simulation script for testing Redis ingestion,
          # TimescaleDB storage, alert rules, and Grafana dashboards without
          # requiring real brewery hardware.
          # ------------------------------------------------------------------
          telemetry-simulate = pkgs.writeShellApplication {
            name = "telemetry-simulate";
            runtimeInputs = [ pkgs.redis pkgs.gawk postgresqlTs ];
            text = ''
              export TELEMETRY_SRC=${telemetrySrc}
              export BURANBREW_HOST_ENV="''${BURANBREW_HOST_ENV:-$PWD/host.env}"
              # shellcheck disable=SC1091
              . "$TELEMETRY_SRC/scripts/env.sh"
              exec bash ${telemetrySrc}/scripts/simulate.sh "$@"
            '';
          };
        in
        {
          packages = {
            inherit
              chip-tool
              buranbrew-model
              buranbrew-consumer
              telemetry-stack
              telemetry-simulate
              ;
            default = buranbrew-model;
          };

          devShell =
            let
              shellPkgs = [
                pythonEnv
                chip-tool
                pkgs.shellcheck

                # telemetry stack
                pkgs.go
                pkgs.redis
                postgresqlTs
                pkgs.grafana
                pkgs.process-compose
              ];
            in
            pkgs.mkShell {
              packages = shellPkgs;
              shellHook = ''
                export PS1="(buranbrew) $PS1"
                echo "chip-tool ${ncsTag} (pinned) on PATH"
                tools="${pkgs.lib.concatStringsSep " " shellPkgs}"
                echo "dev shell tools:"
                for p in $tools; do
                  echo "  - $(basename "$p" | sed -E 's/^[a-z0-9]{32}-//')"
                done
                echo -e "\e[1;33mWelcome to nix shell\e[0m"
              '';
            };
        };
    in
    {
      packages = forAll (s: (perSystem s).packages);
      devShells = forAll (s: { default = (perSystem s).devShell; });

      apps = forAll (s: {
        default = {
          type = "app";
          program = "${(perSystem s).packages.buranbrew-model}/bin/buranbrew-model";
        };
        chip-tool = {
          type = "app";
          program = "${(perSystem s).packages.chip-tool}/bin/chip-tool";
        };
        cellarman = {
          type = "app";
          program = "${(perSystem s).packages.telemetry-stack}/bin/telemetry-stack";
        };
        cellarman-simulate = {
          type = "app";
          program = "${(perSystem s).packages.telemetry-simulate}/bin/telemetry-simulate";
        };
      });
    };
}
