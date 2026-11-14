variable "name" {
  description = "Cluster name, also used for DNS, NLB names and metric dimensions."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,19}$", var.name))
    error_message = "Use 3-20 lowercase letters, digits or hyphens, starting with a letter."
  }
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
  validation {
    condition     = toset(keys(var.nodes)) == toset(["a", "b", "c"]) && length(distinct([for n in var.nodes : n.subnet_id])) == 3
    error_message = "Provide exactly a, b and c, each in a distinct private subnet."
  }
  validation {
    condition     = alltrue([for n in var.nodes : n.instance_type == null || can(regex("^(r5n|r5dn|r6in|r7iz|m6in|c6in)\\.", n.instance_type))])
    error_message = "Per-node instance_type overrides must use a supported network-capable x86_64 family."
  }
}

variable "ami_owner_ids" {
  description = "Trusted AMI owners. The supplied Packer build produces an AMI owned by self."
  type        = list(string)
  default     = ["self"]
}

variable "instance_type" {
  description = "Network-optimised x86_64 EC2 size; benchmark at peak with one node unavailable. Changing it stops/starts every node together; resize through per-node nodes[*].instance_type overrides instead."
  type        = string
  default     = "r5n.2xlarge"
  validation {
    condition     = can(regex("^(r5n|r5dn|r6in|r7iz|m6in|c6in)\\.", var.instance_type))
    error_message = "Choose a supported network-capable x86_64 instance family."
  }
}

variable "private_zone_name" {
  description = "Dedicated private hosted zone created by this module, e.g. rmq.prod.internal."
  type        = string
  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.private_zone_name))
    error_message = "Provide a lowercase DNS zone without a trailing dot."
  }
}

variable "tls_dns" {
  description = "Existing hosted zone and client DNS name. The secret certificate must cover this name."
  type        = object({ zone_id = string, name = string })
  default     = null
  validation {
    condition     = var.tls_dns == null || can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.tls_dns.name))
    error_message = "Use a lowercase DNS hostname without a trailing dot."
  }
}

variable "enable_tls" {
  description = "Enable AMQPS 5671. Disabling it requires private plaintext clients and forbids a public endpoint."
  type        = bool
  default     = true
}

variable "management_dns" {
  description = "Optional private HTTPS UI DNS record. Requires management_client_cidrs and a certificate covering this name."
  type        = object({ zone_id = string, name = string })
  default     = null
  validation {
    condition     = var.management_dns == null || can(regex("^[a-z0-9][a-z0-9.-]+\\.[a-z]{2,}$", var.management_dns.name))
    error_message = "Use a lowercase DNS hostname without a trailing dot."
  }
}

variable "management_client_cidrs" {
  description = "RFC1918 administrator ranges allowed to the optional private HTTPS UI on 443."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([for c in var.management_client_cidrs : try(
      (split(".", cidrhost(c, 0))[0] == "10" && tonumber(split("/", c)[1]) >= 8) ||
      (split(".", cidrhost(c, 0))[0] == "172" && tonumber(split(".", cidrhost(c, 0))[1]) >= 16 && tonumber(split(".", cidrhost(c, 0))[1]) <= 31 && tonumber(split("/", c)[1]) >= 12) ||
    (startswith(cidrhost(c, 0), "192.168.") && tonumber(split("/", c)[1]) >= 16), false)])
    error_message = "The UI allowlist must contain only RFC1918 CIDRs."
  }
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
  validation {
    condition     = var.enable_tls ? length(var.tls_subnet_ids) == 3 : length(var.tls_subnet_ids) == 0
    error_message = "Provide three distinct NLB subnet IDs."
  }
}

