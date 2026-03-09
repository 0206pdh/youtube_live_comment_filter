variable "parameters" {
  description = "Map of parameter definitions keyed by logical name."
  type = map(object({
    name        = string
    description = string
    value       = string
    type        = string
  }))
}
