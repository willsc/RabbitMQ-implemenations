packer {
  required_version = ">= 1.11.0"
  required_plugins {
    amazon = {
      source  = "github.com/hashicorp/amazon"
      version = ">= 1.3.0, < 2.0.0"
    }
  }
}

variable "region" {
  type    = string
  default = "eu-west-2"
}

variable "source_ami" {
  type        = string
  description = "Approved, pinned Ubuntu Server 26.04 amd64 base AMI."
}

variable "subnet_id" {
  type        = string
  description = "Build subnet reachable by the Packer runner, with package/image repository egress."
}

variable "vpc_id" {
  type = string
}

variable "builder_cidr" {
  type        = string
  description = "Runner's private IP /32; used for the temporary build-only SSH security group."
}

variable "kms_key_id" {
  type = string
}

variable "rabbitmq_image" {
  type        = string
  description = "Approved RabbitMQ 4.3 image pinned by SHA256 digest, including tag for readability."
  validation {
    condition     = can(regex("^[A-Za-z0-9./:_-]+@sha256:[a-f0-9]{64}$", var.rabbitmq_image))
    error_message = "Supply an immutable image digest, not a floating tag."
  }
}

variable "cloudwatch_deb_url" {
  type        = string
  description = "Versioned HTTPS URL for the approved amd64 CloudWatch agent .deb."
}
variable "cloudwatch_deb_sha256" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.cloudwatch_deb_sha256))
    error_message = "Provide the independently verified CloudWatch package checksum."
  }
}
variable "ssm_deb_url" {
  type        = string
  description = "Versioned HTTPS URL for the approved amd64 SSM agent .deb."
}
variable "ssm_deb_sha256" {
  type = string
  validation {
    condition     = can(regex("^[a-f0-9]{64}$", var.ssm_deb_sha256))
    error_message = "Provide the independently verified SSM package checksum."
  }
}

source "amazon-ebs" "rabbitmq" {
  region                                = var.region
  source_ami                            = var.source_ami
  instance_type                         = "m7i.large"
  ssh_username                          = "ubuntu"
  ssh_interface                         = "private_ip"
  subnet_id                             = var.subnet_id
  vpc_id                                = var.vpc_id
  associate_public_ip_address           = false
  temporary_security_group_source_cidrs = [var.builder_cidr]
  ami_name                              = "rabbitmq-ubuntu-26-04-${formatdate("YYYYMMDD-hhmmss", timestamp())}"
  encrypt_boot                          = true
  kms_key_id                            = var.kms_key_id
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  launch_block_device_mappings {
    device_name           = "/dev/sda1"
    volume_size           = 30
    volume_type           = "gp3"
    delete_on_termination = true
    encrypted             = true
  }
  tags = {
    Name                = "rabbitmq-ubuntu-26.04"
    RabbitMQOS          = "ubuntu-26.04"
    RabbitMQAMIContract = "1"
    RabbitMQImage       = var.rabbitmq_image
  }
}

build {
  sources = ["source.amazon-ebs.rabbitmq"]
  provisioner "shell" {
    script = "${path.root}/provision.sh"
    environment_vars = [
      "RABBITMQ_IMAGE=${var.rabbitmq_image}",
      "CW_URL=${var.cloudwatch_deb_url}",
      "CW_SHA=${var.cloudwatch_deb_sha256}",
      "SSM_URL=${var.ssm_deb_url}",
      "SSM_SHA=${var.ssm_deb_sha256}"
    ]
    execute_command = "chmod +x {{ .Path }}; sudo {{ .Vars }} {{ .Path }}"
  }
  post-processor "manifest" {
    output     = "${path.root}/manifest.json"
    strip_path = true
  }
}
