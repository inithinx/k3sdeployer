{
  description = "A NixOS flake to deploy k3s clusters on AWS, Azure, and DigitalOcean using Terranix";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";
    terranix.url = "github:terranix/terranix";
    flake-utils.url = "github:numtide/flake-utils";
    deploy-rs.url = "github:serokell/deploy-rs";
  };

  outputs = { self, nixpkgs, terranix, flake-utils, deploy-rs }:
    flake-utils.lib.eachDefaultSystem (system: let
      pkgs = nixpkgs.legacyPackages.${system};
      lib = nixpkgs.lib;

      mkDeployment = config: let
        inherit (config) cloudProvider numVMs vmShape region credentials hostnamePrefix blockDeviceSize tailscaleAuthKey tailscaleDomain k3sToken helmRepoUrl helmCharts sshPublicKey;

        terranixConfig = if cloudProvider == "aws" then
          import ./aws.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else if cloudProvider == "azure" then
          import ./azure.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else if cloudProvider == "digitalocean" then
          import ./digitalocean.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else
          throw "Unsupported cloud provider: ${cloudProvider}";

        terranixConfiguration = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ terranixConfig ];
        };

        nixosConfigs = lib.listToAttrs (lib.imap1 (i: _: {
          name = "${hostnamePrefix}${toString i}";
          value = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./configuration.nix
              { 
                networking.hostName = "${hostnamePrefix}${toString i}";
                nixpkgs.config.allowUnfree = true;  # Allow unfree packages
                users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ]; 
              }
              { 
                _module.args = { 
                  inherit numVMs tailscaleAuthKey tailscaleDomain k3sToken helmRepoUrl helmCharts;
                  vmIndex = i; 
                }; 
              }
            ];
          };
        }) (lib.range 1 numVMs));

      in {
        inherit terranixConfiguration;

        apps = {
          provision = {
            type = "app";
            program = let
              terranixConfigFile = terranixConfiguration;
            in "${pkgs.writeScript "provision-${cloudProvider}" ''
              #!/bin/sh
              set -e
              mkdir -p tf
              cp ${terranixConfigFile} tf/config.tf.json
              cd tf
              ${pkgs.terraform}/bin/terraform init
              ${pkgs.terraform}/bin/terraform apply -auto-approve \
                ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "-var '${n}=${v}'") credentials.${cloudProvider})}
              
              VM_IPS=$(${pkgs.terraform}/bin/terraform output -json vm_ips | ${pkgs.jq}/bin/jq -r '.[]' | tr '\n' ' ')
              
              index=1
              for ip in $VM_IPS; do
                ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
                  --flake .#${hostnamePrefix}${toString index} \
                  root@$ip
                index=$((index + 1))
              done
            ''}";
          };

          destroy = {
            type = "app";
            program = "${pkgs.writeScript "destroy-${cloudProvider}" '' ... ''}";  # Keep existing destroy script
          };

          update = {
            type = "app";
            program = "${pkgs.writeScript "update-${cloudProvider}" '' ... ''}";  # Keep existing update script
          };
        };

        deploy.nodes = lib.mapAttrs (name: cfg: {
          hostname = name;
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos cfg;
          };
        }) nixosConfigs;

        nixosConfigurations = nixosConfigs;
      };
    in {
      lib = { inherit mkDeployment; };
    });
}
