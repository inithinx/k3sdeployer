{ pkgs, terranix, lib, numVMs, vmShape, region, hostnamePrefix, blockDeviceSize }:
{
  variable = {
    aws_access_key = {};
    aws_secret_key = {};
  };

  provider.aws = {
    region = region;
    access_key = "\${var.aws_access_key}";
    secret_key = "\${var.aws_secret_key}";
  };

  resource.aws_vpc.main = {
    cidr_block = "10.0.0.0/16";
  };

  resource.aws_internet_gateway.main = {
    vpc_id = "\${aws_vpc.main.id}";
  };

  resource.aws_subnet.main = {
    vpc_id = "\${aws_vpc.main.id}";
    cidr_block = "10.0.1.0/24";
    availability_zone = "${region}a";
  };

  resource.aws_security_group.main = {
    vpc_id = "\${aws_vpc.main.id}";

    ingress = [
      {
        description = "Tailscale";
        from_port = 41641;
        to_port = 41641;
        protocol = "udp";
        cidr_blocks = ["0.0.0.0/0"];
        ipv6_cidr_blocks = [];
        prefix_list_ids = [];
        security_groups = [];
        self = false;
      }
    ];

    egress = [
      {
        description = "Allow all outbound";
        from_port = 0;
        to_port = 0;
        protocol = "-1";
        cidr_blocks = ["0.0.0.0/0"];
        ipv6_cidr_blocks = [];
        prefix_list_ids = [];
        security_groups = [];
        self = false;
      }
    ];
  };

  resource.aws_instance = lib.genAttrs (lib.genList (i: "vm${toString (i + 1)}") numVMs) (name: {
    ami = "ami-0c55b159cbfafe1f0";
    instance_type = vmShape;
    subnet_id = "\${aws_subnet.main.id}";
    vpc_security_group_ids = ["\${aws_security_group.main.id}"];
    associate_public_ip_address = true;
    user_data = ''
      #!/bin/sh
      mkfs.ext4 /dev/sdb
      mkdir -p /var/lib/longhorn
      mount /dev/sdb /var/lib/longhorn
    '';
    tags = {
      Name = "${hostnamePrefix}${lib.strings.removePrefix "vm" name}";
    };
  });

  resource.aws_ebs_volume = lib.genAttrs (lib.genList (i: "data${toString (i + 1)}") numVMs) (name: {
    availability_zone = "\${aws_instance.${lib.strings.replaceStrings ["data"] ["vm"] name}.availability_zone}";
    size = blockDeviceSize;
  });

  resource.aws_volume_attachment = lib.genAttrs (lib.genList (i: "attach${toString (i + 1)}") numVMs) (name: {
    device_name = "/dev/sdb";
    volume_id = "\${aws_ebs_volume.${lib.strings.replaceStrings ["attach"] ["data"] name}.id}";
    instance_id = "\${aws_instance.${lib.strings.replaceStrings ["attach"] ["vm"] name}.id}";
  });

  output.vm_ips = {
    value = lib.genList (i: "\${aws_instance.vm${toString (i + 1)}.public_ip}") numVMs;
  };
}
