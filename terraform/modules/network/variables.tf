variable "project_id" {
  description = "The GCP project ID"
  type        = string
}

variable "region" {
  description = "The GCP region"
  type        = string
}

variable "network_name" {
  description = "The name of the custom VPC network"
  type        = string
}

variable "subnet_name" {
  description = "The name of the subnet used for the GKE cluster"
  type        = string
}

variable "node_ipv4_cidr" {
  description = "The CIDR range for the GKE cluster nodes"
  type        = string
}

validation {
  condition     = can(cidrhost(var.node_ipv4_cidr, 0))
  error_message = "The node_ipv4_cidr must be a valid IPv4 CIDR range."
}

variable "pod_ipv4_cidr" {
  description = "The secondary IPv4 CIDR range for the GKE cluster pods"
  type        = string
}

validation {
  condition     = can(cidrhost(var.pod_ipv4_cidr, 0))
  error_message = "The pod_ipv4_cidr must be a valid IPv4 CIDR range."
}