# Weave on alastor. Exported as nixosModules.weave-alastor.
#
# alastor is jaspermayone's VPS and is built from jaspermayone/infra, which
# imports this module through its `patchwork-core` flake input. Everything
# Patchwork-specific about the deployment lives here: the instance settings,
# the CI deploy key, the Traefik routes and the agenix secrets.
#
# What the importing host must provide:
#   - the agenix NixOS module (`age.*` options)
#   - Docker (the module runs its containers through it)
#   - Traefik with the file provider on /etc/traefik/conf.d and a `cloudflare`
#     cert resolver and `hsts` middleware (infra's modules/traefik)
#
# To change any of this: merge here, then in infra run
#   nix flake update patchwork-core
# and deploy alastor.
{ config, ... }:
{
  imports = [ ../../modules/weave ];

  # Recipients are in ../../secrets/secrets.nix (jsp + alastor's host key).
  age.secrets = {
    weave-env = {
      file = ../../secrets/weave-env.age;
      mode = "400";
    };
    # Same two keys as weave-env, but RAILS_MASTER_KEY is the staging
    # credentials key and POSTGRES_PASSWORD is for the staging database.
    weave-staging-env = {
      file = ../../secrets/weave-staging-env.age;
      mode = "400";
    };
  };

  patchwork.services.weave = {
    enable = true;
    environmentFile = config.age.secrets.weave-env.path;
    # Sender domain verified in Resend. The weave repo's lib/weave.rb reads it.
    extraEnv.MAIL_DOMAIN = "weave.patchworklabs.org";
    # CI (weave repo, .github/workflows/deploy.yml) SSHes as weave-deploy and runs
    # `sudo systemctl restart weave-web`. Private key is the WEAVE_DEPLOY_SSH_KEY
    # repo secret.
    deployAuthorizedKeys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBlQambjmi/gstrJ6CH/ZnMbuqkp+ad5ckfkx5STdKU6 github-actions-weave-deploy"
    ];

    traefik = {
      enable = true;
      hosts = [
        "idp.patchworklabs.org"
        "weave.patchworklabs.org"
        "slack.patchworklabs.org"
      ];
    };

    # weave-staging.patchworklabs.org: weave-staging-* units on 127.0.0.1:3004.
    # Same weave-deploy user; CI restarts it with
    # `sudo systemctl restart weave-staging-web`.
    staging = {
      enable = true;
      environmentFile = config.age.secrets.weave-staging-env.path;
      hosts = [ "weave-staging.patchworklabs.org" ];
      extraEnv = {
        APP_HOST = "weave-staging.patchworklabs.org";
        # Sender domain verified in Resend; the staging Resend key only allows
        # this domain. Who receives staging mail is the weave repo's
        # `mail_allowlist` credential.
        MAIL_DOMAIN = "sandbox.patchworklabs.org";
      };
    };
  };
}
