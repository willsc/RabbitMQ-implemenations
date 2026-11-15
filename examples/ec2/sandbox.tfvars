# SANDBOX — RabbitMQ 4.4 on EC2, account 490228638978, eu-west-1 (Ireland)
#
# Not production (see production.tfvars). There is no VPN and there are no external client
# ranges, so nothing is exposed to the internet:
#   * AMQPS 5671 is on an INTERNAL NLB, reachable only from inside the VPC (172.31.0.0/16).
#   * Plain AMQP 5672 and the HTTPS management NLB are off.
#   * From a laptop, use SSM port forwarding (modules/ec2/README.md, "Accessing a node"):
#       aws ssm start-session --target <instance-id> \
#         --document-name AWS-StartPortForwardingSession \
#         --parameters '{"portNumber":["15672"],"localPortNumber":["15672"]}'
#
#   cd examples/ec2
#   terraform init
#   terraform plan -var-file=sandbox.tfvars -out=sandbox.tfplan
#
# BEFORE THE FIRST PLAN (checked 2026-11-15: none of these exist in the account yet):
#   1. The three subnets below are the default VPC's subnets. They auto-assign public IPs,
#      which the module rejects ("Use private node subnets..."). Turn that off:
#        aws ec2 modify-subnet-attribute --no-map-public-ip-on-launch --subnet-id <id>
#   2. Nodes get no public IP and the VPC has no NAT gateway, so they need VPC endpoints:
#      S3 (gateway), secretsmanager, logs, monitoring, ssm, ssmmessages, ec2messages.
#   3. Bake the AMI with Packer, create the bootstrap secret, publish the definitions object
#      and create the private hosted zone used by tls_dns (docs/operations.md#first-deployment-ec2).
# REPLACE_ values are deliberately invalid, so `terraform plan` fails until they are filled in.

name   = "sbx-rabbit"
region = "eu-west-1"
vpc_id = "vpc-052869dcdcbbddf14" # default VPC, 172.31.0.0/16, DNS support + hostnames on

# Brokers: one subnet per AZ. Termination protection off so the sandbox can be torn down.
nodes = {
  a = { subnet_id = "subnet-02e248c5020370d77", ami_id = "ami-REPLACE_PACKER_AMI", termination_protection = false } # eu-west-1a, 172.31.0.0/20
  b = { subnet_id = "subnet-0a059cc7141f96225", ami_id = "ami-REPLACE_PACKER_AMI", termination_protection = false } # eu-west-1b, 172.31.16.0/20
  c = { subnet_id = "subnet-09fe45cd17a789a9c", ami_id = "ami-REPLACE_PACKER_AMI", termination_protection = false } # eu-west-1c, 172.31.32.0/20
}

# Packer bakes in this account.
ami_owner_ids = ["self"]

# Smaller than production (r5n.2xlarge) to keep sandbox cost down; same family. Offered in
# all three AZs (checked 2026-11-15).
instance_type = "r5n.large"

# Node identities rabbit@{a,b,c}.sbx-rabbit.internal (zone created by the module).
private_zone_name = "sbx-rabbit.internal"

# ---------------------------------------------------------------------------
# Client AMQPS 5671: internal NLB in the same three subnets, VPC clients only.
# ---------------------------------------------------------------------------
enable_tls       = true
tls_public       = false
tls_subnet_ids   = ["subnet-02e248c5020370d77", "subnet-0a059cc7141f96225", "subnet-09fe45cd17a789a9c"]
tls_client_cidrs = ["172.31.0.0/16"]

# Existing Route 53 hosted zone (none exists yet). A private zone associated with this VPC
# is enough, e.g. sandbox.internal. Do not use sbx-rabbit.internal; the module creates that.
# The bootstrap secret's certificate must cover this name (a self-signed CA is fine here).
tls_dns = { zone_id = "REPLACE_PRIVATE_ZONE_ID", name = "amqps.sandbox.internal" }

require_client_certificate = false

# Off: no plain AMQP NLB, no HTTPS UI NLB (use SSM), no Prometheus scrapers.
plaintext_client_cidrs  = []
management_dns          = null
management_client_cidrs = []
monitoring_cidrs        = []

# ---------------------------------------------------------------------------
# Secrets, definitions and encryption
# ---------------------------------------------------------------------------
# JSON: erlang_cookie, ca_certificate_pem, certificate_pem, private_key_pem
# (modules/ec2/README.md#runtime-secret). Full ARN including the random 6-character suffix.
bootstrap_secret_arn = "arn:aws:secretsmanager:eu-west-1:490228638978:secret:sbx-rabbit/bootstrap-REPLACE"

# Output of scripts/prepare_definitions.py in a versioned, public-access-blocked bucket.
definitions = {
  bucket     = "REPLACE_SANDBOX_DEFINITIONS_BUCKET"
  key        = "rabbitmq/sbx-rabbit/definitions.json"
  version_id = "REPLACE_S3_VERSION_ID"
  sha256     = "REPLACE_64_HEX_SHA256"
}

# AWS-managed aws/ebs key in this account, instead of a customer key.
kms_key_arn = "arn:aws:kms:eu-west-1:490228638978:key/7675cf6d-0504-4c8f-afff-920b550965db"

# Empty while the secret uses aws/secretsmanager and the bucket uses SSE-S3. Add customer
# key ARNs here if you encrypt either with one.
secret_kms_key_arns = []
log_kms_key_arn     = null

# ---------------------------------------------------------------------------
# Egress
# ---------------------------------------------------------------------------
# No TKY/LDN upstreams are reachable from this account.
federation_egress = {}

# AWS APIs over HTTPS (VPC endpoints are inside 172.31.0.0/16; S3 gateway uses public ranges).
https_egress_cidrs = ["0.0.0.0/0"]

allow_transient_nonexclusive_queues = false

# ---------------------------------------------------------------------------
# Protection and alerting
# ---------------------------------------------------------------------------
# Off for the sandbox. The data volumes keep prevent_destroy=true in the module, so
# `terraform destroy` still stops at them (modules/ec2/README.md).
nlb_deletion_protection = false

# No SNS topic in this account yet; alarms are created without actions.
alarm_action_arns = []

tags = {
  Environment = "sandbox"
  Owner       = "messaging"
}
