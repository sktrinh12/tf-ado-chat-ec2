data "aws_key_pair" "ec2_key" {
  key_name = var.key_name
}

resource "aws_instance" "app" {
  ami                         = var.ami_id
  instance_type               = var.instance_type
  key_name                    = data.aws_key_pair.ec2_key.key_name
  vpc_security_group_ids      = [var.security_group_id]
  iam_instance_profile        = var.iam_instance_profile
  subnet_id                   = var.subnet_id
  associate_public_ip_address = true
  user_data                   = templatefile("${path.root}/${var.user_data_file}", {
    duckdns_domain    = var.duckdns_domain
    letsencrypt_email = var.letsencrypt_email
  })

  tags = {
    Name = "ado-chat-spa-ec2"
  }
}
