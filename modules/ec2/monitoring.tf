resource "aws_cloudwatch_metric_alarm" "ready" {
  for_each            = var.nodes
  alarm_name          = "${var.name}-${each.key}-not-ready"
  alarm_description   = "Broker readiness probe failed or stopped reporting"
  namespace           = "RabbitMQ/EC2"
  metric_name         = "Ready"
  dimensions          = { Cluster = var.name, Node = each.key }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 1
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "status" {
  for_each            = var.nodes
  alarm_name          = "${var.name}-${each.key}-ec2-status"
  namespace           = "AWS/EC2"
  metric_name         = "StatusCheckFailed"
  dimensions          = { InstanceId = aws_instance.node[each.key].id }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  comparison_operator = "GreaterThanThreshold"
  threshold           = 0
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "capacity" {
  for_each            = local.listeners
  alarm_name          = "${var.name}-${each.key}-capacity"
  alarm_description   = "Fewer than three healthy nodes; investigate reduced failure tolerance"
  namespace           = "AWS/NetworkELB"
  metric_name         = "HealthyHostCount"
  dimensions          = { LoadBalancer = aws_lb.this[each.key].arn_suffix, TargetGroup = aws_lb_target_group.this[each.key].arn_suffix }
  statistic           = "Minimum"
  period              = 60
  evaluation_periods  = 3
  comparison_operator = "LessThanThreshold"
  threshold           = 3
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  tags                = local.tags
}

resource "aws_cloudwatch_metric_alarm" "certificate" {
  for_each            = local.tls_material ? var.nodes : {}
  alarm_name          = "${var.name}-${each.key}-certificate-expiry"
  namespace           = "RabbitMQ/EC2"
  metric_name         = "CertificateDaysRemaining"
  dimensions          = { Cluster = var.name, Node = each.key }
  statistic           = "Minimum"
  period              = 300
  evaluation_periods  = 1
  comparison_operator = "LessThanThreshold"
  threshold           = 21
  treat_missing_data  = "breaching"
  alarm_actions       = var.alarm_action_arns
  ok_actions          = var.alarm_action_arns
  tags                = local.tags
}
