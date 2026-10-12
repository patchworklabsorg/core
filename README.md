# core

NixOS configuration for the Patchwork Labs Core VM (`pw-01-core`).

Patchwork services that run on other hosts, and their modules and secrets, live in [`patchworklabsorg/infra`](https://github.com/patchworklabsorg/infra). That README shows how the repos connect.

## Layout

| Path | Contents |
|---|---|
| `flake.nix` | Flake outputs. |
| `hosts/pw-01-core/` | The `pw-01-core` VM. |

## Commands

```bash
nix flake check
nix fmt
nixos-rebuild switch --flake .#pw-01-core --target-host root@pw-01-core
```

## Access

All accounts use SSH keys only. Password login is off. Members of `wheel` use `sudo` without a password.