variable "tls_client_cidrs" {
  description = "Explicit IPv4 allowlist for TLS clients; no unrestricted public ingress."
  type        = set(string)
  default     = []
  validation {
    condition     = (!var.enable_tls || length(var.tls_client_cidrs) > 0) && alltrue([for c in var.tls_client_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Provide nonempty, specific IPv4 CIDRs; 0.0.0.0/0 is forbidden."
  }
}

variable "plaintext_client_cidrs" {
  description = "RFC1918 IPv4 ranges for temporary AMQP 5672 access. Empty disables both listener and internal migration NLB."
  type        = set(string)
  default     = []
  validation {
    condition = alltrue([for c in var.plaintext_client_cidrs : try(
      (split(".", cidrhost(c, 0))[0] == "10" && tonumber(split("/", c)[1]) >= 8) ||
      (split(".", cidrhost(c, 0))[0] == "172" && tonumber(split(".", cidrhost(c, 0))[1]) >= 16 && tonumber(split(".", cidrhost(c, 0))[1]) <= 31 && tonumber(split("/", c)[1]) >= 12) ||
    (startswith(cidrhost(c, 0), "192.168.") && tonumber(split("/", c)[1]) >= 16), false)])
    error_message = "Plaintext access must be contained within RFC1918 ranges: 10/8, 172.16/12 or 192.168/16."
  }
}

variable "monitoring_cidrs" {
  description = "Trusted private monitoring ranges allowed to scrape Prometheus on 15692."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.monitoring_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Use specific IPv4 CIDRs."
  }
}

variable "bootstrap_secret_arn" {
  description = "Existing Secrets Manager secret containing Erlang cookie and PEM TLS material. Fetched only by instances."
  type        = string
  validation {
    condition     = can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:", var.bootstrap_secret_arn))
    error_message = "Supply a Secrets Manager secret ARN."
  }
}

variable "definitions" {
  description = "Immutable, versioned S3 definitions object; no credentials enter Terraform state."
  type = object({
    bucket     = string
    key        = string
    version_id = string
    sha256     = string
  })
  validation {
    condition     = var.definitions.version_id != "" && var.definitions.version_id != "null" && can(regex("^[a-f0-9]{64}$", var.definitions.sha256))
    error_message = "Require a non-null S3 VersionId and a lowercase SHA-256 checksum."
  }
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
  description = "Per-node encrypted gp3 storage; this is local to each node, never shared."
  type = object({
    size       = optional(number, 100)
    iops       = optional(number, 3000)
    throughput = optional(number, 125)
  })
  default = {}
  validation {
    condition     = var.data_volume.size >= 40 && var.data_volume.iops >= 3000 && var.data_volume.iops <= 16000 && var.data_volume.throughput >= 125 && var.data_volume.throughput <= 1000 && var.data_volume.throughput <= var.data_volume.iops / 4
    error_message = "Use gp3 >=40 GiB, 3000-16000 IOPS, 125-1000 MiB/s, and throughput <= IOPS/4."
  }
}

variable "federation_egress" {
  description = "Outbound TLS 5671 destinations for TKY/LDN federation, keyed by descriptive name."
  type        = map(string)
  default     = {}
  validation {
    condition     = alltrue([for c in values(var.federation_egress) : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Provide specific IPv4 destination CIDRs for federation."
  }
}

variable "https_egress_cidrs" {
  description = "HTTPS destinations for AWS APIs, S3, SSM and logs. Narrow to endpoints when available."
  type        = set(string)
  default     = ["0.0.0.0/0"]
  validation {
    condition     = length(var.https_egress_cidrs) > 0 && alltrue([for c in var.https_egress_cidrs : can(cidrnetmask(c))])
    error_message = "Provide at least one valid IPv4 CIDR."
  }
}

variable "allow_transient_nonexclusive_queues" {
  description = "Explicit migration opt-in for RabbitMQ 4.3's deprecated transient non-exclusive queues."
  type        = bool
  default     = false
}

variable "require_client_certificate" {
  description = "Require a client certificate trusted by ca_certificate_pem, in addition to RabbitMQ authentication."
  type        = bool
  default     = false
}

variable "nlb_deletion_protection" {
  description = "Protect load balancers from accidental deletion; disable only for planned decommissioning."
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
