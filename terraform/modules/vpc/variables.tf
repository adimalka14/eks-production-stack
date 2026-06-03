variable "project_name" {
  description = "Prefix applied to all resource names"
  type        = string
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC"
  type        = string
  default     = "10.0.0.0/16"
}

variable "public_subnet_count" {
  description = "Number of public subnets (one per AZ)"
  type        = number
  default     = 2
}

variable "private_subnet_count" {
  description = "Number of private subnets (one per AZ)"
  type        = number
  default     = 2
}
