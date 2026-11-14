# Pass-through of every modules/ec2 input. Defaults mirror the module; see
# modules/ec2/variables.tf for validation rules and full descriptions.

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "name" {
  description = "Cluster name, also used for DNS, NLB names and metric dimensions."
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC with DNS support and DNS hostnames enabled."
  type        = string
}

variable "nodes" {
  description = "Three stable identities a/b/c. Each has a private subnet and a baked Ubuntu 26.04 AMI. Roll AMI IDs and instance_type overrides one node at a time."
  type = map(object({
    subnet_id              = string
    ami_id                 = string
    instance_type          = optional(string)
    termination_protection = optional(bool, true)
  }))
}

variable "ami_owner_ids" {
  description = "Trusted AMI owners. The supplied Packer build produces an AMI owned by self."
  type        = list(string)
  default     = ["self"]
}

variable "instance_type" {
  description = "Network-optimised x86_64 EC2 size. Changing it restarts every node together; resize through per-node overrides instead."
  type        = string
  default     = "r5n.2xlarge"
}

variable "private_zone_name" {
  description = "Dedicated private hosted zone for node names. Null uses <name>.internal."
  type        = string
  default     = null
}

variable "enable_tls" {
  description = "Enable AMQPS 5671."
  type        = bool
  default     = true
}

variable "tls_dns" {
  description = "Existing hosted zone and client DNS name. The secret certificate must cover this name."
  type        = object({ zone_id = string, name = string })
  default     = null
}

variable "tls_public" {
  description = "Expose TLS NLB to allowlisted public clients. EC2 nodes remain private."
  type        = bool
  default     = false
}

variable "tls_subnet_ids" {
  description = "Three NLB subnets in distinct AZs. Use public subnets only when tls_public is true."
  type        = set(string)
  default     = []
}

variable "tls_client_cidrs" {
  description = "Explicit IPv4 allowlist for TLS clients; no unrestricted public ingress."
  type        = set(string)
  default     = []
}

variable "require_client_certificate" {
  description = "Require a client certificate trusted by the bundle's CA, in addition to RabbitMQ authentication."
  type        = bool
  default     = false
}

variable "plaintext_client_cidrs" {
  description = "RFC1918 IPv4 ranges for temporary AMQP 5672 access. Empty disables both listener and internal migration NLB."
  type        = set(string)
  default     = []
}

variable "management_dns" {
  description = "Optional private HTTPS UI DNS record. Requires management_client_cidrs and a certificate covering this name."
  type        = object({ zone_id = string, name = string })
  default     = null
}

variable "management_client_cidrs" {
  description = "RFC1918 administrator ranges allowed to the optional private HTTPS UI on 443."
  type        = set(string)
  default     = []
}

variable "monitoring_cidrs" {
  description = "Trusted private monitoring ranges allowed to scrape Prometheus on 15692."
  type        = set(string)
  default     = []
}

variable "bootstrap_secret_arn" {
  description = "Existing Secrets Manager secret containing Erlang cookie and PEM TLS material. Fetched only by instances."
  type        = string
}

variable "definitions" {
  description = "Immutable, versioned S3 definitions object; no credentials enter Terraform state."
  type = object({
    bucket     = string
    key        = string
    version_id = string
    sha256     = string
  })
}

variable "kms_key_arn" {
  description = "Customer KMS key for root and data EBS volumes."
  type        = string
}

variable "secret_kms_key_arns" {
  description = "CMKs used by the bootstrap secret and definitions object; exact decrypt permissions."
  type        = set(string)
  default     = []
}

variable "log_kms_key_arn" {
  description = "Optional CloudWatch Logs KMS key, with permission for the regional Logs service."
  type        = string
  default     = null
}

variable "data_volume" {
  description = "Per-node encrypted gp3 storage."
  type = object({
    size       = optional(number, 100)
    iops       = optional(number, 3000)
    throughput = optional(number, 125)
  })
  default = {}
}

variable "federation_egress" {
  description = "Outbound TLS 5671 destinations for TKY/LDN federation, keyed by descriptive name."
  type        = map(string)
  default     = {}
}

variable "https_egress_cidrs" {
  description = "HTTPS destinations for AWS APIs, S3, SSM and logs. Narrow to endpoints when available."
  type        = set(string)
  default     = ["0.0.0.0/0"]
}

variable "allow_transient_nonexclusive_queues" {
  description = "Explicit migration opt-in for deprecated transient non-exclusive queues (denied by default since RabbitMQ 4.3)."
  type        = bool
  default     = false
}

variable "nlb_deletion_protection" {
  description = "Protect load balancers from accidental deletion."
  type        = bool
  default     = true
}

variable "alarm_action_arns" {
  description = "SNS topics for alarm and recovery notifications."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}
