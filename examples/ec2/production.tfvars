# PRODUCTION — RabbitMQ 4.4 on EC2, eu-west-1 (Ireland)
#
# Decisions (2026-11-14):
#   * Production lives in a dedicated AWS account (not 490228638978).
#   * Internet clients use an allowlisted, internet-facing AMQPS 5671 NLB; brokers stay private.
#   * Private clients keep temporary plain AMQP 5672 on an internal NLB until cutover.
#
# Every REPLACE_ value comes from the production account. Placeholders are deliberately
# invalid, so `terraform plan` fails until every one is filled in. Do not commit this file
# (*.tfvars is git-ignored).
#
#   cd examples/ec2   # with the S3 backend block in main.tf enabled
#   terraform init
#   terraform plan -var-file=production.tfvars -out=production.tfplan
#
# Before the first plan: bootstrap secret, definitions object and AMI must exist
# (docs/operations.md#first-deployment-ec2).

name   = "prod-rabbit"
region = "eu-west-1"
vpc_id = "vpc-REPLACE_PROD_VPC" # DNS support and DNS hostnames must be enabled

# ---------------------------------------------------------------------------
# Broker nodes: one PRIVATE subnet per AZ (eu-west-1a/b/c), no public-IP mapping,
# with NAT or VPC endpoints for Secrets Manager, S3, CloudWatch, SSM.
# All three start on the same Packer-baked Ubuntu 26.04 AMI; later AMI rolls change
# one node at a time (docs/operations.md#replace-or-update-one-node).
# ---------------------------------------------------------------------------
nodes = {
  a = { subnet_id = "subnet-REPLACE_PRIVATE_EUW1A", ami_id = "ami-REPLACE_PACKER_AMI" }
  b = { subnet_id = "subnet-REPLACE_PRIVATE_EUW1B", ami_id = "ami-REPLACE_PACKER_AMI" }
  c = { subnet_id = "subnet-REPLACE_PRIVATE_EUW1C", ami_id = "ami-REPLACE_PACKER_AMI" }
}

# "self" when Packer bakes in the production account; otherwise the 12-digit build
# account that shares the AMI.
ami_owner_ids = ["self"]

# Offered in all three eu-west-1 AZs (euw1-az1/2/3), checked 2026-11-14. Starting size
# only: load-test at 874+ connections and 83 MB/s with one node down before go-live.
instance_type = "r5n.2xlarge"

# Per node, never shared. 200 GiB holds roughly 40 minutes of full-rate (83 MB/s) backlog
# above the 5 GB disk alarm; 6000 IOPS / 250 MiB/s leaves headroom for persistent
# messages. Grow online later; shrinking is impossible.
data_volume = {
  size       = 200
  iops       = 6000
  throughput = 250
}

# Node identities rabbit@{a,b,c}.prod-rabbit.internal. Must not overlap any existing
# private zone associated with this VPC.
private_zone_name = "prod-rabbit.internal"

# ---------------------------------------------------------------------------
# Client AMQPS 5671: internet-facing NLB, allowlisted. TLS terminates on RabbitMQ.
# The certificate in the bootstrap secret must cover tls_dns.name AND management_dns.name.
# ---------------------------------------------------------------------------
enable_tls = true
tls_public = true

# Three PUBLIC subnets (Internet Gateway route), one per AZ, in the same VPC.
tls_subnet_ids = [
  "subnet-REPLACE_PUBLIC_EUW1A",
  "subnet-REPLACE_PUBLIC_EUW1B",
  "subnet-REPLACE_PUBLIC_EUW1C",
]

# Public hosted zone and the hostname clients will verify.
tls_dns = { zone_id = "REPLACE_PUBLIC_ZONE_ID", name = "amqps.REPLACE_PUBLIC_DOMAIN" }

# Explicit allowlist; 0.0.0.0/0 is rejected. Include:
#  - the egress CIDRs of the 264 internet clients (from the connection audit,
#    docs/migration.md#1-inventory-the-current-broker)
#  - the NAT gateway EIPs (/32) of any private network whose clients use AMQPS. With a
#    public NLB, in-VPC clients reach 5671 through NAT, not privately.
tls_client_cidrs = [
  "REPLACE_INTERNET_CLIENT_CIDR",
  "REPLACE_NAT_EIP_CIDR",
]

