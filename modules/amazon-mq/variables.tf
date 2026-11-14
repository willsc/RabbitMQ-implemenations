variable "name" {
  description = "Unique broker name."
  type        = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{2,39}$", var.name))
    error_message = "Use 3-40 lowercase letters, digits or hyphens, starting with a letter."
  }
}

variable "vpc_id" {
  description = "Existing VPC with private connectivity to clients."
  type        = string
}

variable "subnet_ids" {
  description = "Exactly three private subnets in three distinct availability zones."
  type        = set(string)
  validation {
    condition     = length(var.subnet_ids) == 3
    error_message = "Provide exactly three distinct subnet IDs."
  }
}

variable "engine_version" {
  description = "Amazon MQ-supported RabbitMQ major.minor; verify regional availability before deployment."
  type        = string
  default     = "4.3"
  validation {
    condition     = contains(["4.2", "4.3"], var.engine_version)
    error_message = "This module supports Amazon MQ RabbitMQ 4.2 and 4.3."
  }
}

variable "instance_type" {
  description = "RabbitMQ 4 requires mq.m7g. Benchmark this independently from EC2 r5n sizing."
  type        = string
  default     = "mq.m7g.2xlarge"
  validation {
    condition     = contains(["mq.m7g.large", "mq.m7g.xlarge", "mq.m7g.2xlarge", "mq.m7g.4xlarge", "mq.m7g.8xlarge", "mq.m7g.12xlarge", "mq.m7g.16xlarge"], var.instance_type)
    error_message = "Choose an mq.m7g instance size supported by Amazon MQ in your region."
  }
}

variable "admin_username" {
  description = "Bootstrap administrator; manage subsequent users through the RabbitMQ API."
  type        = string
  default     = "bootstrap-admin"
  validation {
    condition     = var.admin_username != "guest" && can(regex("^[A-Za-z0-9_.-]{1,100}$", var.admin_username))
    error_message = "Use a non-guest username containing letters, digits, dots, underscores or hyphens."
  }
}

variable "admin_password" {
  description = "Bootstrap password. Sensitive but stored in Terraform state by aws_mq_broker; protect state."
  type        = string
  sensitive   = true
  validation {
    condition     = length(var.admin_password) >= 12 && length(var.admin_password) <= 250 && length(distinct(split("", var.admin_password))) >= 4 && !strcontains(var.admin_password, ",")
    error_message = "Use 12-250 characters, at least four unique characters, and no commas."
  }
}

variable "client_cidrs" {
  description = "IPv4 CIDRs allowed to connect using AMQPS on 5671."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.client_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Use specific IPv4 CIDRs, never 0.0.0.0/0."
  }
}

variable "client_security_group_ids" {
  description = "Client security groups allowed on AMQPS 5671."
  type        = set(string)
  default     = []
}

variable "management_cidrs" {
  description = "Private administrator IPv4 CIDRs allowed on HTTPS 443 and 15671."
  type        = set(string)
  default     = []
  validation {
    condition     = alltrue([for c in var.management_cidrs : can(cidrnetmask(c)) && c != "0.0.0.0/0"])
    error_message = "Use specific IPv4 CIDRs."
  }
}

variable "kms_key_arn" {
  description = "Customer-managed KMS key for broker storage; key policy must allow Amazon MQ."
  type        = string
}

variable "resource_share_arns" {
  description = "Existing RAM shares of VPC Lattice resources for private outbound federation."
  type        = set(string)
  default     = []
}

variable "maintenance_window" {
  description = "UTC weekly maintenance window."
  type = object({
    day  = string
    time = string
  })
  default = { day = "SUNDAY", time = "02:00" }
  validation {
    condition     = contains(["MONDAY", "TUESDAY", "WEDNESDAY", "THURSDAY", "FRIDAY", "SATURDAY", "SUNDAY"], var.maintenance_window.day) && can(regex("^([01][0-9]|2[0-3]):[0-5][0-9]$", var.maintenance_window.time))
    error_message = "Specify an uppercase weekday and a valid HH:MM time."
  }
}

variable "memory_alarm_percent" {
  description = "Alarm when cluster-aggregate memory use exceeds this percentage of the aggregate RabbitMQ memory limit."
  type        = number
  default     = 70
  validation {
    condition     = var.memory_alarm_percent > 0 && var.memory_alarm_percent < 100
    error_message = "Use a percentage between 1 and 99."
  }
}

variable "node_disk_free_alarm_gib" {
  description = "Alarm when the node with the least free disk drops below this many GiB."
  type        = number
  default     = 10
  validation {
    condition     = var.node_disk_free_alarm_gib >= 1
    error_message = "Use at least 1 GiB."
  }
}

variable "alarm_action_arns" {
  description = "SNS topic ARNs for alarm and recovery notifications."
  type        = list(string)
  default     = []
}

variable "tags" {
  description = "Additional resource tags."
  type        = map(string)
  default     = {}
}
