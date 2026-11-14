# PRODUCTION — Amazon MQ for RabbitMQ 4.3, eu-west-1 (Ireland)
#
# Decisions (2026-11-14): production lives in a dedicated AWS account (not 490228638978).
# Amazon MQ is private only: there is no public endpoint and no plain AMQP 5672. The 264
# internet clients need VPN/Transit Gateway connectivity and TLS before using this broker.
#
# Every REPLACE_ value comes from the production account. Placeholders are deliberately
# invalid, so `terraform plan` fails until every one is filled in. Do not commit this file
# (*.tfvars is git-ignored).
#
#   cd examples/amazon-mq   # with the S3 backend block in main.tf enabled
#   export TF_VAR_admin_password=...   # from the CI secret store, never in this file
#   terraform init
#   terraform plan -var-file=production.tfvars -out=production.tfplan
#
# The AWS provider stores admin_password in state: the backend must be encrypted, locked and
# access-restricted. Do not change admin_username/admin_password after creation; that can
# force broker replacement (modules/amazon-mq/README.md).

name   = "prod-managed-rabbit"
region = "eu-west-1"
vpc_id = "vpc-REPLACE_PROD_VPC"

# Exactly three PRIVATE subnets, one per AZ (eu-west-1a/b/c), no public-IP mapping.
subnet_ids = [
  "subnet-REPLACE_PRIVATE_EUW1A",
  "subnet-REPLACE_PRIVATE_EUW1B",
  "subnet-REPLACE_PRIVATE_EUW1C",
]

# Both offered in eu-west-1 as CLUSTER_MULTI_AZ in 1a/1b/1c (checked 2026-11-14).
# Size independently of the EC2 r5n benchmark.
engine_version = "4.3"
instance_type  = "mq.m7g.2xlarge"

admin_username = "bootstrap-admin"
# admin_password: TF_VAR_admin_password only.

# ---------------------------------------------------------------------------
# Client access: AMQPS 5671 only, private addresses only.
# Include the ranges the 264 internet clients will arrive from over VPN/TGW.
# ---------------------------------------------------------------------------
client_cidrs = [
  "REPLACE_PRIVATE_CLIENT_CIDR",
  "REPLACE_VPN_OR_TGW_CLIENT_CIDR",
]

# In-VPC application tiers, by security group, e.g. ["sg-0123456789abcdef0"].
client_security_group_ids = []

# HTTPS UI/API (443 and 15671) for administrators only.
management_cidrs = ["REPLACE_ADMIN_VPN_CIDR"]

# ---------------------------------------------------------------------------
# Encryption and private federation
# ---------------------------------------------------------------------------
# Customer key; its policy must allow Amazon MQ (and EBS grants) for this account.
kms_key_arn = "arn:aws:kms:eu-west-1:REPLACE_PROD_ACCOUNT_ID:key/REPLACE_MQ_KEY_ID"

# Approved AWS RAM shares of VPC Lattice resource configurations for private TKY/LDN
# upstreams (docs/migration.md#5-federation-direction). Leave [] if this broker is only an
# upstream, or until the network team provides the shares.
resource_share_arns = [
  "arn:aws:ram:eu-west-1:REPLACE_PROD_ACCOUNT_ID:resource-share/REPLACE_TKY_SHARE_ID",
  "arn:aws:ram:eu-west-1:REPLACE_PROD_ACCOUNT_ID:resource-share/REPLACE_LDN_SHARE_ID",
]

# ---------------------------------------------------------------------------
# Maintenance and alerting
# ---------------------------------------------------------------------------
# UTC. Sunday 02:00 UTC is 02:00/03:00 in London and 11:00 Sunday in Tokyo; confirm it is
# a low-traffic window for both federated sites. Clients must reconnect during maintenance.
maintenance_window = { day = "SUNDAY", time = "02:00" }

# Memory is a cluster aggregate; disk is the worst single node.
memory_alarm_percent     = 70
node_disk_free_alarm_gib = 10
alarm_action_arns        = ["arn:aws:sns:eu-west-1:REPLACE_PROD_ACCOUNT_ID:REPLACE_ONCALL_TOPIC"]

tags = {
  Environment = "production"
  Owner       = "messaging"
}
