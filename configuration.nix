{ config, lib, pkgs, vmIndex, numVMs, tailscaleAuthKey, tailscaleDomain, k3sToken, helmRepoUrl, helmCharts, ... }:

{
  # Allow unfree packages system-wide
  nixpkgs.config.allowUnfree = true;

  boot.loader.grub.enable = true;
  boot.loader.grub.device = "/dev/sda";

  fileSystems."/" = {
    device = "/dev/sda1";
    fsType = "ext4";
  };

  fileSystems."/var/lib/longhorn" = {
    device = "/dev/sdb";
    fsType = "ext4";
  };

  networking = {
    hostName = config.networking.hostName;  # Set from flake.nix
    interfaces.eth0.useDHCP = true;
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 6443 10250 2379 2380 80 443 41641 ];
      allowedUDPPorts = [ 41641 ];
    };
  };

  services.tailscale.enable = true;
  systemd.services.tailscale-auth = {
    # ... existing tailscale config ...
  };

  services.k3s = {
    enable = true;
    role = "server";
    token = k3sToken;
    extraFlags = [
      "--write-kubeconfig-mode=0644"
      "--disable=local-storage"
      "--vpn-auth=name=tailscale,joinKey=${tailscaleAuthKey}"
    ] ++ (if vmIndex == 1 then ["--cluster-init"] else ["--server=https://${config.networking.hostName}1.${tailscaleDomain}:6443"]);
  };

  services.k3s.manifests = lib.optionalAttrs (vmIndex == 1) {
    helmCharts = lib.listToAttrs (map (chart: {
      name = chart;
      value = {
        enable = true;
        content = {
          apiVersion = "helm.cattle.io/v1";
          kind = "HelmChart";
          metadata = { name = chart; };
          spec = {
            chart = chart;
            repo = helmRepoUrl;
          };
        };
      };
    }) helmCharts);
  };

  # ... rest of the existing configuration ...
  system.stateVersion = "24.11";
}
