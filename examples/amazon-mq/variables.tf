# Pass-through of every modules/amazon-mq input. Defaults mirror the module; see
# modules/amazon-mq/variables.tf for validation rules and full descriptions.

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "name" {
  description = "Unique broker name."
  type        = string
}

variable "vpc_id" {
  description = "Existing VPC with private connectivity to clients."
  type        = string
}

variable "subnet_ids" {
  description = "Exactly three private subnets in three distinct availability zones."
  type        = set(string)
}

variable "engine_version" {
  description = "Amazon MQ RabbitMQ major.minor (4.2 or 4.3)."
  type        = string
  default     = "4.3"
}

variable "instance_type" {
  description = "mq.m7g broker size."
  type        = string
  default     = "mq.m7g.2xlarge"
}

variable "admin_username" {
  description = "Bootstrap administrator; manage subsequent users through the RabbitMQ API."
  type        = string
  default     = "bootstrap-admin"
}

variable "admin_password" {
  description = "Bootstrap password. Supply via TF_VAR_admin_password. Stored in Terraform state by aws_mq_broker; protect state."
  type        = string
  sensitive   = true
}

variable "client_cidrs" {
  description = "IPv4 CIDRs allowed to connect using AMQPS on 5671."
  type        = set(string)
  default     = []
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
}

variable "memory_alarm_percent" {
  description = "Cluster-aggregate memory alarm threshold, percent of the aggregate limit."
  type        = number
  default     = 70
}

variable "node_disk_free_alarm_gib" {
  description = "Alarm when the node with the least free disk drops below this many GiB."
  type        = number
  default     = 10
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