# RabbitMQ username/password over TLS. Set true only once every client has a certificate.
require_client_certificate = false

# ---------------------------------------------------------------------------
# Temporary plain AMQP 5672: separate INTERNAL NLB in the node subnets, RFC1918 only.
# After cutover: set to [] and roll the nodes to remove the listener.
# ---------------------------------------------------------------------------
plaintext_client_cidrs = [
  "REPLACE_PRIVATE_CLIENT_CIDR",
]

# ---------------------------------------------------------------------------
# Management UI: private HTTPS 443 -> RabbitMQ 15671 on an internal NLB.
# ---------------------------------------------------------------------------
management_dns          = { zone_id = "REPLACE_PRIVATE_ZONE_ID", name = "rabbitmq-ui.REPLACE_INTERNAL_DOMAIN" }
management_client_cidrs = ["REPLACE_ADMIN_VPN_CIDR"] # RFC1918 only, e.g. the VPN client pool

# Prometheus scrapers (15692): per-queue depth, federation links, per-node memory/disk.
monitoring_cidrs = ["REPLACE_PROMETHEUS_CIDR"]

# ---------------------------------------------------------------------------
# Secrets, definitions and encryption. Nothing secret is stored in this file or in state.
# ---------------------------------------------------------------------------
# JSON: erlang_cookie, ca_certificate_pem, certificate_pem, private_key_pem
# (modules/ec2/README.md#runtime-secret). Use the full ARN, including the random suffix.
bootstrap_secret_arn = "arn:aws:secretsmanager:eu-west-1:REPLACE_PROD_ACCOUNT_ID:secret:prod/rabbitmq/bootstrap-REPLACE"

# Output of scripts/prepare_definitions.py, uploaded to a versioned, KMS-encrypted,
# public-access-blocked bucket (docs/migration.md#4-definitions-pipeline).
definitions = {
  bucket     = "REPLACE_PROD_DEFINITIONS_BUCKET"
  key        = "rabbitmq/prod-rabbit/definitions.json"
  version_id = "REPLACE_S3_VERSION_ID"
  sha256     = "REPLACE_64_HEX_SHA256"
}

# Key policies must allow EC2/EBS use by the deploying role (EBS key), Secrets Manager
# and S3 decrypt (secret/object keys), and the eu-west-1 Logs service (log key).
kms_key_arn         = "arn:aws:kms:eu-west-1:REPLACE_PROD_ACCOUNT_ID:key/REPLACE_EBS_KEY_ID"
secret_kms_key_arns = ["arn:aws:kms:eu-west-1:REPLACE_PROD_ACCOUNT_ID:key/REPLACE_SECRETS_KEY_ID"]
log_kms_key_arn     = "arn:aws:kms:eu-west-1:REPLACE_PROD_ACCOUNT_ID:key/REPLACE_LOGS_KEY_ID"

# ---------------------------------------------------------------------------
# Federation (TLS 5671 egress) and other egress
# ---------------------------------------------------------------------------
federation_egress = {
  TKY = "REPLACE_TKY_UPSTREAM_CIDR"
  LDN = "REPLACE_LDN_UPSTREAM_CIDR"
}

# AWS APIs over HTTPS. Narrow to interface-endpoint subnets once every service in
# modules/ec2/README.md has a VPC endpoint.
https_egress_cidrs = ["0.0.0.0/0"]

# Leave false unless the queue audit finds durable=false, exclusive=false queues that
# clients cannot change before cutover.
allow_transient_nonexclusive_queues = false

# ---------------------------------------------------------------------------
# Protection and alerting
# ---------------------------------------------------------------------------
nlb_deletion_protection = true
alarm_action_arns       = ["arn:aws:sns:eu-west-1:REPLACE_PROD_ACCOUNT_ID:REPLACE_ONCALL_TOPIC"]

tags = {
  Environment = "production"
  Owner       = "messaging"
}
