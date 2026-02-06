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
