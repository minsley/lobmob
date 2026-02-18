# --- DOKS Kubernetes Cluster ---
# Free control plane; pay only for worker nodes.
# The default node pool can't be resized without cluster recreation,
# so we use lobsigliere (highest requirements, benefits from headroom
# as a remote dev environment, unlikely to ever downsize).

resource "digitalocean_kubernetes_cluster" "lobmob" {
  name    = "${var.project_name}-k8s"
  region  = var.region
  version = var.doks_k8s_version

  vpc_uuid = digitalocean_vpc.swarm.id

  # lobsigliere node pool (default) — always-on, single node
  node_pool {
    name       = "lobsigliere"
    size       = var.doks_lobsigliere_node_size
    node_count = 1

    labels = {
      "lobmob.io/role" = "lobsigliere"
    }
  }

  tags = [digitalocean_tag.lobsigliere.id]
}

# Lobboss node pool — always-on, single node
resource "digitalocean_kubernetes_node_pool" "lobboss" {
  cluster_id = digitalocean_kubernetes_cluster.lobmob.id
  name       = "lobboss"
  size       = var.doks_lobboss_node_size
  node_count = 1

  labels = {
    "lobmob.io/role" = "lobboss"
  }

  tags = [digitalocean_tag.lobboss.id]
}

# Lobwife node pool — always-on, single node
resource "digitalocean_kubernetes_node_pool" "lobwife" {
  cluster_id = digitalocean_kubernetes_cluster.lobmob.id
  name       = "lobwife"
  size       = var.doks_lobwife_node_size
  node_count = 1

  labels = {
    "lobmob.io/role" = "lobwife"
  }

  tags = [digitalocean_tag.lobwife.id]
}

# Lobster node pool — autoscaling, 0 to N
resource "digitalocean_kubernetes_node_pool" "lobsters" {
  cluster_id = digitalocean_kubernetes_cluster.lobmob.id
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

# --- Outputs ---

output "doks_cluster_id" {
  value       = digitalocean_kubernetes_cluster.lobmob.id
  description = "DOKS cluster ID"
}

output "doks_cluster_endpoint" {
  value       = digitalocean_kubernetes_cluster.lobmob.endpoint
  description = "DOKS cluster API endpoint"
}

output "doks_cluster_name" {
  value       = digitalocean_kubernetes_cluster.lobmob.name
  description = "DOKS cluster name (for doctl kubeconfig save)"
}
