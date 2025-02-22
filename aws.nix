{ pkgs, terranix, lib, numVMs, vmShape, region, hostnamePrefix, blockDeviceSize }:
{
  variable.aws_access_key = {};
  variable.aws_secret_key = {};

  provider.aws = {
    region = region;
    access_key = "var.aws_access_key";
    secret_key = "var.aws_secret_key";
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
    ingress = lib.genList (i: {
      from_port = [
        41641 80 443 53 53 6443 10250 2379
      ].[i];
      to_port = [
        41641 80 443 53 53 6443 10250 2380
      ].[i];
      protocol = [
        "udp" "tcp" "tcp" "udp" "tcp" "tcp" "tcp" "tcp"
      ].[i];
      cidr_blocks = ["0.0.0.0/0"];
      description = [
        "Tailscale" "HTTP" "HTTPS" "DNS" "DNS" 
        "Kubernetes API" "Kubelet" "etcd"
      ].[i];
      ipv6_cidr_blocks = [];
      prefix_list_ids = [];
      security_groups = [];
      self = false;
    }) 8;

    egress = [{
      from_port = 0;
      to_port = 0;
      protocol = "-1";
      cidr_blocks = ["0.0.0.0/0"];
      ipv6_cidr_blocks = [];
      prefix_list_ids = [];
      security_groups = [];
      self = false;
    }];
  };

  resource.aws_instance = lib.genAttrs (map (i: "vm${toString i}") (lib.range 1 numVMs)) (name: {
    ami = "ami-0c55b159cbfafe1f0";
    instance_type = vmShape;
    subnet_id = "\${aws_subnet.main.id}";
    vpc_security_group_ids = ["\${aws_security_group.main.id}"];
    associate_public_ip_address = true;
    user_data = pkgs.writeScript "userdata" ''
      #!/bin/sh
      mkfs.ext4 /dev/sdb
      mkdir -p /var/lib/longhorn
      mount /dev/sdb /var/lib/longhorn
    '';
    tags = {
      Name = "${hostnamePrefix}${lib.strings.removePrefix "vm" name}";
    };
  });

  resource.aws_ebs_volume = lib.genAttrs (map (i: "data${toString i}") (lib.range 1 numVMs)) (name: {
    availability_zone = "\${aws_instance.vm${lib.strings.removePrefix "data" name}.availability_zone}";
    size = blockDeviceSize;
    type = "gp3";
  });

  resource.aws_volume_attachment = lib.genAttrs (map (i: "attach${toString i}") (lib.range 1 numVMs)) (name: let
    i = lib.strings.removePrefix "attach" name;
  in {
    device_name = "/dev/sdb";
    volume_id = "\${aws_ebs_volume.data${i}.id}";
    instance_id = "\${aws_instance.vm${i}.id}";
  });

  output.vm_ips = {
    value = lib.genList (i: "\${aws_instance.vm${toString (i + 1)}.public_ip}") numVMs;
  };
}
