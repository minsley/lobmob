# --- DOKS Kubernetes Cluster ---
# Gated behind var.doks_enabled so existing Droplet infra isn't affected.
# Free control plane; pay only for worker nodes.

resource "digitalocean_kubernetes_cluster" "lobmob" {
  count   = var.doks_enabled ? 1 : 0
  name    = "${var.project_name}-k8s"
  region  = var.region
  version = var.doks_k8s_version

  vpc_uuid = digitalocean_vpc.swarm.id

  # lobboss node pool — always-on, single node
  node_pool {
    name       = "lobboss"
    size       = var.doks_lobboss_node_size
    node_count = 1

    labels = {
      "lobmob.io/role" = "lobboss"
    }
  }

  tags = [digitalocean_tag.lobboss.id]
}

# Lobster node pool — autoscaling, 0 to N
resource "digitalocean_kubernetes_node_pool" "lobsters" {
  count      = var.doks_enabled ? 1 : 0
  cluster_id = digitalocean_kubernetes_cluster.lobmob[0].id
  name       = "lobsters"
  size       = var.doks_lobster_node_size
  auto_scale = true
  min_nodes  = 0
  max_nodes  = var.doks_lobster_max_nodes

  labels = {
    "lobmob.io/role" = "lobster"
  }

  tags = [digitalocean_tag.lobster.id]
}

# --- DOKS Outputs ---

output "doks_cluster_id" {
  value       = var.doks_enabled ? digitalocean_kubernetes_cluster.lobmob[0].id : ""
  description = "DOKS cluster ID"
}

output "doks_cluster_endpoint" {
  value       = var.doks_enabled ? digitalocean_kubernetes_cluster.lobmob[0].endpoint : ""
  description = "DOKS cluster API endpoint"
}

output "doks_cluster_name" {
  value       = var.doks_enabled ? digitalocean_kubernetes_cluster.lobmob[0].name : ""
  description = "DOKS cluster name (for doctl kubeconfig save)"
}
