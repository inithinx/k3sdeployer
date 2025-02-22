{ pkgs, terranix, lib, numVMs, vmShape, region, hostnamePrefix, blockDeviceSize }:
{
  variable = {
    aws_access_key = {};
    aws_secret_key = {};
  };

  provider.aws = {
    region = region;
    access_key = "var.aws_access_key";
    secret_key = "var.aws_secret_key";
  };

  resource.aws_vpc.main = {
    cidr_block = "10.0.0.0/16";
  };

  resource.aws_internet_gateway.main = {
    vpc_id = "\${resource.aws_vpc.main.id}";
  };

  resource.aws_subnet.main = {
    vpc_id = "\${resource.aws_vpc.main.id}";
    cidr_block = "10.0.1.0/24";
    availability_zone = "${region}a";
  };

  resource.aws_security_group.main = {
    vpc_id = "\${resource.aws_vpc.main.id}";
    ingress = [
      { from_port = 41641; to_port = 41641; protocol = "udp"; cidr_blocks = ["0.0.0.0/0"]; description = "Tailscale"; }
      { from_port = 80; to_port = 80; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTP"; }
      { from_port = 443; to_port = 443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "HTTPS"; }
      { from_port = 53; to_port = 53; protocol = "udp"; cidr_blocks = ["0.0.0.0/0"]; description = "DNS"; }
      { from_port = 53; to_port = 53; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "DNS"; }
      { from_port = 6443; to_port = 6443; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "Kubernetes API"; }
      { from_port = 10250; to_port = 10250; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "Kubelet"; }
      { from_port = 2379; to_port = 2380; protocol = "tcp"; cidr_blocks = ["0.0.0.0/0"]; description = "etcd"; }
    ];
    egress = [
      { from_port = 0; to_port = 0; protocol = "-1"; cidr_blocks = ["0.0.0.0/0"]; }
    ];
  };

  resource.aws_instance.vm = lib.listToAttrs (lib.imap1 (i: _: {
    name = "vm${toString i}";
    value = {
      ami = "ami-0c55b159cbfafe1f0"; # Replace with an Alpine AMI for your region
      instance_type = vmShape;
      subnet_id = "\${resource.aws_subnet.main.id}";
      vpc_security_group_ids = ["\${resource.aws_security_group.main.id}"];
      associate_public_ip_address = true;
      user_data = ''
        #!/bin/sh
        mkfs.ext4 /dev/sdb
        mkdir -p /var/lib/longhorn
        mount /dev/sdb /var/lib/longhorn
      '';
      tags = { Name = "${hostnamePrefix}${toString i}"; };
    };
  }) (lib.range 1 numVMs));

  resource.aws_ebs_volume.data = lib.listToAttrs (lib.imap1 (i: _: {
    name = "data${toString i}";
    value = {
      availability_zone = "\${resource.aws_instance.vm${toString i}.availability_zone}";
      size = blockDeviceSize; # Use the provided size
    };
  }) (lib.range 1 numVMs));

  resource.aws_volume_attachment.data = lib.listToAttrs (lib.imap1 (i: _: {
    name = "data${toString i}";
    value = {
      device_name = "/dev/sdb";
      volume_id = "\${resource.aws_ebs_volume.data${toString i}.id}";
      instance_id = "\${resource.aws_instance.vm${toString i}.id}";
    };
  }) (lib.range 1 numVMs));

  output.vm_ips = {
    value = lib.mapAttrsToList (n: v: "\${${v.id}.public_ip}") (lib.filterAttrs (n: _: lib.hasPrefix "vm" n) (lib.getAttrs (lib.genList (i: "vm${toString (i + 1)}") numVMs) resource.aws_instance));
  };
}
