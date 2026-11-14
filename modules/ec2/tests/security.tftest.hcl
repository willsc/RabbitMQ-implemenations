mock_provider "aws" {
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_data "aws_region" {
    defaults = { region = "eu-west-2" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws", dns_suffix = "amazonaws.com" }
  }
  mock_data "aws_vpc" {
    defaults = { enable_dns_support = true, enable_dns_hostnames = true }
  }
  mock_data "aws_ami" {
    defaults = { architecture = "x86_64", tags = { RabbitMQOS = "ubuntu-26.04", RabbitMQAMIContract = "1" } }
  }
}

variables {
  name              = "test-rabbit"
  vpc_id            = "vpc-0123456789abcdef0"
  private_zone_name = "rabbit.test.internal"
  nodes = {
    a = { subnet_id = "subnet-00000000000000001", ami_id = "ami-00000000000000001" }
    b = { subnet_id = "subnet-00000000000000002", ami_id = "ami-00000000000000001" }
    c = { subnet_id = "subnet-00000000000000003", ami_id = "ami-00000000000000001" }
  }
  tls_subnet_ids       = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
  tls_dns              = { zone_id = "Z0123456789", name = "rabbit.example.com" }
  tls_client_cidrs     = ["10.20.0.0/16"]
  bootstrap_secret_arn = "arn:aws:secretsmanager:eu-west-2:123456789012:secret:rabbit-AbCdEf"
  kms_key_arn          = "arn:aws:kms:eu-west-2:123456789012:key/12345678-1234-1234-1234-123456789012"
  definitions = {
    bucket = "test-rabbit-definitions", key = "definitions.json", version_id = "immutable-version"
    sha256 = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
  }
}

override_data {
  target = data.aws_subnet.node["a"]
  values = { availability_zone = "eu-west-2a", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.node["b"]
  values = { availability_zone = "eu-west-2b", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.node["c"]
  values = { availability_zone = "eu-west-2c", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.tls["subnet-00000000000000001"]
  values = { availability_zone = "eu-west-2a", vpc_id = "vpc-0123456789abcdef0" }
}
override_data {
  target = data.aws_subnet.tls["subnet-00000000000000002"]
  values = { availability_zone = "eu-west-2b", vpc_id = "vpc-0123456789abcdef0" }
}
override_data {
  target = data.aws_subnet.tls["subnet-00000000000000003"]
  values = { availability_zone = "eu-west-2c", vpc_id = "vpc-0123456789abcdef0" }
}

run "secure_defaults" {
  command = plan
  assert {
    condition     = length(aws_instance.node) == 3 && length(aws_ebs_volume.data) == 3
    error_message = "Three nodes must have independent volumes."
  }
  assert {
    condition     = alltrue([for n in aws_instance.node : n.instance_type == "r5n.2xlarge" && n.metadata_options[0].http_tokens == "required" && n.root_block_device[0].encrypted])
    error_message = "Instance sizing, IMDSv2 and root encryption must be enforced."
  }
  assert {
    condition     = length(aws_lb_listener.this) == 1 && aws_lb_listener.this["tls"].port == 5671 && aws_lb.this["tls"].internal
    error_message = "Defaults must expose only private TLS."
  }
  assert {
    condition     = alltrue([for v in aws_ebs_volume.data : v.encrypted]) && length(aws_vpc_security_group_ingress_rule.cluster) == 2
    error_message = "Encrypted local volumes and restricted clustering ports are required."
  }
}

run "public_tls_private_migration_ui" {
  command = plan
  variables {
    tls_public              = true
    tls_client_cidrs        = ["203.0.113.0/24"]
    plaintext_client_cidrs  = ["10.20.0.0/16"]
    management_dns          = { zone_id = "Z0123456789", name = "rabbit-ui.example.com" }
    management_client_cidrs = ["10.20.5.0/24"]
  }
  assert {
    condition     = !aws_lb.this["tls"].internal && aws_lb.this["plaintext"].internal && aws_lb.this["management"].internal
    error_message = "UI and plaintext must remain private when AMQPS is public."
  }
  assert {
    condition     = aws_lb_listener.this["management"].port == 443 && aws_lb_target_group.this["management"].port == 15671
    error_message = "The UI must pass HTTPS to RabbitMQ."
  }
}

run "private_plaintext_without_certificates" {
  command = plan
  variables {
    enable_tls             = false
    tls_dns                = null
    tls_subnet_ids         = []
    tls_client_cidrs       = []
    plaintext_client_cidrs = ["172.16.0.0/12"]
  }
  assert {
    condition     = length(aws_lb_listener.this) == 1 && aws_lb.this["plaintext"].internal && length(aws_cloudwatch_metric_alarm.certificate) == 0
    error_message = "Private plaintext mode must not require TLS certificates or expose public endpoints."
  }
}

run "reject_public_plaintext" {
  command = plan
  variables { plaintext_client_cidrs = ["203.0.113.0/24"] }
  expect_failures = [var.plaintext_client_cidrs]
}

run "reject_cidr_supernet" {
  command = plan
  variables { plaintext_client_cidrs = ["10.0.0.0/7"] }
  expect_failures = [var.plaintext_client_cidrs]
}

run "reject_world_tls" {
  command = plan
  variables { tls_client_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.tls_client_cidrs]
}

run "reject_same_az" {
  command = plan
  override_data {
    target = data.aws_subnet.node["b"]
    values = { availability_zone = "eu-west-2a", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
  }
  expect_failures = [aws_instance.node]
}

run "reject_unprepared_ami" {
  command = plan
  override_data {
    target = data.aws_ami.node["a"]
    values = { architecture = "x86_64", tags = { RabbitMQOS = "ubuntu-24.04" } }
  }
  expect_failures = [aws_instance.node]
}

run "monitoring_federation_and_mtls" {
  command = plan
  variables {
    monitoring_cidrs           = ["10.20.9.0/24"]
    federation_egress          = { TKY = "10.30.0.0/16", LDN = "10.40.0.0/16" }
    require_client_certificate = true
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.prometheus) == 1 && aws_vpc_security_group_ingress_rule.prometheus["10.20.9.0/24"].from_port == 15692
    error_message = "Prometheus must be reachable only from the monitoring allowlist."
  }
  assert {
    condition     = length(aws_vpc_security_group_egress_rule.federation) == 2 && alltrue([for r in aws_vpc_security_group_egress_rule.federation : r.from_port == 5671 && r.to_port == 5671])
    error_message = "Federation egress must be TLS-only and per destination."
  }
  assert {
    condition     = length(aws_cloudwatch_metric_alarm.certificate) == 3 && length(aws_cloudwatch_metric_alarm.ready) == 3
    error_message = "Each node needs readiness and certificate-expiry alarms."
  }
}

run "reject_duplicate_node_subnet" {
  command = plan
  variables {
    nodes = {
      a = { subnet_id = "subnet-00000000000000001", ami_id = "ami-00000000000000001" }
      b = { subnet_id = "subnet-00000000000000001", ami_id = "ami-00000000000000001" }
      c = { subnet_id = "subnet-00000000000000003", ami_id = "ami-00000000000000001" }
    }
  }
  expect_failures = [var.nodes]
}

run "reject_management_without_allowlist" {
  command = plan
  variables {
    management_dns = { zone_id = "Z0123456789", name = "rabbit-ui.example.com" }
  }
  expect_failures = [aws_instance.node]
}

run "reject_public_without_tls" {
  command = plan
  variables {
    enable_tls             = false
    tls_public             = true
    tls_dns                = null
    tls_subnet_ids         = []
    tls_client_cidrs       = []
    plaintext_client_cidrs = ["10.20.0.0/16"]
  }
  expect_failures = [aws_instance.node]
}

run "reject_public_management_cidr" {
  command = plan
  variables {
    management_dns          = { zone_id = "Z0123456789", name = "rabbit-ui.example.com" }
    management_client_cidrs = ["198.51.100.0/24"]
  }
  expect_failures = [var.management_client_cidrs]
}

run "staged_instance_resize" {
  command = plan
  variables {
    nodes = {
      a = { subnet_id = "subnet-00000000000000001", ami_id = "ami-00000000000000001", instance_type = "r6in.2xlarge" }
      b = { subnet_id = "subnet-00000000000000002", ami_id = "ami-00000000000000001" }
      c = { subnet_id = "subnet-00000000000000003", ami_id = "ami-00000000000000001" }
    }
  }
  assert {
    condition     = aws_instance.node["a"].instance_type == "r6in.2xlarge" && aws_instance.node["b"].instance_type == "r5n.2xlarge" && aws_instance.node["c"].instance_type == "r5n.2xlarge"
    error_message = "A per-node override must resize only that node."
  }
}

run "reject_unsupported_node_override" {
  command = plan
  variables {
    nodes = {
      a = { subnet_id = "subnet-00000000000000001", ami_id = "ami-00000000000000001", instance_type = "t3.micro" }
      b = { subnet_id = "subnet-00000000000000002", ami_id = "ami-00000000000000001" }
      c = { subnet_id = "subnet-00000000000000003", ami_id = "ami-00000000000000001" }
    }
  }
  expect_failures = [var.nodes]
}
