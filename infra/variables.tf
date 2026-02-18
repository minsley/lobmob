# --- Infrastructure variables (non-secret) ---
# The DO provider authenticates via DIGITALOCEAN_TOKEN env var.

variable "region" {
  description = "DigitalOcean region"
  type        = string
  default     = "nyc3"
}

variable "project_name" {
  description = "Name prefix for all resources"
  type        = string
  default     = "lobmob"
}

variable "vault_repo" {
  description = "GitHub repo for the Obsidian vault (org/repo format)"
  type        = string
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

# --- DOKS variables ---

variable "doks_k8s_version" {
  description = "Kubernetes version for DOKS cluster (use `doctl kubernetes options versions` to list)"
  type        = string
  default     = "1.32.10-do.3"
}

variable "doks_lobboss_node_size" {
  description = "Node size for the lobboss (always-on) node pool"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "doks_lobwife_node_size" {
  description = "Node size for the lobwife (always-on) node pool"
  type        = string
  default     = "s-1vcpu-2gb"
}

variable "doks_lobsigliere_node_size" {
  description = "Node size for the lobsigliere (always-on) node pool"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "doks_lobster_node_size" {
  description = "Node size for the lobster (autoscaling) node pool"
  type        = string
  default     = "s-2vcpu-4gb"
}

variable "doks_lobster_max_nodes" {
  description = "Maximum number of nodes in the lobster autoscaling pool"
  type        = number
  default     = 5
}
