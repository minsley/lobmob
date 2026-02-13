vault_repo   = "minsley/lobmob-vault-dev"
region       = "nyc3"
project_name = "lobmob-dev"
alert_email  = "insley.matthew@gmail.com"
environment  = "dev"
vpc_cidr     = "10.101.0.0/24"

# DOKS
doks_k8s_version        = "1.32.10-do.3"
doks_lobboss_node_size  = "s-2vcpu-4gb"
doks_lobster_node_size  = "s-2vcpu-4gb"
doks_lobster_max_nodes  = 3
