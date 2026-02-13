vault_repo            = "minsley/lobmob-vault"
wg_lobboss_public_key = "brQU20/YxgxGWJQEuv+d9GOX8oB6JDiqHDPc3sGcTDM="
ssh_pub_key_path      = "/Users/matt/.ssh/lobmob_ed25519.pub"
region                = "nyc3"
project_name          = "lobmob"
alert_email           = "insley.matthew@gmail.com"
environment           = "prod"
vpc_cidr              = "10.100.0.0/24"
wg_subnet             = "10.0.0"
enable_monitoring     = true

# DOKS — enable when ready to deploy k8s
doks_enabled            = false
doks_lobboss_node_size  = "s-2vcpu-4gb"
doks_lobster_node_size  = "s-2vcpu-4gb"
doks_lobster_max_nodes  = 5
