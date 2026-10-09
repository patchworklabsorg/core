# agenix recipients for the secrets in this directory.
#
#   cd secrets && agenix -e <name>.age   # create or edit
#   cd secrets && agenix -r              # re-key after changing a recipient list
#
# The .age files are public in this repo. Only the listed keys can decrypt
# them. Re-keying needs a machine that holds one of the current keys.
let
  # Admins
  jsp = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHm7lo7umraewipgQu1Pifmoo/V8jYGDHjBTmt+7SOCe me@jaspermayone.com";

  # Hosts (/etc/ssh/ssh_host_ed25519_key.pub)
  alastor = "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFwkC1CiWpLB10NNVaJwu4LSyiL0wM7ExI1VoKqIsgeG root@alastor-vnic";
in
{
  # Weave (Patchwork IDP) runtime env. Must contain:
  #   RAILS_MASTER_KEY=...   (decrypts config/credentials)
  #   POSTGRES_PASSWORD=...  (Rails DB password + postgres container init)
  "weave-env.age".publicKeys = [
    jsp
    alastor
  ];

  # Weave staging (weave-staging.patchworklabs.org) runtime env. Same keys as
  # weave-env.age:
  #   RAILS_MASTER_KEY=...   (the staging credentials key, not production's)
  #   POSTGRES_PASSWORD=...  (staging Rails DB password + postgres container init)
  "weave-staging-env.age".publicKeys = [
    jsp
    alastor
  ];
}
