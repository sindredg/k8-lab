# A reserved address the DNS record can point at for the life of the project, independent of any Gateway object that happens to be using it.
resource "google_compute_global_address" "gateway" {
  project      = var.project_id
  name         = var.address_name
  address_type = "EXTERNAL"
  description  = "Static frontend address for the external Gateway"
}

# Proves control of the domain through a DNS record, so the certificate can be issued and renewed without depending on live traffic.
resource "google_certificate_manager_dns_authorization" "default" {
  project = var.project_id
  name    = "${var.address_name}-dns-auth"
  domain  = var.domain
}

# Google issues this and renews it before expiry. Nothing to rotate by hand.
resource "google_certificate_manager_certificate" "default" {
  project = var.project_id
  name    = "${var.address_name}-cert"

  managed {
    domains            = [var.domain]
    dns_authorizations = [google_certificate_manager_dns_authorization.default.id]
  }
}

# A map lets one Gateway serve several certificates, chosen by hostname. The Gateway references the map, not the certificate.
resource "google_certificate_manager_certificate_map" "default" {
  project = var.project_id
  name    = "${var.address_name}-cert-map"
}

resource "google_certificate_manager_certificate_map_entry" "default" {
  project      = var.project_id
  name         = "${var.address_name}-cert-entry"
  map          = google_certificate_manager_certificate_map.default.name
  certificates = [google_certificate_manager_certificate.default.id]
  hostname     = var.domain
}