vault_repo            = "minsley/lobmob-vault-dev"
wg_lobboss_public_key = "__GENERATE_WITH_lobmob_init__"
ssh_pub_key_path      = "/Users/matt/.ssh/lobmob_ed25519.pub"
region                = "nyc3"
project_name          = "lobmob-dev"
alert_email           = "insley.matthew@gmail.com"
environment           = "dev"
vpc_cidr              = "10.101.0.0/24"
wg_subnet             = "10.1.0"
manager_size          = "s-1vcpu-2gb"
worker_size           = "s-1vcpu-1gb"
enable_monitoring     = false

discord_channels = {
  task_queue    = "dev-task-queue"
  swarm_control = "dev-swarm-control"
  swarm_logs    = "dev-swarm-logs"
}
