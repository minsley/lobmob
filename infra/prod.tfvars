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

# DOKS
doks_enabled            = true
doks_k8s_version        = "1.32.10-do.3"
doks_lobboss_node_size  = "s-2vcpu-4gb"
doks_lobster_node_size  = "s-2vcpu-4gb"
doks_lobster_max_nodes  = 5
