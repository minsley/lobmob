variable "do_token" {
  description = "DigitalOcean API token"
  type        = string
  sensitive   = true
}

variable "gh_token" {
  description = "GitHub fine-grained PAT scoped to the vault repo"
  type        = string
  sensitive   = true
}

variable "discord_bot_token" {
  description = "Discord bot token for OpenClaw"
  type        = string
  sensitive   = true
}

variable "anthropic_api_key" {
  description = "Anthropic API key for Claude"
  type        = string
  sensitive   = true
}

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
}

variable "manager_size" {
  description = "Droplet size for the manager node"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "worker_size" {
  description = "Droplet size for worker nodes"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "ssh_pub_key_path" {
  description = "Path to SSH public key for droplet access"
  type        = string
  default     = "~/.ssh/id_ed25519.pub"
}

variable "vault_repo" {
  description = "GitHub repo for the Obsidian vault (org/repo format)"
  type        = string
}

variable "vault_deploy_key_private" {
  description = "Base64-encoded private deploy key for the vault repo"
  type        = string
  sensitive   = true
}

variable "wg_manager_private_key" {
  description = "WireGuard private key for manager (generate with wg genkey)"
  type        = string
  sensitive   = true
}

variable "wg_manager_public_key" {
  description = "WireGuard public key for manager"
  type        = string
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "lobmob"
}
