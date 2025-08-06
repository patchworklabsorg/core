# Edit this configuration file to define what should be installed on
# your system. Help is available in the configuration.nix(5) man page, on
# https://search.nixos.org/options and in the NixOS manual (`nixos-help`).

{ config, lib, pkgs, ... }:

{
  imports =
    [ # Include the results of the hardware scan.
      ./hardware-configuration.nix
    ];

  # Bootloader
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  # Set hostname
  networking.hostName = "nixos-vm";

  # Set your time zone
  time.timeZone = "America/New_York";

  # Select internationalisation properties
  i18n.defaultLocale = "en_US.UTF-8";

users.groups.admins = {};

  # User configuration
  users.mutableUsers = false;
  users.users = {
    jsp = {
      isNormalUser = true;
      shell = pkgs.zsh;
      extraGroups = [ "wheel" "docker" ];
      openssh.authorizedKeys.keys = [
        "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDxnv44DTFIO2cIiy4blF/UjJxDY+j8AJo9Wwq25inA2 jasper@jaspermayone.com"
      ];
      hashedPassword = "$6$kBN.jtU2kKeD8ORm$F/2Anag4NrcG3rboaCUxE9GqxX2AI3V3BcCfK8xg.WHhjOhFup1ZfAJP8tJj9e4hFIcYhDuMw0qz2WHVaoEY6.";
    };
    krn = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
    };
    yc = {
      isNormalUser = true;
      extraGroups = [ "wheel" "docker" ];
    };
    dom = {
      isNormalUser = true;
      extraGroups = [ "docker" ];
    };
  };

# Create directory with correct ownership and permissions
systemd.tmpfiles.rules = [ "d /opt/dots 0775 root admins - -" ];

  # System packages
  environment.systemPackages = with pkgs; [
    vim
    wget
    curl
    git
    htop
    tree
    gnupg
  ];

  programs.gnupg.agent = {
    enable = true;
    enableSSHSupport = true;
  };

  # Services
  services.qemuGuest.enable = true;
  services.openssh.enable = true;
  virtualisation.docker.enable = true;

  # Programs
  programs.zsh.enable = true;

  # Firewall (you may want to open specific ports)
  networking.firewall.enable = true;
  # networking.firewall.allowedTCPPorts = [ 22 ]; # SSH is allowed by default

  # Copy the NixOS configuration file and link it from the resulting system
  system.copySystemConfiguration = true;

  # This option defines the first version of NixOS you have installed on this particular machine,
  # and is used to maintain compatibility with application data (e.g. databases) created on older NixOS versions.
  system.stateVersion = "25.05"; # Did you read the comment?
}
