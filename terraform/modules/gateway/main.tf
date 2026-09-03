# A reserved address the DNS record can point at for the life of the project, independent of any Gateway object that happens to be using it.
resource "google_compute_global_address" "gateway" {
  project      = var.project_id
  name         = var.address_name
  address_type = "EXTERNAL"
  description  = "Static frontend address for the external Gateway"
}
