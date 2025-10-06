provider "aws" {
  region  = var.aws_region
  profile = var.aws_profile
}

module "security" {
  source = "./modules/security"
}

module "iam" {
  source = "./modules/iam"
  duckdns_token = var.duckdns_token
  hf_token = var.hf_token
}

module "compute" {
  source = "./modules/compute"
  
  ami_id              = var.ami_id
  instance_type       = var.instance_type
  key_name            = var.key_name
  subnet_id           = var.subnet_id
  security_group_id   = module.security.security_group_id
  iam_instance_profile = module.iam.instance_profile_name
  user_data_file      = var.user_data_file
  duckdns_domain      = var.duckdns_domain
  letsencrypt_email   = var.letsencrypt_email
}

output "ec2_public_ip" {
  description = "Public IP of the EC2 instance"
  value       = module.compute.public_ip
}
