vault_repo   = "minsley/lobmob-vault"
region       = "nyc3"
project_name = "lobmob"
alert_email  = "insley.matthew@gmail.com"
environment  = "prod"
vpc_cidr     = "10.100.0.0/24"

# DOKS
doks_k8s_version           = "1.32.10-do.3"
doks_lobboss_node_size     = "s-1vcpu-2gb"
doks_lobwife_node_size     = "s-1vcpu-2gb"
doks_lobsigliere_node_size = "s-2vcpu-4gb"
doks_lobster_node_size     = "s-2vcpu-4gb"
doks_lobster_max_nodes     = 5
