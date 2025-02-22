{ config, lib, pkgs, vmIndex, numVMs, tailscaleAuthKey, tailscaleDomain, k3sToken, helmRepoUrl, helmCharts, ... }:

{
  # Bootloader and filesystem configuration
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

  # Networking and firewall
  networking = {
    interfaces.eth0.useDHCP = true;
    defaultGateway = {
      address = "10.0.0.1";
      interface = "eth0";
    };
    firewall = {
      enable = true;
      allowedTCPPorts = [ 22 6443 10250 2379 2380 80 443 41641 ];
      allowedUDPPorts = [ 41641 ];
    };
  };

  # Tailscale configuration
  services.tailscale = {
    enable = true;
    extraUpFlags = [ "--advertise-tags=${tailscaleDomain}" ];
  };

  systemd.services.tailscale-auth = {
    description = "Tailscale authentication";
    after = [ "tailscale.service" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "oneshot";
      RemainAfterExit = true;
      ExecStart = "${pkgs.bash}/bin/bash -c 'if ! ${pkgs.tailscale}/bin/tailscale status; then ${pkgs.tailscale}/bin/tailscale up --authkey=${tailscaleAuthKey}; fi'";
    };
  };

  # k3s configuration
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

  # Deploy Helm charts on the first VM
  services.k3s.manifests = if vmIndex == 1 then {
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
  } else {};

  # Fix PATH for k3s
  systemd.services.k3s.environment.PATH = lib.mkForce "/run/current-system/sw/bin:/usr/bin:/bin";

  # Longhorn fix
  systemd.tmpfiles.rules = [
    "L+ /usr/local/bin - - - - /run/current-system/sw/bin/"
  ];

  # Boot parameters
  boot.kernelParams = [
    "console=ttyS0"
    "panic=1"
    "boot.panic_on_fail"
    "net.ifnames=0"
  ];

  # SSH configuration
  services.openssh.enable = true;

  # System version
  system.stateVersion = "24.11";
}
