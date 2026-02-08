# --- Infrastructure variables (non-secret) ---
# Secrets are stored in secrets.env and pushed via SSH after deploy.
# The DO provider authenticates via DIGITALOCEAN_TOKEN env var.

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
}

variable "manager_size" {
  description = "Droplet size for the lobboss node"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_size" {
  description = "Droplet size for lobster nodes"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "ssh_pub_key_path" {
  description = "Path to SSH public key for droplet access"
  type        = string
  default     = "~/.ssh/lobmob_ed25519.pub"
}

variable "vault_repo" {
  description = "GitHub repo for the Obsidian vault (org/repo format)"
  type        = string
}

variable "wg_lobboss_public_key" {
  description = "WireGuard public key for lobboss (not secret — used in lobster configs)"
  type        = string
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "lobmob"
}

variable "alert_email" {
  description = "Email address for monitoring alerts"
  type        = string
}

variable "environment" {
  description = "Environment name (prod or dev)"
  type        = string
  default     = "prod"
}

variable "vpc_cidr" {
  description = "VPC CIDR block"
  type        = string
  default     = "10.100.0.0/24"
}

variable "wg_subnet" {
  description = "WireGuard subnet prefix (e.g. 10.0.0 for 10.0.0.0/24)"
  type        = string
  default     = "10.0.0"
}

variable "discord_channels" {
  description = "Discord channel names for the swarm"
  type = object({
    task_queue    = string
    swarm_control = string
    swarm_logs    = string
  })
  default = {
    task_queue    = "task-queue"
    swarm_control = "swarm-control"
    swarm_logs    = "swarm-logs"
  }
}

variable "enable_monitoring" {
  description = "Whether to create monitoring alerts"
  type        = bool
  default     = true
}
