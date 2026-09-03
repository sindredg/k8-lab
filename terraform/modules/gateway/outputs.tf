output "address_name" {
  description = "Name the Gateway references, not the address itself"
  value       = google_compute_global_address.gateway.name
}

output "address" {
  description = "The reserved IPv4 address, for the DNS record"
  value       = google_compute_global_address.gateway.address
}