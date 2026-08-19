output "vpc_id" {
  description = "VPC id."
  value       = aws_vpc.this.id
}

output "public_subnet_ids" {
  description = "Public subnet ids."
  value       = aws_subnet.public[*].id
}

output "private_subnet_ids" {
  description = "Private subnet ids."
  value       = aws_subnet.private[*].id
}

output "private_route_table_id" {
  description = "Private route table used by the S3 gateway endpoint."
  value       = aws_route_table.private.id
}

output "vpc_endpoint_security_group_id" {
  description = "Security group attached to interface VPC endpoints."
  value       = try(aws_security_group.endpoints[0].id, null)
}
