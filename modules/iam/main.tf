resource "aws_iam_role" "ec2_iam_role" {
  name = "ec2-iam-access"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = {
          Service = "ec2.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name = "ado-chat-ec2-role"
  }
}

resource "aws_iam_role_policy_attachment" "s3_access" {
  role       = aws_iam_role.ec2_iam_role.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonS3ReadOnlyAccess"
}

resource "aws_iam_instance_profile" "ec2_profile" {
  name = "ec2-iam-profile"
  role = aws_iam_role.ec2_iam_role.name
}

resource "aws_ssm_parameter" "hf_token" {
  name  = "/app/hf-token"
  type  = "SecureString"
  value = var.hf_token
  
  tags = {
    Name = "HF Token"
  }
}

resource "aws_ssm_parameter" "duckdns_token" {
  name  = "/app/duckdns-token"
  type  = "SecureString"
  value = var.duckdns_token
  
  tags = {
    Name = "DuckDNS Token"
  }
}

resource "aws_iam_role_policy" "ssm_access" {
  name = "ssm-parameter-access"
  role = aws_iam_role.ec2_iam_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = [
          aws_ssm_parameter.hf_token.arn,
          aws_ssm_parameter.duckdns_token.arn
        ]
      }
    ]
  })
}
