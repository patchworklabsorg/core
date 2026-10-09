# modules/weave/default.nix
# Weave — Patchwork Labs identity provider (Rails app) + Postgres + Redis as
# Docker containers on a dedicated network. Exported by this flake as
# nixosModules.weave; the host that runs it imports nixosModules.weave-alastor
# (hosts/alastor/weave.nix), which sets the instance options below.
#
# Traefik routing (`traefik.*` options) is a fragment in
# /etc/traefik/conf.d/weave.toml. The host's Traefik must use the file
# provider on that directory and define the cert resolver and middlewares the
# routers name. jaspermayone/infra's modules/traefik does both. The `idp`
# router points idp.patchworklabs.org, weave.patchworklabs.org and
# slack.patchworklabs.org at 127.0.0.1:3003.
#
# CI deploys happen without nixos-rebuild:
#   1. CI builds and pushes a new image to ghcr.io/patchworklabsorg/weave
#   2. CI writes the new image ref to /var/lib/weave/image-ref
#   3. CI SSHes as weave-deploy and runs:
#        sudo systemctl restart weave-web
#   The web service auto-runs `bin/rails db:prepare` on start (creates +
#   migrates the primary and queue databases, idempotent). weave-worker is
#   `partOf` weave-web, so that one restart carries the worker onto the same
#   image — see the comment on the worker unit for why it has to.
#
# Env file (weave-env.age) must contain:
#   RAILS_MASTER_KEY=...   # decrypts config/credentials (Resend + Slack + more)
#   POSTGRES_PASSWORD=...  # used by both the Rails app and the postgres init
#
# Staging (optional, `staging.enable`) is a second, fully separate instance
# rendered by the same `mkInstance` function below: units weave-staging-*,
# Docker network `weave-staging`, its own Postgres + Redis containers, state in
# /var/lib/weave-staging, image ref in /var/lib/weave-staging/image-ref, Docker
# volume weave_staging_storage, and its own env file (weave-staging-env.age,
# same two keys, but RAILS_MASTER_KEY is the staging credentials key). With an
# empty `extraEnv`, the production instance renders byte-identical units to the
# pre-refactor module; keep it that way when editing `mkInstance` (an empty
# `extraEnv` must add no characters). CI deploys staging the same way: write
# /var/lib/weave-staging/image-ref, then `sudo systemctl restart weave-staging-web`.
{
  config,
  lib,
  pkgs,
  ...
}:
let
  dockerBin = "${config.virtualisation.docker.package}/bin/docker";
  cfg = config.patchwork.services.weave;

  # Renders `--env 'KEY=value' \` continuation lines for an instance's
  # extraEnv. Each line ends with the two-space indent the following docker
  # argument expects. An empty attrset renders "", which is what keeps the
  # production units identical.
  envArgs =
    env:
    lib.concatStrings (lib.mapAttrsToList (k: v: "--env ${lib.escapeShellArg "${k}=${v}"} \\\n  ") env);

  # Every unit, container, network, state path and script name of one Weave
  # instance is derived from `name`. Production is name = "weave".
  #   name             unit/container/network prefix and /var/lib/<name>
  #   label            human prefix for unit descriptions ("Weave")
  #   port             loopback host port for the web container
  #   image            fallback image when <stateDir>/image-ref is empty
  #   environmentFile  agenix env file (RAILS_MASTER_KEY, POSTGRES_PASSWORD)
  #   storageVolume    Docker named volume mounted at /rails/storage
  #   extraEnv         extra container env for db:prepare, web and worker
  mkInstance =
    {
      name,
      label,
      port,
      image,
      environmentFile,
      storageVolume,
      extraEnv ? { },
    }:
    let
      network = name;
      stateDir = "/var/lib/${name}";
      extraEnvArgs = envArgs extraEnv;
    in
    {
      # ── Docker network ────────────────────────────────────────────────────────
      systemd.services."${name}-network" = {
        description = "Create ${name} Docker network";
        after = [ "docker.service" ];
        requires = [ "docker.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          StateDirectory = "${name} ${name}/db ${name}/redis";
          StateDirectoryMode = "0755";
          ExecStart = pkgs.writeShellScript "${name}-network-create" ''
            ${dockerBin} network inspect ${network} >/dev/null 2>&1 || \
              ${dockerBin} network create ${network}
          '';
        };
      };

      # ── Redis ─────────────────────────────────────────────────────────────────
      systemd.services."${name}-redis" = {
        description = "${label} Redis";
        after = [
          "docker.service"
          "${name}-network.service"
        ];
        requires = [
          "docker.service"
          "${name}-network.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = [
            "-${dockerBin} stop ${name}-redis"
            "-${dockerBin} rm ${name}-redis"
            "${dockerBin} pull redis:7-alpine"
          ];
          ExecStart = ''
            ${dockerBin} run \
              --name ${name}-redis \
              --network ${network} \
              --volume ${stateDir}/redis:/data \
              --restart no \
              redis:7-alpine redis-server --save 60 1 --loglevel warning
          '';
          ExecStop = "${dockerBin} stop ${name}-redis";
          Restart = "on-failure";
          RestartSec = "5s";
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "${name}-redis";
        };
      };

      # ── PostgreSQL (pgvector) ─────────────────────────────────────────────────
      systemd.services."${name}-db" = {
        description = "${label} PostgreSQL";
        after = [
          "docker.service"
          "${name}-network.service"
        ];
        requires = [
          "docker.service"
          "${name}-network.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";
          ExecStartPre = [
            "-${dockerBin} stop ${name}-db"
            "-${dockerBin} rm ${name}-db"
            "${dockerBin} pull pgvector/pgvector:pg17"
          ];
          ExecStart = ''
            ${dockerBin} run \
              --name ${name}-db \
              --network ${network} \
              --env-file ${environmentFile} \
              --env POSTGRES_USER=weave \
              --env POSTGRES_DB=weave_production \
              --volume ${stateDir}/db:/var/lib/postgresql/data \
              --restart no \
              pgvector/pgvector:pg17
          '';
          ExecStop = "${dockerBin} stop ${name}-db";
          Restart = "on-failure";
          RestartSec = "10s";
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "${name}-db";
        };
      };

      # ── Web (Rails) ───────────────────────────────────────────────────────────
      systemd.services."${name}-web" = {
        description = "${label} web";
        after = [
          "docker.service"
          "${name}-network.service"
          "${name}-db.service"
          "${name}-redis.service"
        ];
        requires = [
          "docker.service"
          "${name}-network.service"
          "${name}-db.service"
          "${name}-redis.service"
        ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";

          ExecStartPre = [
            # Resolve the image: file written by CI takes precedence over Nix default.
            (pkgs.writeShellScript "${name}-resolve-image" ''
              IMAGE_FILE="${stateDir}/image-ref"
              IMAGE="${image}"
              if [ -f "$IMAGE_FILE" ] && [ -s "$IMAGE_FILE" ]; then
                IMAGE=$(cat "$IMAGE_FILE")
              else
                echo "$IMAGE" > "$IMAGE_FILE"
              fi
              echo "$IMAGE" > /run/${name}-image
            '')

            # Optionally log in to ghcr.io before pulling.
            (pkgs.writeShellScript "${name}-registry-login" ''
              ${lib.optionalString (cfg.registryCredentialsFile != null) ''
                ${dockerBin} login ghcr.io \
                  --username patchworklabsorg \
                  --password-stdin < ${cfg.registryCredentialsFile}
              ''}
              IMAGE=$(cat /run/${name}-image)
              ${dockerBin} pull "$IMAGE"
            '')

            "-${dockerBin} stop ${name}-web"
            "-${dockerBin} rm ${name}-web"

            # Wait for postgres, then run db:prepare (create + migrate, idempotent).
            (pkgs.writeShellScript "${name}-db-prepare" ''
              set -e
              IMAGE=$(cat /run/${name}-image)
              echo "Waiting for postgres..."
              until ${dockerBin} exec ${name}-db \
                  pg_isready -U weave -h localhost -q; do
                sleep 2
              done
              echo "Running db:prepare..."
              ${dockerBin} run --rm \
                --network ${network} \
                --env-file ${environmentFile} \
                --env RAILS_ENV=production \
                --env DB_HOST=${name}-db \
                --env DB_PORT=5432 \
                --env POSTGRES_DB=weave_production \
                --env POSTGRES_USER=weave \
                ${extraEnvArgs}"$IMAGE" \
                bin/rails db:prepare
            '')
          ];

          ExecStart = pkgs.writeShellScript "${name}-web-start" ''
            IMAGE=$(cat /run/${name}-image)
            exec ${dockerBin} run \
              --name ${name}-web \
              --network ${network} \
              --publish 127.0.0.1:${toString port}:3000 \
              --env-file ${environmentFile} \
              --env RAILS_ENV=production \
              --env DB_HOST=${name}-db \
              --env DB_PORT=5432 \
              --env POSTGRES_DB=weave_production \
              --env POSTGRES_USER=weave \
              --env REDIS_URL=redis://${name}-redis:6379/0 \
              --env REDIS_CACHE_URL=redis://${name}-redis:6379/1 \
              --env SOLID_QUEUE_IN_PUMA=true \
              --env RAILS_SERVE_STATIC_FILES=true \
              --env RAILS_LOG_TO_STDOUT=true \
              ${extraEnvArgs}--volume ${storageVolume}:/rails/storage \
              --restart no \
              "$IMAGE"
          '';

          ExecStop = "${dockerBin} stop ${name}-web";
          Restart = "on-failure";
          RestartSec = "10s";
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "${name}-web";
        };
      };

      # ── Worker (Solid Queue) ──────────────────────────────────────────────────
      # Dedicated Active Job / Solid Queue supervisor (`bin/jobs`). Runs the same
      # image as the web service. Required for background jobs — mailers deliver
      # via jobs (magic links, welcome + confirmation emails), so without this
      # process no email is ever sent. db:prepare (creating/migrating the queue
      # database) is handled by weave-web's ExecStartPre; the worker is ordered
      # after it so the queue tables exist before it starts.
      systemd.services."${name}-worker" = {
        description = "${label} Solid Queue worker";
        after = [
          "docker.service"
          "${name}-network.service"
          "${name}-db.service"
          "${name}-redis.service"
          "${name}-web.service"
        ];
        requires = [
          "docker.service"
          "${name}-network.service"
          "${name}-db.service"
          "${name}-redis.service"
        ];
        # Restarting weave-web restarts the worker too, and `after` above puts it
        # second, so db:prepare has already run by then.
        #
        # Without this the two drift apart: CI's deploy step is a single
        # `systemctl restart weave-web`, and because the worker resolves
        # image-ref in its own ExecStartPre it goes on serving whatever image it
        # last started with. On 2026-07-27 that had the worker running job code
        # from d3a4717 against a schema 9df16dd had already migrated. Coupling
        # the units here rather than adding a second restart to CI means the
        # invariant cannot be forgotten, and needs no further sudoers grant for
        # weave-deploy.
        partOf = [ "${name}-web.service" ];
        wantedBy = [ "multi-user.target" ];
        serviceConfig = {
          Type = "simple";

          ExecStartPre = [
            # Resolve the image independently of weave-web (its own /run file),
            # so the worker doesn't race the web service's image resolution.
            (pkgs.writeShellScript "${name}-worker-resolve-image" ''
              IMAGE_FILE="${stateDir}/image-ref"
              IMAGE="${image}"
              if [ -f "$IMAGE_FILE" ] && [ -s "$IMAGE_FILE" ]; then
                IMAGE=$(cat "$IMAGE_FILE")
              fi
              echo "$IMAGE" > /run/${name}-worker-image
            '')

            (pkgs.writeShellScript "${name}-worker-pull" ''
              ${lib.optionalString (cfg.registryCredentialsFile != null) ''
                ${dockerBin} login ghcr.io \
                  --username patchworklabsorg \
                  --password-stdin < ${cfg.registryCredentialsFile}
              ''}
              IMAGE=$(cat /run/${name}-worker-image)
              ${dockerBin} pull "$IMAGE"
            '')

            "-${dockerBin} stop ${name}-worker"
            "-${dockerBin} rm ${name}-worker"
          ];

          ExecStart = pkgs.writeShellScript "${name}-worker-start" ''
            IMAGE=$(cat /run/${name}-worker-image)
            exec ${dockerBin} run \
              --name ${name}-worker \
              --network ${network} \
              --env-file ${environmentFile} \
              --env RAILS_ENV=production \
              --env DB_HOST=${name}-db \
              --env DB_PORT=5432 \
              --env POSTGRES_DB=weave_production \
              --env POSTGRES_USER=weave \
              --env REDIS_URL=redis://${name}-redis:6379/0 \
              --env REDIS_CACHE_URL=redis://${name}-redis:6379/1 \
              --env RAILS_LOG_TO_STDOUT=true \
              ${extraEnvArgs}--volume ${storageVolume}:/rails/storage \
              --restart no \
              "$IMAGE" \
              ./bin/jobs
          '';

          ExecStop = "${dockerBin} stop ${name}-worker";
          Restart = "on-failure";
          RestartSec = "10s";
          StandardOutput = "journal";
          StandardError = "journal";
          SyslogIdentifier = "${name}-worker";
        };
      };
    };
