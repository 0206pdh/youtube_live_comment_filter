variable "name" {
  description = "Prefix used for VPC-related resource names."
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  type        = string
}

variable "availability_zones" {
  description = "AZs used to spread public/private subnets."
  type        = list(string)
}

variable "public_subnet_cidrs" {
  description = "CIDR blocks for public subnets."
  type        = list(string)
}

variable "private_subnet_cidrs" {
  description = "CIDR blocks for private subnets."
  type        = list(string)
}

variable "aws_region" {
  description = "AWS region used to build regional VPC endpoint service names."
  type        = string
}

variable "enable_private_endpoints" {
  description = "Create S3 gateway and ECR, Logs, SSM, and SQS interface endpoints for NAT-free private tasks."
  type        = bool
  default     = true
}
