data "aws_region" "current" {}
data "aws_partition" "current" {}

data "aws_vpc" "this" {
  id = var.vpc_id
}

data "aws_subnet" "node" {
  for_each = var.nodes
  id       = each.value.subnet_id
}

data "aws_subnet" "tls" {
  for_each = var.tls_subnet_ids
  id       = each.value
}

data "aws_ami" "node" {
  for_each = var.nodes
  owners   = var.ami_owner_ids
  filter {
    name   = "image-id"
    values = [each.value.ami_id]
  }
}

locals {
  tags         = merge(var.tags, { ManagedBy = "Terraform", Service = "RabbitMQ", Cluster = var.name })
  plaintext    = length(var.plaintext_client_cidrs) > 0
  management   = var.management_dns != null
  tls_material = var.enable_tls || local.management || length(var.federation_egress) > 0
  node_names   = { for key in keys(var.nodes) : key => "rabbit@${key}.${var.private_zone_name}" }
  listeners    = merge(var.enable_tls ? { tls = 5671 } : {}, local.plaintext ? { plaintext = 5672 } : {}, local.management ? { management = 15671 } : {})
  attachments  = { for pair in setproduct(keys(local.listeners), keys(var.nodes)) : "${pair[0]}-${pair[1]}" => { listener = pair[0], node = pair[1] } }
}

resource "aws_route53_zone" "cluster" {
  name = var.private_zone_name
  vpc {
    vpc_id = var.vpc_id
  }
  tags = local.tags
}

resource "aws_network_interface" "node" {
  for_each        = var.nodes
  subnet_id       = each.value.subnet_id
  security_groups = [aws_security_group.node.id]
  tags            = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_route53_record" "node" {
  for_each = var.nodes
  zone_id  = aws_route53_zone.cluster.zone_id
  name     = "${each.key}.${var.private_zone_name}"
  type     = "A"
  ttl      = 30
  records  = [aws_network_interface.node[each.key].private_ip]
}

resource "aws_ebs_volume" "data" {
  for_each          = var.nodes
  availability_zone = data.aws_subnet.node[each.key].availability_zone
  type              = "gp3"
  size              = var.data_volume.size
  iops              = var.data_volume.iops
  throughput        = var.data_volume.throughput
  encrypted         = true
  kms_key_id        = var.kms_key_arn
  tags              = merge(local.tags, { Name = "${var.name}-${each.key}-data" })
  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_cloudwatch_log_group" "broker" {
  name              = "/rabbitmq/${var.name}"
  retention_in_days = 30
  kms_key_id        = var.log_kms_key_arn
  tags              = local.tags
}

resource "aws_instance" "node" {
  for_each                = var.nodes
  ami                     = each.value.ami_id
  instance_type           = coalesce(each.value.instance_type, var.instance_type)
  iam_instance_profile    = aws_iam_instance_profile.node.name
  ebs_optimized           = true
  monitoring              = true
  disable_api_termination = each.value.termination_protection
  primary_network_interface {
    network_interface_id = aws_network_interface.node[each.key].id
  }
  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }
  root_block_device {
    volume_type           = "gp3"
    volume_size           = 30
    encrypted             = true
    kms_key_id            = var.kms_key_arn
    delete_on_termination = true
  }

  user_data_base64 = base64gzip(templatefile("${path.module}/templates/cloud-init.sh.tftpl", {
    config = base64encode(jsonencode({
      region          = data.aws_region.current.region
      cluster         = var.name
      node_key        = each.key
      node_name       = local.node_names[each.key]
      node_names      = local.node_names
      volume_id       = aws_ebs_volume.data[each.key].id
      secret_arn      = var.bootstrap_secret_arn
      definitions     = var.definitions
      tls_names       = concat(var.enable_tls ? [try(var.tls_dns.name, "")] : [], local.management ? [var.management_dns.name] : [])
      enable_tls      = var.enable_tls
      management      = local.management
      tls_material    = local.tls_material
      plaintext       = local.plaintext
      require_mtls    = var.require_client_certificate
      allow_transient = var.allow_transient_nonexclusive_queues
      log_group       = aws_cloudwatch_log_group.broker.name
    }))
    runtime = filebase64("${path.module}/runtime/bootstrap.py")
    health  = filebase64("${path.module}/runtime/health.py")
  }))

  # Template changes are intentionally staged: see the one-node replacement runbook.
  lifecycle {
    ignore_changes = [user_data_base64]
    precondition {
      condition     = (var.enable_tls && var.tls_dns != null) || (!var.enable_tls && !var.tls_public && local.plaintext)
      error_message = "TLS requires a certificate DNS name. Disabling TLS requires private plaintext access and tls_public=false."
    }
    precondition {
      condition     = local.management == (length(var.management_client_cidrs) > 0)
      error_message = "Set both management_dns and private management_client_cidrs, or neither (SSM-only UI)."
    }
    precondition {
      condition     = data.aws_vpc.this.enable_dns_support && data.aws_vpc.this.enable_dns_hostnames
      error_message = "The VPC must enable DNS support and DNS hostnames."
    }
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.node : s.availability_zone])) == 3 && alltrue([for s in data.aws_subnet.node : s.vpc_id == var.vpc_id && !s.map_public_ip_on_launch])
      error_message = "Use private node subnets in the same VPC, across three distinct AZs."
    }
    precondition {
      condition     = data.aws_ami.node[each.key].architecture == "x86_64" && try(data.aws_ami.node[each.key].tags["RabbitMQOS"] == "ubuntu-26.04" && data.aws_ami.node[each.key].tags["RabbitMQAMIContract"] == "1", false)
      error_message = "Use a trusted x86_64 Ubuntu 26.04 AMI built by the supplied Packer template (contract 1)."
    }
  }
  depends_on = [aws_route53_record.node, aws_iam_role_policy.node, aws_iam_role_policy_attachment.ssm, aws_vpc_security_group_ingress_rule.cluster, aws_vpc_security_group_egress_rule.cluster]
  tags       = merge(local.tags, { Name = "${var.name}-${each.key}" })
}

resource "aws_volume_attachment" "data" {
  for_each                       = var.nodes
  device_name                    = "/dev/sdf"
  volume_id                      = aws_ebs_volume.data[each.key].id
  instance_id                    = aws_instance.node[each.key].id
  stop_instance_before_detaching = true
}
