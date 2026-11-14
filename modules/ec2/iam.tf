data "aws_iam_policy_document" "assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "node" {
  name_prefix        = "${var.name}-node-"
  assume_role_policy = data.aws_iam_policy_document.assume.json
  tags               = local.tags
}

resource "aws_iam_instance_profile" "node" {
  name_prefix = "${var.name}-"
  role        = aws_iam_role.node.name
  tags        = local.tags
}

resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.node.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "node" {
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [var.bootstrap_secret_arn]
  }
  # Any version of this one key. Nodes pin version_id and sha256 in their own user data,
  # which is staged (ignore_changes). Restricting IAM to the newest version would make an
  # un-rolled node fail bootstrap on reboot midway through a one-node-at-a-time roll.
  statement {
    actions   = ["s3:GetObjectVersion"]
    resources = ["arn:${data.aws_partition.current.partition}:s3:::${var.definitions.bucket}/${var.definitions.key}"]
  }
  dynamic "statement" {
    for_each = length(var.secret_kms_key_arns) > 0 ? [1] : []
    content {
      actions   = ["kms:Decrypt"]
      resources = var.secret_kms_key_arns
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}", "s3.${data.aws_region.current.region}.${data.aws_partition.current.dns_suffix}"]
      }
    }
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"]
    resources = ["${aws_cloudwatch_log_group.broker.arn}:*"]
  }
  statement {
    actions   = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["RabbitMQ/EC2"]
    }
  }
}

resource "aws_iam_role_policy" "node" {
  role   = aws_iam_role.node.id
  policy = data.aws_iam_policy_document.node.json
}
