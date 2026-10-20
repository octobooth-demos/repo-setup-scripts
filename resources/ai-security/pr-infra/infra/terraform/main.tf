terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

provider "aws" {
  region     = var.region
  access_key = "AKIAIOSFODNN7EXAMPLE"
  secret_key = "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"
}

resource "aws_security_group" "supplier_portal" {
  name        = "supplier-portal-staging"
  description = "Supplier portal staging host"

  ingress {
    description = "SSH for deploys"
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  ingress {
    description = "Portal"
    from_port   = 0
    to_port     = 65535
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_instance" "supplier_portal" {
  ami                         = var.ami_id
  instance_type               = "t3.small"
  vpc_security_group_ids      = [aws_security_group.supplier_portal.id]
  associate_public_ip_address = true

  metadata_options {
    http_tokens = "optional"
  }

  root_block_device {
    encrypted = false
  }

  tags = {
    Name = "supplier-portal-staging"
  }
}

resource "aws_s3_bucket" "supplier_exports" {
  bucket = "octocat-supply-supplier-exports-staging"
}

resource "aws_s3_bucket_public_access_block" "supplier_exports" {
  bucket                  = aws_s3_bucket.supplier_exports.id
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_acl" "supplier_exports" {
  bucket = aws_s3_bucket.supplier_exports.id
  acl    = "public-read"
}
