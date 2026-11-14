output "broker_id" {
  description = "Amazon MQ broker ID."
  value       = aws_mq_broker.this.id
}

output "broker_arn" {
  description = "Amazon MQ broker ARN."
  value       = aws_mq_broker.this.arn
}

output "amqps_endpoints" {
  description = "Native AWS hostnames to preserve TLS hostname verification."
  value       = distinct(flatten([for i in aws_mq_broker.this.instances : [for e in i.endpoints : e if startswith(e, "amqps://")]]))
}

output "console_urls" {
  description = "Private HTTPS management URLs."
  value       = distinct([for i in aws_mq_broker.this.instances : i.console_url])
}

output "security_group_id" {
  description = "Broker security group."
  value       = aws_security_group.broker.id
}

output "shared_resources" {
  description = "Private resource DNS names and association status used by federation."
  value       = aws_mq_broker.this.shared_resources
}
