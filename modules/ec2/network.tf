resource "aws_security_group" "node" {
  name_prefix = "${var.name}-nodes-"
  description = "RabbitMQ private nodes; administration uses SSM"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_security_group" "nlb" {
  for_each    = local.listeners
  name_prefix = "${var.name}-${each.key}-"
  description = "RabbitMQ ${each.key} NLB"
  vpc_id      = var.vpc_id
  tags        = local.tags
}

resource "aws_vpc_security_group_ingress_rule" "tls" {
  for_each          = var.enable_tls ? var.tls_client_cidrs : toset([])
  security_group_id = aws_security_group.nlb["tls"].id
  ip_protocol       = "tcp"
  from_port         = 5671
  to_port           = 5671
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "management" {
  for_each          = var.management_client_cidrs
  security_group_id = aws_security_group.nlb["management"].id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "plaintext" {
  for_each          = var.plaintext_client_cidrs
  security_group_id = aws_security_group.nlb["plaintext"].id
  ip_protocol       = "tcp"
  from_port         = 5672
  to_port           = 5672
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_ingress_rule" "broker" {
  for_each                     = local.listeners
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.nlb[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_egress_rule" "nlb_broker" {
  for_each                     = local.listeners
  security_group_id            = aws_security_group.nlb[each.key].id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
}

resource "aws_vpc_security_group_ingress_rule" "health" {
  for_each                     = local.listeners
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.nlb[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_egress_rule" "nlb_health" {
  for_each                     = local.listeners
  security_group_id            = aws_security_group.nlb[each.key].id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = 8080
  to_port                      = 8080
}

resource "aws_vpc_security_group_ingress_rule" "cluster" {
  for_each                     = toset(["4369", "25672"])
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
  description                  = "Erlang peer traffic only; cookie authenticated within the VPC"
}

resource "aws_vpc_security_group_egress_rule" "cluster" {
  for_each                     = toset(["4369", "25672"])
  security_group_id            = aws_security_group.node.id
  referenced_security_group_id = aws_security_group.node.id
  ip_protocol                  = "tcp"
  from_port                    = tonumber(each.value)
  to_port                      = tonumber(each.value)
}

resource "aws_vpc_security_group_egress_rule" "https" {
  for_each          = var.https_egress_cidrs
  security_group_id = aws_security_group.node.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = each.value
}

resource "aws_vpc_security_group_egress_rule" "time" {
  security_group_id = aws_security_group.node.id
  ip_protocol       = "udp"
  from_port         = 123
  to_port           = 123
  cidr_ipv4         = "169.254.169.123/32"
  description       = "Amazon Time Sync"
}

resource "aws_vpc_security_group_egress_rule" "federation" {
  for_each          = var.federation_egress
  security_group_id = aws_security_group.node.id
  ip_protocol       = "tcp"
  from_port         = 5671
  to_port           = 5671
  cidr_ipv4         = each.value
  description       = "TLS federation to ${each.key}"
}

resource "aws_vpc_security_group_ingress_rule" "prometheus" {
  for_each          = var.monitoring_cidrs
  security_group_id = aws_security_group.node.id
  ip_protocol       = "tcp"
  from_port         = 15692
  to_port           = 15692
  cidr_ipv4         = each.value
}

resource "aws_lb" "this" {
  for_each                         = local.listeners
  name                             = "${var.name}-${each.key}"
  internal                         = each.key == "tls" ? !var.tls_public : true
  load_balancer_type               = "network"
  ip_address_type                  = "ipv4"
  subnets                          = each.key == "tls" ? var.tls_subnet_ids : toset([for n in var.nodes : n.subnet_id])
  security_groups                  = [aws_security_group.nlb[each.key].id]
  enable_cross_zone_load_balancing = true
  enable_deletion_protection       = var.nlb_deletion_protection
  tags                             = local.tags
  lifecycle {
    precondition {
      condition     = !var.enable_tls || (length(distinct([for s in data.aws_subnet.tls : s.availability_zone])) == 3 && alltrue([for s in data.aws_subnet.tls : s.vpc_id == var.vpc_id]))
      error_message = "TLS NLB subnets must be in the same VPC and three distinct AZs."
    }
  }
}

resource "aws_lb_target_group" "this" {
  for_each               = local.listeners
  name                   = "${var.name}-${each.key}"
  port                   = each.value
  protocol               = "TCP"
  target_type            = "instance"
  vpc_id                 = var.vpc_id
  preserve_client_ip     = true
  proxy_protocol_v2      = false
  deregistration_delay   = 60
  connection_termination = true
  health_check {
    enabled             = true
    protocol            = "HTTP"
    port                = "8080"
    path                = "/ready"
    matcher             = "200"
    interval            = 30
    healthy_threshold   = 2
    unhealthy_threshold = 2
  }
  tags = local.tags
}

resource "aws_lb_listener" "this" {
  for_each          = local.listeners
  load_balancer_arn = aws_lb.this[each.key].arn
  port              = each.key == "management" ? 443 : each.value
  protocol          = "TCP"
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.this[each.key].arn
  }
}

resource "aws_lb_target_group_attachment" "this" {
  for_each         = local.attachments
  target_group_arn = aws_lb_target_group.this[each.value.listener].arn
  target_id        = aws_instance.node[each.value.node].id
  port             = local.listeners[each.value.listener]
}

resource "aws_route53_record" "tls" {
  count   = var.enable_tls ? 1 : 0
  zone_id = var.tls_dns.zone_id
  name    = var.tls_dns.name
  type    = "A"
  alias {
    name                   = aws_lb.this["tls"].dns_name
    zone_id                = aws_lb.this["tls"].zone_id
    evaluate_target_health = true
  }
}

resource "aws_route53_record" "management" {
  count   = local.management ? 1 : 0
  zone_id = var.management_dns.zone_id
  name    = var.management_dns.name
  type    = "A"
  alias {
    name                   = aws_lb.this["management"].dns_name
    zone_id                = aws_lb.this["management"].zone_id
    evaluate_target_health = true
  }
}
