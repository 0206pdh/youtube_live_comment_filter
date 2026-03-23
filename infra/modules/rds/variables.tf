variable "name" {
  description = "Identifier prefix for the RDS instance and related resources."
  type        = string
}

variable "vpc_id" {
  description = "VPC where RDS will be placed."
  type        = string
}

variable "subnet_ids" {
  description = "Private subnet IDs for the DB subnet group."
  type        = list(string)
}

variable "allowed_security_group_id" {
  description = "Security group ID (ECS service) allowed to reach PostgreSQL on 5432."
  type        = string
}

variable "db_name" {
  description = "Initial database name created on the instance."
  type        = string
  default     = "ylcf"
}

variable "db_username" {
  description = "Master username for the database."
  type        = string
  default     = "ylcf_admin"
}

variable "db_password" {
  description = "Master password for the database. Should come from SSM/secrets."
  type        = string
  sensitive   = true
}

variable "engine_version" {
  description = "PostgreSQL engine version."
  type        = string
  default     = "16.3"
}

variable "instance_class" {
  description = "RDS instance class."
  type        = string
  default     = "db.t4g.micro"
}

variable "allocated_storage" {
  description = "Allocated storage in GiB."
  type        = number
  default     = 20
}

variable "backup_retention_days" {
  description = "Days to retain automated backups."
  type        = number
  default     = 7
}

variable "skip_final_snapshot" {
  description = "Skip final snapshot on deletion. Set true for dev."
  type        = bool
  default     = true
}

variable "deletion_protection" {
  description = "Enable deletion protection. Set true for prod."
  type        = bool
  default     = false
}
