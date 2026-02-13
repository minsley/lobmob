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

# --- VPC ---

resource "digitalocean_vpc" "swarm" {
  name     = "${var.project_name}-vpc"
  region   = var.region
  ip_range = var.vpc_cidr
}

# --- Tags ---

resource "digitalocean_tag" "lobboss" {
  name = "${var.project_name}-lobboss"
}

resource "digitalocean_tag" "lobster" {
  name = "${var.project_name}-lobster"
}

# --- Project ---
# Groups all lobmob resources in the DO console.

resource "digitalocean_project" "lobmob" {
  name        = var.project_name
  description = "Agent swarm on DOKS"
  purpose     = "Operational / Developer tooling"
  environment = var.environment == "prod" ? "Production" : "Development"
  resources = [
    digitalocean_kubernetes_cluster.lobmob.urn,
  ]
}

# --- Outputs ---

output "vpc_id" {
  value       = digitalocean_vpc.swarm.id
  description = "VPC ID"
}

output "project_id" {
  value       = digitalocean_project.lobmob.id
  description = "DO Project ID for lobmob"
}
