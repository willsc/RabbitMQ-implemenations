# SANDBOX — Amazon MQ for RabbitMQ 4.3, account 490228638978, eu-west-1 (Ireland)
#
# Not production (see production.tfvars). No VPN and no external client ranges: the broker
# is private and only reachable from inside the VPC (172.31.0.0/16). From a laptop, port
# forward through an SSM-managed instance in the VPC.
#
#   cd examples/amazon-mq
#   export TF_VAR_admin_password=...   # never in this file
#   terraform init
#   terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
#
# BEFORE THE FIRST PLAN (checked 2026-11-15):
#   1. The three subnets below are the default VPC's subnets. They auto-assign public IPs,
#      which the module rejects ("Broker subnets must ... disable public IP assignment"):
#        aws ec2 modify-subnet-attribute --no-map-public-ip-on-launch --subnet-id <id>
#   2. Create a customer-managed KMS key whose policy allows Amazon MQ (none exists yet).
#
# admin_password is stored in Terraform state; keep local state off shared machines or use
# an encrypted S3 backend.

name   = "sbx-managed-rabbit"
region = "eu-west-1"
vpc_id = "vpc-052869dcdcbbddf14" # default VPC, 172.31.0.0/16

# One subnet per AZ.
subnet_ids = [
  "subnet-02e248c5020370d77", # eu-west-1a, 172.31.0.0/20
  "subnet-0a059cc7141f96225", # eu-west-1b, 172.31.16.0/20
  "subnet-09fe45cd17a789a9c", # eu-west-1c, 172.31.32.0/20
]

# Smallest size the module allows, to keep sandbox cost down (production: mq.m7g.2xlarge).
engine_version = "4.3"
instance_type  = "mq.m7g.large"

admin_username = "bootstrap-admin"

# AMQPS 5671 and HTTPS UI from inside the VPC only.
client_cidrs              = ["172.31.0.0/16"]
client_security_group_ids = []
management_cidrs          = ["172.31.0.0/16"]

kms_key_arn = "arn:aws:kms:eu-west-1:490228638978:key/REPLACE_MQ_KEY_ID"

# No TKY/LDN Lattice shares in this account.
resource_share_arns = []

maintenance_window       = { day = "SUNDAY", time = "02:00" }
memory_alarm_percent     = 70
node_disk_free_alarm_gib = 10

# No SNS topic in this account yet; alarms are created without actions.
alarm_action_arns = []

tags = {
  Environment = "sandbox"
  Owner       = "messaging"
}
