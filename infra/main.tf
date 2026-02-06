terraform {
  required_version = ">= 1.5"

  required_providers {
    digitalocean = {
      source  = "digitalocean/digitalocean"
      version = "~> 2.0"
    }
  }
}

# Authenticates via DIGITALOCEAN_TOKEN env var — no token in state
provider "digitalocean" {}

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

resource "digitalocean_firewall" "lobboss" {
  name        = "${var.project_name}-lobboss-fw"
  droplet_ids = [digitalocean_droplet.lobboss.id]

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

resource "digitalocean_firewall" "lobster" {
  name = "${var.project_name}-lobster-fw"
  tags = [digitalocean_tag.lobster.id]

  # SSH only from lobboss WireGuard IP
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

  # All outbound (lobsters need internet for GitHub, Discord, LLM APIs)
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

resource "digitalocean_tag" "lobboss" {
  name = "${var.project_name}-lobboss"
}

resource "digitalocean_tag" "lobster" {
  name = "${var.project_name}-lobster"
}

# --- Lobboss Droplet ---
# Cloud-init installs packages and scripts only — zero secrets.
# Secrets are pushed via SSH after boot by `lobmob deploy`.

resource "digitalocean_droplet" "lobboss" {
  name     = "${var.project_name}-lobboss"
  region   = var.region
  size     = var.manager_size
  image    = "ubuntu-24-04-x64"
  vpc_uuid = digitalocean_vpc.swarm.id
  ssh_keys = [digitalocean_ssh_key.lobmob.id]
  tags     = [digitalocean_tag.lobboss.id]

  user_data = templatefile("${path.module}/../templates/cloud-init-lobboss.yaml", {
    vault_repo   = var.vault_repo
    project_name = var.project_name
    lobster_size = var.worker_size
    region       = var.region
    ssh_key_id   = digitalocean_ssh_key.lobmob.id
    vpc_uuid     = digitalocean_vpc.swarm.id
    lobster_tag  = digitalocean_tag.lobster.name
  })
}

# --- Outputs ---

output "lobboss_ip" {
  value       = digitalocean_droplet.lobboss.ipv4_address
  description = "Lobboss droplet public IP"
}

output "lobboss_private_ip" {
  value       = digitalocean_droplet.lobboss.ipv4_address_private
  description = "Lobboss droplet VPC IP"
}

output "vpc_id" {
  value       = digitalocean_vpc.swarm.id
  description = "VPC ID for lobster droplets"
}

output "lobster_firewall_id" {
  value       = digitalocean_firewall.lobster.id
  description = "Firewall applied to lobster droplets"
}
