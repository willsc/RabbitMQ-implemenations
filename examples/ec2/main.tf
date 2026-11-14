terraform {
  required_version = ">= 1.9, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.54, < 7.0" }
  }

  # Configure an encrypted, locked remote backend before the first apply, e.g.:
  # backend "s3" {
  #   bucket       = "REPLACE-terraform-state"
  #   key          = "messaging/rabbitmq-ec2/terraform.tfstate"
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
  source = "../../modules/ec2"

  name                                = var.name
  vpc_id                              = var.vpc_id
  nodes                               = var.nodes
  ami_owner_ids                       = var.ami_owner_ids
  instance_type                       = var.instance_type
  private_zone_name                   = coalesce(var.private_zone_name, "${var.name}.internal")
  enable_tls                          = var.enable_tls
  tls_dns                             = var.tls_dns
  tls_public                          = var.tls_public
  tls_subnet_ids                      = var.tls_subnet_ids
  tls_client_cidrs                    = var.tls_client_cidrs
  require_client_certificate          = var.require_client_certificate
  plaintext_client_cidrs              = var.plaintext_client_cidrs
  management_dns                      = var.management_dns
  management_client_cidrs             = var.management_client_cidrs
  monitoring_cidrs                    = var.monitoring_cidrs
  bootstrap_secret_arn                = var.bootstrap_secret_arn
  definitions                         = var.definitions
  kms_key_arn                         = var.kms_key_arn
  secret_kms_key_arns                 = var.secret_kms_key_arns
  log_kms_key_arn                     = var.log_kms_key_arn
  data_volume                         = var.data_volume
  federation_egress                   = var.federation_egress
  https_egress_cidrs                  = var.https_egress_cidrs
  allow_transient_nonexclusive_queues = var.allow_transient_nonexclusive_queues
  nlb_deletion_protection             = var.nlb_deletion_protection
  alarm_action_arns                   = var.alarm_action_arns
  tags                                = var.tags
}

output "rabbitmq" {
  value = {
    amqps      = module.rabbitmq.amqps_endpoint
    amqp       = module.rabbitmq.plaintext_endpoint
    management = module.rabbitmq.management_url
    nodes      = module.rabbitmq.nodes
    targets    = module.rabbitmq.target_group_arns
  }
}
