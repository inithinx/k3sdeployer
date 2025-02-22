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

      # Function to create a deployment
      mkDeployment = config: let
        # Extract configuration parameters
        inherit (config) cloudProvider numVMs vmShape region credentials hostnamePrefix blockDeviceSize tailscaleAuthKey tailscaleDomain k3sToken helmRepoUrl helmCharts sshPublicKey;

        # Select Terranix config based on cloud provider
        terranixConfig = if cloudProvider == "aws" then
          import ./aws.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else if cloudProvider == "azure" then
          import ./azure.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else if cloudProvider == "digitalocean" then
          import ./digitalocean.nix { inherit pkgs terranix lib numVMs vmShape region hostnamePrefix blockDeviceSize; }
        else
          throw "Unsupported cloud provider: ${cloudProvider}";

        # Define terranixConfiguration here so it's accessible throughout
        terranixConfiguration = terranix.lib.terranixConfiguration {
          inherit system;
          modules = [ terranixConfig ];
        };

        # Generate NixOS configurations per VM
        nixosConfigs = lib.listToAttrs (lib.imap1 (i: _: {
          name = "${hostnamePrefix}${toString i}";
          value = nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            modules = [
              ./configuration.nix
              { networking.hostName = "${hostnamePrefix}${toString i}"; }
              { users.users.root.openssh.authorizedKeys.keys = [ sshPublicKey ]; }
              { _module.args = { vmIndex = i; numVMs = numVMs; tailscaleAuthKey = tailscaleAuthKey; tailscaleDomain = tailscaleDomain; k3sToken = k3sToken; helmRepoUrl = helmRepoUrl; helmCharts = helmCharts; }; }
            ];
          };
        }) (lib.range 1 numVMs));

      in {
        # Expose terranixConfiguration
        inherit terranixConfiguration;

        # Nix apps for automation
        apps = {
          provision = {
            type = "app";
            program = let
              terranixConfigFile = terranixConfiguration;  # References the outer terranixConfiguration
            in "${pkgs.writeScript "provision-${cloudProvider}" ''
              #!/bin/sh
              set -e
              # Generate Terraform config
              mkdir -p tf
              cp ${terranixConfigFile} tf/config.tf.json
              cd tf
              # Initialize Terraform
              ${pkgs.terraform}/bin/terraform init
              # Apply Terraform config with credentials
              ${pkgs.terraform}/bin/terraform apply -auto-approve \
                ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "-var '${n}=${v}'") credentials.${cloudProvider})}
              # Get VM IPs from Terraform output
              VM_IPS=$(${pkgs.terraform}/bin/terraform output -json vm_ips | ${pkgs.jq}/bin/jq -r '.[]')
              # Convert VMs to NixOS
              for ip in $VM_IPS; do
                ${pkgs.nixos-anywhere}/bin/nixos-anywhere \
                  --flake .#${hostnamePrefix}${toString (lib.findFirst (i: nixosConfigs."${hostnamePrefix}${toString i}".networking.hostName == "${hostnamePrefix}${toString i}") 1 (lib.range 1 numVMs))} \
                  root@$ip
              done
            ''}";
          };

          destroy = {
            type = "app";
            program = "${pkgs.writeScript "destroy-${cloudProvider}" ''
              #!/bin/sh
              set -e
              cd tf
              ${pkgs.terraform}/bin/terraform destroy -auto-approve \
                ${lib.concatStringsSep " " (lib.mapAttrsToList (n: v: "-var '${n}=${v}'") credentials.${cloudProvider})}
              rm -rf tf
            ''}";
          };

          update = {
            type = "app";
            program = "${pkgs.writeScript "update-${cloudProvider}" ''
              #!/bin/sh
              set -e
              # Use deploy-rs to update NixOS configurations
              ${deploy-rs.packages.${system}.deploy-rs}/bin/deploy .#${cloudProvider}-deployment --targets \
                $(echo "${lib.concatStringsSep " " (lib.mapAttrsToList (n: _: "root@${n}") nixosConfigs)}")
            ''}";
          };
        };

        # Deploy-rs configuration
        deploy.nodes = lib.mapAttrs (name: cfg: {
          hostname = name; # Assumes Tailscale or DNS resolves this
          profiles.system = {
            user = "root";
            path = deploy-rs.lib.${system}.activate.nixos cfg;
          };
        }) nixosConfigs;

        # Expose NixOS configurations if needed
        nixosConfigurations = nixosConfigs;
      };
    in {
      lib = { inherit mkDeployment; };
    });
}
