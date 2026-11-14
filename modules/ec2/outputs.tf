output "amqps_endpoint" {
  description = "TLS AMQP 0-9-1 endpoint with the certificate hostname."
  value       = var.enable_tls ? "amqps://${var.tls_dns.name}:5671" : null
}

output "management_url" {
  description = "Private HTTPS UI URL, or null for SSM-only access to localhost:15672."
  value       = local.management ? "https://${var.management_dns.name}" : null
}

output "plaintext_endpoint" {
  description = "Temporary private-only AMQP endpoint, or null when disabled."
  value       = local.plaintext ? "amqp://${aws_lb.this["plaintext"].dns_name}:5672" : null
}

output "nodes" {
  description = "Stable identities, instance IDs, private IPs and retained data volumes."
  value = { for k in keys(var.nodes) : k => {
    instance_id = aws_instance.node[k].id
    private_ip  = aws_network_interface.node[k].private_ip
    node_name   = local.node_names[k]
    volume_id   = aws_ebs_volume.data[k].id
  } }
}

output "target_group_arns" {
  description = "Use for controlled target deregistration during maintenance."
  value       = { for k, v in aws_lb_target_group.this : k => v.arn }
}

output "security_group_id" {
  description = "Node security group."
  value       = aws_security_group.node.id
}

output "log_group_name" {
  description = "CloudWatch log group for RabbitMQ and bootstrap logs."
  value       = aws_cloudwatch_log_group.broker.name
}
