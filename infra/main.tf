terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

provider "digitalocean" {
  token = var.do_token
}

# --- SSH Key ---

resource "digitalocean_ssh_key" "lobmob" {
  name       = "${var.project_name}-key"
  public_key = file(var.ssh_pub_key_path)
}

# --- VPC ---

resource "digitalocean_vpc" "swarm" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = "10.100.0.0/24"
}

# --- Cloud Firewall ---

resource "digitalocean_firewall" "manager" {
  name        = "${var.project_name}-manager-fw"
  droplet_ids = [digitalocean_droplet.manager.id]

  # SSH from anywhere (tighten to your IP in production)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # WireGuard
  inbound_rule {
    protocol         = "udp"
    port_range       = "51820"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

resource "digitalocean_firewall" "worker" {
  name = "${var.project_name}-worker-fw"
  tags = [digitalocean_tag.worker.id]

  # SSH only from manager's WireGuard IP
  inbound_rule {
    protocol         = "tcp"
    port_range       = "22"
    source_addresses = ["10.0.0.1/32"]
  }

  # WireGuard
  inbound_rule {
    protocol         = "udp"
    port_range       = "51820"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # All outbound (workers need internet for GitHub, Discord, LLM APIs)
  outbound_rule {
    protocol              = "tcp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "udp"
    port_range            = "1-65535"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
  outbound_rule {
    protocol              = "icmp"
    destination_addresses = ["0.0.0.0/0", "::/0"]
  }
}

# --- Tags ---

resource "digitalocean_tag" "manager" {
  name = "${var.project_name}-manager"
}

resource "digitalocean_tag" "worker" {
  name = "${var.project_name}-worker"
}

# --- Manager Droplet ---

resource "digitalocean_droplet" "manager" {
  name     = "${var.project_name}-manager"
  region   = var.region
  size     = var.manager_size
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.swarm.id
  ssh_keys = [digitalocean_ssh_key.lobmob.id]
  tags     = [digitalocean_tag.manager.id]

  user_data = templatefile("${path.module}/../templates/cloud-init-manager.yaml", {
    do_token              = var.do_token
    gh_token              = var.gh_token
    discord_bot_token     = var.discord_bot_token
    anthropic_api_key     = var.anthropic_api_key
    vault_repo            = var.vault_repo
    vault_deploy_key_b64  = var.vault_deploy_key_private
    wg_private_key        = var.wg_manager_private_key
    project_name          = var.project_name
    worker_size           = var.worker_size
    region                = var.region
    ssh_key_id            = digitalocean_ssh_key.lobmob.id
    vpc_uuid              = digitalocean_vpc.swarm.id
    worker_tag            = digitalocean_tag.worker.name
  })
}

# --- Outputs ---

output "manager_ip" {
  value       = digitalocean_droplet.manager.ipv4_address
  description = "Manager droplet public IP"
}

output "manager_private_ip" {
  value       = digitalocean_droplet.manager.ipv4_address_private
  description = "Manager droplet VPC IP"
}

output "vpc_id" {
  value       = digitalocean_vpc.swarm.id
  description = "VPC ID for worker droplets"
}

output "worker_firewall_id" {
  value       = digitalocean_firewall.worker.id
  description = "Firewall applied to worker droplets"
}
