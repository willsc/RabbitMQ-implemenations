data "aws_subnet" "broker" {
  for_each = var.subnet_ids
  id       = each.value
}

locals {
  tags = merge(var.tags, { ManagedBy = "Terraform", Service = "RabbitMQ", Name = var.name })
  management_rules = { for pair in setproduct(var.management_cidrs, [443, 15671]) : "${pair[0]}:${pair[1]}" => {
    cidr = pair[0]
    port = pair[1]
  } }
}

resource "aws_security_group" "broker" {
  name_prefix = "${var.name}-"
  description = "Private RabbitMQ: TLS clients and HTTPS management only"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "client_cidr" {
  for_each          = var.client_cidrs
  security_group_id = aws_security_group.broker.id
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 5671
  to_port           = 5671
  description       = "AMQP 0-9-1 over TLS"
}

resource "aws_vpc_security_group_ingress_rule" "client_sg" {
  for_each                     = var.client_security_group_ids
  security_group_id            = aws_security_group.broker.id
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 5671
  to_port                      = 5671
  description                  = "AMQP 0-9-1 over TLS"
}

resource "aws_vpc_security_group_ingress_rule" "management" {
  for_each          = local.management_rules
  security_group_id = aws_security_group.broker.id
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port
  to_port           = each.value.port
  description       = "Restricted RabbitMQ HTTPS management"
}

resource "aws_mq_configuration" "broker" {
  name           = var.name
  description    = "RabbitMQ migration compatibility and heartbeat settings"
  engine_type    = "RabbitMQ"
  engine_version = var.engine_version
  data = join("\n", [
    "heartbeat = 60",
    "consumer_timeout = 1800000",
    "management.restrictions.operator_policy_changes.disabled = true"
  ])
  tags = local.tags
}

resource "aws_mq_broker" "this" {
  broker_name                = var.name
  engine_type                = "RabbitMQ"
  engine_version             = var.engine_version
  host_instance_type         = var.instance_type
  deployment_mode            = "CLUSTER_MULTI_AZ"
  publicly_accessible        = false
  subnet_ids                 = sort(tolist(var.subnet_ids))
  security_groups            = [aws_security_group.broker.id]
  auto_minor_version_upgrade = true
  apply_immediately          = false
  resource_share_arns        = var.resource_share_arns

  user {
    username = var.admin_username
    password = var.admin_password
  }

  encryption_options {
    use_aws_owned_key = false
    kms_key_id        = var.kms_key_arn
  }

  configuration {
    id       = aws_mq_configuration.broker.id
    revision = aws_mq_configuration.broker.latest_revision
  }

  logs {
    general = true
  }

  maintenance_window_start_time {
    day_of_week = var.maintenance_window.day
    time_of_day = var.maintenance_window.time
    time_zone   = "UTC"
  }

  lifecycle {
    prevent_destroy = true
    precondition {
      condition     = length(distinct([for s in data.aws_subnet.broker : s.availability_zone])) == 3 && alltrue([for s in data.aws_subnet.broker : s.vpc_id == var.vpc_id && !s.map_public_ip_on_launch])
      error_message = "Broker subnets must belong to the supplied VPC, span three AZs, and disable public IP assignment."
    }
    precondition {
      condition     = length(var.client_cidrs) + length(var.client_security_group_ids) > 0
      error_message = "Provide at least one TLS client CIDR or security group."
    }
  }
  tags = local.tags
}

resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.name}-memory"
  alarm_description   = "Cluster-aggregate RabbitMQ memory use is above ${var.memory_alarm_percent}% of the aggregate limit; one node can be higher"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 3
  threshold           = var.memory_alarm_percent
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  metric_query {
    id          = "used"
    return_data = false
    metric {
      metric_name = "RabbitMQMemUsed"
      namespace   = "AWS/AmazonMQ"
      period      = 60
      stat        = "Maximum"
      dimensions  = { Broker = aws_mq_broker.this.broker_name }
    }
  }
  metric_query {
    id          = "limit"
    return_data = false
    metric {
      metric_name = "RabbitMQMemLimit"
      namespace   = "AWS/AmazonMQ"
      period      = 60
      stat        = "Minimum"
      dimensions  = { Broker = aws_mq_broker.this.broker_name }
    }
  }
  metric_query {
    id          = "percent"
    expression  = "100 * used / limit"
    label       = "Memory percent of limit"
    return_data = true
  }
  tags = local.tags
}

# Broker-dimension RabbitMQDiskFree is the SUM of the three nodes, so it cannot
# detect one node running out of disk. Query the node-level series and alarm on
# the worst node instead (CloudWatch Metrics Insights, single aggregated series).
resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${var.name}-node-disk"
  alarm_description   = "At least one RabbitMQ node has less than ${var.node_disk_free_alarm_gib} GiB disk free"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 3
  threshold           = var.node_disk_free_alarm_gib * 1073741824
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  metric_query {
    id          = "worst"
    expression  = "SELECT MIN(RabbitMQDiskFree) FROM SCHEMA(\"AWS/AmazonMQ\", Broker, Node) WHERE Broker = '${aws_mq_broker.this.broker_name}'"
    label       = "Lowest node free disk"
    period      = 60
    return_data = true
  }
  tags = local.tags
}
