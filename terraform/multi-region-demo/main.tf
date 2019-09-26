# Consul Demo Cluster - Single Region

terraform {
  required_version = "< 0.12"

  required_providers {
    aws    = "~> 2.29"
    consul = "~> 2.5"
    null   = "~> 2.1"
  }
}

# Create MAIN Consul cluster
module "cluster_main" {
  source = "../modules/consul-demo-cluster"

  aws_region       = "${var.aws_region}"
  consul_dc        = "${var.consul_dc}"
  consul_acl_dc    = "${var.consul_dc}"
  vpc_netblock     = "${var.vpc_cidr_main}"
  project_name     = "${var.project_name}"
  top_level_domain = "${var.top_level_domain}"
  route53_zone_id  = "${var.route53_zone_id}"
  ssh_key_name     = "${var.ssh_key_name}"
  consul_lic       = "${var.consul_lic}"
  ami_prefix       = "${var.ami_prefix}"

  hashi_tags = "${var.hashi_tags}"
}

# Create ALTERNATE Consul cluster
module "cluster_alt" {
  source = "../modules/consul-demo-cluster"

  aws_region       = "${var.aws_region_alt}"
  consul_dc        = "${var.consul_dc_alt}"
  consul_acl_dc    = "${var.consul_dc}"
  vpc_netblock     = "${var.vpc_cidr_alt}"
  project_name     = "${var.project_name}"
  top_level_domain = "${var.top_level_domain}"
  route53_zone_id  = "${var.route53_zone_id}"
  ssh_key_name     = "${var.ssh_key_name}"
  consul_lic       = "${var.consul_lic}"
  ami_prefix       = "${var.ami_prefix}"

  hashi_tags = "${var.hashi_tags}"
}

# Link VPCs
module "link_vpc" {
  source = "../modules/link-vpc"

  aws_region_main     = "${module.cluster_main.aws_region}"
  vpc_id_main         = "${module.cluster_main.vpc_id}"
  route_table_id_main = "${module.cluster_main.vpc_public_route_table_id}"
  cidr_block_main     = "${module.cluster_main.vpc_netblock}"

  aws_region_alt     = "${module.cluster_alt.aws_region}"
  vpc_id_alt         = "${module.cluster_alt.vpc_id}"
  route_table_id_alt = "${module.cluster_alt.vpc_public_route_table_id}"
  cidr_block_alt     = "${module.cluster_alt.vpc_netblock}"

  hashi_tags = "${var.hashi_tags}"
}

# Configure Consul Clusters in each DC
provider "consul" {
  alias = "main"

  address    = "${element(module.cluster_main.consul_servers, 0)}:8500"
  datacenter = "${module.cluster_main.consul_dc}"
}

provider "consul" {
  alias = "alt"

  address    = "${element(module.cluster_alt.consul_servers, 0)}:8500"
  datacenter = "${module.cluster_alt.consul_dc}"
}

# Configure Prepared Query in main DC
resource "consul_prepared_query" "product_service_main" {
  provider = "consul.main"

  datacenter   = "${module.cluster_main.consul_dc}"
  name         = "product"
  only_passing = true
  connect      = true

  service = "product"

  failover {
    datacenters = ["${module.cluster_main.consul_dc}", "${module.cluster_alt.consul_dc}"]
  }
}

# Configure Prepared Query in alt DC
resource "consul_prepared_query" "product_service_alt" {
  provider = "consul.alt"

  datacenter   = "${module.cluster_alt.consul_dc}"
  name         = "product"
  only_passing = true
  connect      = true

  service = "product"

  failover {
    datacenters = ["${module.cluster_alt.consul_dc}", "${module.cluster_main.consul_dc}"]
  }
}

# Add configuration data to Consul KV in main DC
resource "consul_keys" "server_ips_main" {
  provider = "consul.main"

  key {
    path  = "server_ips"
    value = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  key {
    path   = "product/run"
    value  = "true"
    delete = true
  }
}

# Add configuration data to Consul KV in alt DC
resource "consul_keys" "server_ips_alt" {
  provider = "consul.alt"

  key {
    path  = "server_ips"
    value = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  key {
    path   = "product/run"
    value  = "true"
    delete = true
  }
}

# MAIN DC - join consul clusters using ssh_pri_key_data
resource "null_resource" "join_dc_main_keydata" {
  count      = "${length(var.ssh_pri_key_data) > 0 ? 1 : 0}"
  depends_on = ["module.link_vpc", "consul_keys.server_ips_main"]

  triggers = {
    consul_ips = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  connection {
    type        = "ssh"
    host        = "${element(module.cluster_main.consul_servers, 0)}"
    user        = "ubuntu"
    private_key = "${var.ssh_pri_key_data}"
  }

  provisioner "remote-exec" {
    when = "create"

    inline = [
      "consul lock server_ips consul join -wan $(consul kv get server_ips)",
    ]
  }
}

# MAIN DC - join consul clusters using ssh_pri_key_file
resource "null_resource" "join_dc_main_keyfile" {
  count      = "${length(var.ssh_pri_key_file) > 0 ? length(var.ssh_pri_key_data) == 0 ? 1 : 0 : 0}"
  depends_on = ["module.link_vpc", "consul_keys.server_ips_main"]

  triggers = {
    consul_ips = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  connection {
    type        = "ssh"
    host        = "${element(module.cluster_main.consul_servers, 0)}"
    user        = "ubuntu"
    private_key = "${file(var.ssh_pri_key_file)}"
  }

  provisioner "remote-exec" {
    when = "create"

    inline = [
      "consul lock server_ips consul join -wan $(consul kv get server_ips)",
    ]
  }
}

# ALT DC - join consul clusters using ssh_pri_key_data
resource "null_resource" "join_dc_alt_keydata" {
  count      = "${length(var.ssh_pri_key_data) > 0 ? 1 : 0}"
  depends_on = ["module.link_vpc", "consul_keys.server_ips_alt"]

  triggers = {
    consul_ips = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  connection {
    type        = "ssh"
    host        = "${element(module.cluster_alt.consul_servers, 0)}"
    user        = "ubuntu"
    private_key = "${var.ssh_pri_key_data}"
  }

  provisioner "remote-exec" {
    when = "create"

    inline = [
      "consul lock server_ips consul join -wan $(consul kv get server_ips)",
    ]
  }
}

# ALT DC - join consul clusters using ssh_pri_key_file
resource "null_resource" "join_dc_alt_keyfile" {
  count      = "${length(var.ssh_pri_key_file) > 0 ? length(var.ssh_pri_key_data) == 0 ? 1 : 0 : 0}"
  depends_on = ["module.link_vpc", "consul_keys.server_ips_alt"]

  triggers = {
    consul_ips = "${join(" ", concat(module.cluster_main.consul_servers_private_ip, module.cluster_alt.consul_servers_private_ip))}"
  }

  connection {
    type        = "ssh"
    host        = "${element(module.cluster_alt.consul_servers, 0)}"
    user        = "ubuntu"
    private_key = "${file(var.ssh_pri_key_file)}"
  }

  provisioner "remote-exec" {
    when = "create"

    inline = [
      "consul lock server_ips consul join -wan $(consul kv get server_ips)",
    ]
  }
}