in
{
  options.patchwork.services.weave = {
    enable = lib.mkEnableOption "Weave identity provider";

    port = lib.mkOption {
      type = lib.types.port;
      default = 3003;
      description = "Host port the web container binds to (loopback only; Traefik proxies to it).";
    };

    image = lib.mkOption {
      type = lib.types.str;
      default = "ghcr.io/patchworklabsorg/weave:main";
      description = ''
        Default Docker image for the web container. CI overrides this at deploy
        time by writing a new ref to /var/lib/weave/image-ref and running:
        sudo systemctl restart weave-web. The service reads that file first;
        this value is the fallback.
      '';
    };

    environmentFile = lib.mkOption {
      type = lib.types.path;
      description = ''
        Path to an env file (an agenix secret) containing:
          RAILS_MASTER_KEY=...
          POSTGRES_PASSWORD=...
      '';
    };

    registryCredentialsFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = ''
        Optional path to a file containing a GitHub PAT with packages:read,
        used to authenticate docker pull from ghcr.io. Not needed if the
        package is public.
      '';
    };

    extraEnv = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = { };
      example = {
        MAIL_DOMAIN = "weave.patchworklabs.org";
      };
      description = ''
        Extra container env for the production db:prepare, web and worker
        containers.
      '';
    };

    deployAuthorizedKeys = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = ''
        SSH public keys for the weave-deploy CI user. That user may only:
        sudo systemctl restart weave-web
      '';
    };

    traefik = {
      enable = lib.mkEnableOption ''
        a Traefik file-provider fragment (/etc/traefik/conf.d/weave.toml) that
        routes `hosts` to production and `staging.hosts` to staging
      '';

      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "idp.patchworklabs.org" ];
        description = "Hostnames routed to the production web container (router `idp`).";
      };

      certResolver = lib.mkOption {
        type = lib.types.str;
        default = "cloudflare";
        description = "Name of a cert resolver defined in the host's Traefik static config.";
      };

      middlewares = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ "hsts" ];
        description = "Middlewares, by name, defined elsewhere in the same file provider.";
      };
    };

    staging = {
      enable = lib.mkEnableOption ''
        a Weave staging instance (weave-staging-* units, own Postgres, Redis,
        network, state dir and storage volume) alongside production
      '';

      hosts = lib.mkOption {
        type = lib.types.listOf lib.types.str;
        default = [ ];
        example = [ "weave-staging.patchworklabs.org" ];
        description = ''
          Hostnames routed to the staging web container (router
          `weave-staging`). Used only when `traefik.enable` is set.
        '';
      };

      port = lib.mkOption {
        type = lib.types.port;
        default = 3004;
        description = "Host port the staging web container binds to (loopback only).";
      };

      image = lib.mkOption {
        type = lib.types.str;
        default = "ghcr.io/patchworklabsorg/weave:staging";
        description = ''
          Fallback Docker image for staging. CI overrides it by writing
          /var/lib/weave-staging/image-ref and running:
          sudo systemctl restart weave-staging-web.
        '';
      };

      environmentFile = lib.mkOption {
        type = lib.types.path;
        description = ''
          Path to the staging env file (an agenix secret) containing:
            RAILS_MASTER_KEY=...   (the staging credentials key)
            POSTGRES_PASSWORD=...
        '';
      };

      extraEnv = lib.mkOption {
        type = lib.types.attrsOf lib.types.str;
        default = { };
        example = {
          APP_HOST = "weave-staging.patchworklabs.org";
          MAIL_DOMAIN = "sandbox.patchworklabs.org";
        };
        description = ''
          Extra container env for the staging db:prepare, web and worker
          containers. WEAVE_ENV=staging is always set.
        '';
      };
    };
  };

  config = lib.mkIf cfg.enable (
    lib.mkMerge [
      {

        # ── CI deploy user ────────────────────────────────────────────────────────
        users.users.weave-deploy = lib.mkIf (cfg.deployAuthorizedKeys != [ ]) {
          isNormalUser = true;
          group = "users";
          shell = pkgs.bash;
          openssh.authorizedKeys.keys = cfg.deployAuthorizedKeys;
        };

        security.sudo.extraRules = lib.mkIf (cfg.deployAuthorizedKeys != [ ]) [
          {
            users = [ "weave-deploy" ];
            commands = [
              {
                command = "/run/current-system/sw/bin/systemctl restart weave-web";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl restart weave-worker";
                options = [ "NOPASSWD" ];
              }
            ]
            ++ lib.optionals cfg.staging.enable [
              {
                command = "/run/current-system/sw/bin/systemctl restart weave-staging-web";
                options = [ "NOPASSWD" ];
              }
              {
                command = "/run/current-system/sw/bin/systemctl restart weave-staging-worker";
                options = [ "NOPASSWD" ];
              }
            ];
          }
        ];

        # ── State files ───────────────────────────────────────────────────────────
        # image-ref is written by the CI deploy user, so it must be owned by them.
        systemd.tmpfiles.rules = lib.mkIf (cfg.deployAuthorizedKeys != [ ]) (
          [
            "f /var/lib/weave/image-ref 0644 weave-deploy users -"
            "z /var/lib/weave/image-ref 0644 weave-deploy users -"
          ]
          # The staging state dir may not exist yet when tmpfiles first runs
          # (weave-staging-network's StateDirectory creates it later), so create it
          # here; otherwise the root-owned image-ref written by the web unit would
          # block CI until the next activation.
          ++ lib.optionals cfg.staging.enable [
            "d /var/lib/weave-staging 0755 root root -"
            "f /var/lib/weave-staging/image-ref 0644 weave-deploy users -"
            "z /var/lib/weave-staging/image-ref 0644 weave-deploy users -"
          ]
        );
      }

      # ── Traefik ───────────────────────────────────────────────────────────────
      # Router and service names (`idp`, `weave-staging`) are the ones alastor
      # used before this module moved here. Keep them.
      (lib.mkIf cfg.traefik.enable {
        environment.etc."traefik/conf.d/weave.toml".source =
          let
            router = hosts: service: {
              rule = lib.concatMapStringsSep " || " (h: "Host(`${h}`)") hosts;
              entryPoints = [ "websecure" ];
              tls.certResolver = cfg.traefik.certResolver;
              inherit (cfg.traefik) middlewares;
              inherit service;
            };
            backend = port: {
              loadBalancer.servers = [ { url = "http://127.0.0.1:${toString port}"; } ];
            };
            withStaging = cfg.staging.enable && cfg.staging.hosts != [ ];
          in
          (pkgs.formats.toml { }).generate "weave.toml" {
            http = {
              routers = {
                idp = router cfg.traefik.hosts "idp";
              }
              // lib.optionalAttrs withStaging {
                weave-staging = router cfg.staging.hosts "weave-staging";
              };
              services = {
                idp = backend cfg.port;
              }
              // lib.optionalAttrs withStaging {
                weave-staging = backend cfg.staging.port;
              };
            };
          };
      })

      # ── Production ────────────────────────────────────────────────────────────
      (mkInstance {
        name = "weave";
        label = "Weave";
        inherit (cfg)
          port
          image
          environmentFile
          extraEnv
          ;
        storageVolume = "weave_storage";
      })

      # ── Staging ───────────────────────────────────────────────────────────────
      (lib.mkIf cfg.staging.enable (mkInstance {
        name = "weave-staging";
        label = "Weave staging";
        inherit (cfg.staging) port image environmentFile;
        storageVolume = "weave_staging_storage";
        extraEnv = {
          WEAVE_ENV = "staging";
        }
        // cfg.staging.extraEnv;
      }))
    ]
  );
}
