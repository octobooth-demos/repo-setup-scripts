variable "region" {
  type    = string
  default = "us-west-2"
}

variable "ami_id" {
  type        = string
  description = "Ubuntu 24.04 AMI for the staging host"
}
