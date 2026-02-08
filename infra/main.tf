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
  ip_range = var.vpc_cidr
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

  # HTTPS (web dashboard)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "443"
    source_addresses = ["0.0.0.0/0", "::/0"]
  }

  # HTTP (Let's Encrypt ACME http-01 challenge only)
  inbound_rule {
    protocol         = "tcp"
    port_range       = "80"
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
    source_addresses = ["${var.wg_subnet}.1/32"]
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
    vault_repo        = var.vault_repo
    project_name      = var.project_name
    lobster_size      = var.worker_size
    region            = var.region
    ssh_key_id        = digitalocean_ssh_key.lobmob.id
    vpc_uuid          = digitalocean_vpc.swarm.id
    lobster_tag       = digitalocean_tag.lobster.name
    wg_subnet         = var.wg_subnet
    discord_channels  = var.discord_channels
  })

  # Cloud-init only runs at creation time. Script updates are deployed via
  # `lobmob provision-secrets` over SSH, so user_data changes should NOT
  # trigger droplet replacement.
  lifecycle {
    ignore_changes = [user_data]
  }
}

# --- Reserved IP ---
# Static IP for lobboss — survives droplet recreates, keeps WireGuard stable

resource "digitalocean_reserved_ip" "lobboss" {
  region = var.region
}

resource "digitalocean_reserved_ip_assignment" "lobboss" {
  ip_address = digitalocean_reserved_ip.lobboss.ip_address
  droplet_id = digitalocean_droplet.lobboss.id
}

# --- Project ---
# Groups all lobmob resources in the DO console.
# Note: reserved IP excluded from resources due to provider bug (floatingip URN drift).
# Lobsters are assigned via doctl in the spawn script.

resource "digitalocean_project" "lobmob" {
  name        = var.project_name
  description = "OpenClaw agent swarm"
  purpose     = "Operational / Developer tooling"
  environment = var.environment == "prod" ? "Production" : "Development"
  resources = [
    digitalocean_droplet.lobboss.urn,
  ]
}

# --- Monitoring Alerts ---

resource "digitalocean_monitor_alert" "lobboss_cpu" {
  count       = var.enable_monitoring ? 1 : 0
  description = "lobboss CPU > 90% for 5m"
  type        = "v1/insights/droplet/cpu"
  compare     = "GreaterThan"
  value       = 90
  window      = "5m"
  enabled     = true
  entities    = [digitalocean_droplet.lobboss.id]
  alerts { email = [var.alert_email] }
}

resource "digitalocean_monitor_alert" "lobboss_memory" {
  count       = var.enable_monitoring ? 1 : 0
  description = "lobboss memory > 90% for 5m"
  type        = "v1/insights/droplet/memory_utilization_percent"
  compare     = "GreaterThan"
  value       = 90
  window      = "5m"
  enabled     = true
  entities    = [digitalocean_droplet.lobboss.id]
  alerts { email = [var.alert_email] }
}

resource "digitalocean_monitor_alert" "lobboss_disk" {
  count       = var.enable_monitoring ? 1 : 0
  description = "lobboss disk > 85% for 10m"
  type        = "v1/insights/droplet/disk_utilization_percent"
  compare     = "GreaterThan"
  value       = 85
  window      = "10m"
  enabled     = true
  entities    = [digitalocean_droplet.lobboss.id]
  alerts { email = [var.alert_email] }
}

resource "digitalocean_monitor_alert" "lobster_cpu" {
  count       = var.enable_monitoring ? 1 : 0
  description = "Lobster fleet CPU > 90% for 5m"
  type        = "v1/insights/droplet/cpu"
  compare     = "GreaterThan"
  value       = 90
  window      = "5m"
  enabled     = true
  tags        = [digitalocean_tag.lobster.name]
  alerts { email = [var.alert_email] }
}

resource "digitalocean_monitor_alert" "lobster_memory" {
  count       = var.enable_monitoring ? 1 : 0
  description = "Lobster fleet memory > 90% for 5m"
  type        = "v1/insights/droplet/memory_utilization_percent"
  compare     = "GreaterThan"
  value       = 90
  window      = "5m"
  enabled     = true
  tags        = [digitalocean_tag.lobster.name]
  alerts { email = [var.alert_email] }
}

resource "digitalocean_monitor_alert" "lobster_disk" {
  count       = var.enable_monitoring ? 1 : 0
  description = "Lobster fleet disk > 85% for 10m"
  type        = "v1/insights/droplet/disk_utilization_percent"
  compare     = "GreaterThan"
  value       = 85
  window      = "10m"
  enabled     = true
  tags        = [digitalocean_tag.lobster.name]
  alerts { email = [var.alert_email] }
}

# --- Outputs ---

output "lobboss_ip" {
  value       = digitalocean_reserved_ip.lobboss.ip_address
  description = "Lobboss reserved (static) public IP"
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

output "project_id" {
  value       = digitalocean_project.lobmob.id
  description = "DO Project ID for lobmob"
}
