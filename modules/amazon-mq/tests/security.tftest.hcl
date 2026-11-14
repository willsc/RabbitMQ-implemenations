mock_provider "aws" {}

variables {
  name           = "test-managed-rabbit"
  vpc_id         = "vpc-0123456789abcdef0"
  subnet_ids     = ["subnet-00000000000000001", "subnet-00000000000000002", "subnet-00000000000000003"]
  client_cidrs   = ["10.20.0.0/16"]
  admin_password = "TestOnly-NotARealPassword-2026"
  kms_key_arn    = "arn:aws:kms:eu-west-2:123456789012:key/12345678-1234-1234-1234-123456789012"
}

override_data {
  target = data.aws_subnet.broker["subnet-00000000000000001"]
  values = { availability_zone = "eu-west-2a", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.broker["subnet-00000000000000002"]
  values = { availability_zone = "eu-west-2b", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}
override_data {
  target = data.aws_subnet.broker["subnet-00000000000000003"]
  values = { availability_zone = "eu-west-2c", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
}

run "secure_defaults" {
  command = plan
  assert {
    condition     = aws_mq_broker.this.engine_type == "RabbitMQ" && aws_mq_broker.this.deployment_mode == "CLUSTER_MULTI_AZ" && !aws_mq_broker.this.publicly_accessible
    error_message = "Must deploy a private three-node RabbitMQ broker."
  }
  assert {
    condition     = aws_mq_broker.this.engine_version == "4.3" && aws_mq_broker.this.host_instance_type == "mq.m7g.2xlarge"
    error_message = "RabbitMQ 4 requires the m7g family."
  }
  assert {
    condition     = !aws_mq_broker.this.apply_immediately && aws_mq_broker.this.auto_minor_version_upgrade && aws_mq_broker.this.logs[0].general && !aws_mq_broker.this.encryption_options[0].use_aws_owned_key
    error_message = "Maintenance scheduling, automatic patches, logging and CMK encryption must be configured."
  }
  assert {
    condition     = alltrue([for rule in aws_vpc_security_group_ingress_rule.client_cidr : rule.from_port == 5671 && rule.to_port == 5671])
    error_message = "AMQP must always use TLS."
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.management) == 0 && length(aws_vpc_security_group_ingress_rule.client_sg) == 0
    error_message = "No UI or extra client ingress may be opened by default."
  }
  assert {
    condition     = strcontains(one([for q in aws_cloudwatch_metric_alarm.disk.metric_query : q.expression]), "SCHEMA(\"AWS/AmazonMQ\", Broker, Node)") && aws_cloudwatch_metric_alarm.disk.threshold == 10737418240
    error_message = "The disk alarm must evaluate the worst node, not the three-node aggregate."
  }
}

run "security_group_clients_only" {
  command = plan
  variables {
    client_cidrs              = []
    client_security_group_ids = ["sg-0123456789abcdef0"]
  }
  assert {
    condition     = length(aws_vpc_security_group_ingress_rule.client_sg) == 1 && aws_vpc_security_group_ingress_rule.client_sg["sg-0123456789abcdef0"].from_port == 5671
    error_message = "Client security groups must be granted AMQPS only."
  }
}

run "reject_no_clients" {
  command = plan
  variables { client_cidrs = [] }
  expect_failures = [aws_mq_broker.this]
}

run "private_federation" {
  command = plan
  variables {
    resource_share_arns = ["arn:aws:ram:eu-west-2:123456789012:resource-share/12345678-1234-1234-1234-123456789012"]
    management_cidrs    = ["10.20.5.0/24"]
  }
  assert {
    condition     = length(aws_mq_broker.this.resource_share_arns) == 1 && length(aws_vpc_security_group_ingress_rule.management) == 2
    error_message = "Private shares and the restricted HTTPS UI must be configurable."
  }
}

run "reject_public_ingress" {
  command = plan
  variables { client_cidrs = ["0.0.0.0/0"] }
  expect_failures = [var.client_cidrs]
}

run "reject_old_instance_family" {
  command = plan
  variables { instance_type = "mq.m5.large" }
  expect_failures = [var.instance_type]
}

run "reject_same_az" {
  command = plan
  override_data {
    target = data.aws_subnet.broker["subnet-00000000000000002"]
    values = { availability_zone = "eu-west-2a", vpc_id = "vpc-0123456789abcdef0", map_public_ip_on_launch = false }
  }
  expect_failures = [aws_mq_broker.this]
}
