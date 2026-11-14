terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.54, < 7.0" }
  }

  # Configure an encrypted, locked remote backend before the first apply, e.g.:
  # backend "s3" {
  #   bucket       = "REPLACE-terraform-state"
  #   key          = "messaging/rabbitmq-amazon-mq/terraform.tfstate"
  #   region       = "eu-west-2"
  #   encrypt      = true
  #   kms_key_id   = "arn:aws:kms:eu-west-2:123456789012:key/REPLACE"
  #   use_lockfile = true # Terraform >= 1.10; use dynamodb_table on 1.9
  # }
}

provider "aws" {
  region = var.region
}

module "rabbitmq" {
  source = "../../modules/amazon-mq"

  name                      = var.name
  vpc_id                    = var.vpc_id
  subnet_ids                = var.subnet_ids
  engine_version            = var.engine_version
  instance_type             = var.instance_type
  admin_username            = var.admin_username
  admin_password            = var.admin_password
  client_cidrs              = var.client_cidrs
  client_security_group_ids = var.client_security_group_ids
  management_cidrs          = var.management_cidrs
  kms_key_arn               = var.kms_key_arn
  resource_share_arns       = var.resource_share_arns
  maintenance_window        = var.maintenance_window
  memory_alarm_percent      = var.memory_alarm_percent
  node_disk_free_alarm_gib  = var.node_disk_free_alarm_gib
  alarm_action_arns         = var.alarm_action_arns
  tags                      = var.tags
}

output "amqps_endpoints" { value = module.rabbitmq.amqps_endpoints }
output "management_urls" { value = module.rabbitmq.console_urls }
output "private_federation_resources" { value = module.rabbitmq.shared_resources }
