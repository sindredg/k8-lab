# Security Command Center publishes here. Nothing else does.
resource "google_pubsub_topic" "findings" {
  project = var.project_id
  name    = var.topic_name
}

# A message that fails five deliveries lands here instead of cycling forever.
resource "google_pubsub_topic" "dead_letter" {
  project = var.project_id
  name    = "${var.topic_name}-dead"
}

resource "google_pubsub_subscription" "triage" {
  project = var.project_id
  name    = var.subscription_name
  topic   = google_pubsub_topic.findings.id

  # The worker acknowledges after the verdict is durable, not on receipt.
  ack_deadline_seconds = var.ack_deadline_seconds

  # The window the "stop the worker during a delivery" proof has to fit in.
  message_retention_duration = var.message_retention

  # Without this a subscription is deleted after 31 days of inactivity,
  # which would silently remove the durability this phase rests on.
  expiration_policy {
    ttl = ""
  }

  # At-least-once. The worker keys on finding, event time and state, so a
  # redelivery is safe and exactly-once is not worth its throughput cost.
  retry_policy {
    minimum_backoff = "10s"
    maximum_backoff = "600s"
  }

  dead_letter_policy {
    dead_letter_topic     = google_pubsub_topic.dead_letter.id
    max_delivery_attempts = var.max_delivery_attempts
  }
}

# Pub/Sub's own agent moves a failed message to the dead letter topic and
# acknowledges it on the subscription. Both grants are on that agent, not
# on the worker.
data "google_project" "current" {
  project_id = var.project_id
}

locals {
  pubsub_agent = "serviceAccount:service-${data.google_project.current.number}@gcp-sa-pubsub.iam.gserviceaccount.com"
}

resource "google_pubsub_topic_iam_member" "dead_letter_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.dead_letter.name
  role    = "roles/pubsub.publisher"
  member  = local.pubsub_agent
}

resource "google_pubsub_subscription_iam_member" "dead_letter_subscriber" {
  project      = var.project_id
  subscription = google_pubsub_subscription.triage.name
  role         = "roles/pubsub.subscriber"
  member       = local.pubsub_agent
}

# v2 at project scope. The v1 API is gone: gcloud scc notifications list
# answers "This API is no longer available. Please use API V2", and the
# account cannot read at organization scope anyway, which Phase 14 measured.
resource "google_scc_v2_project_notification_config" "findings" {
  project      = var.project_id
  config_id    = "k8-lab-triage"
  location     = "global"
  description  = "Streams finding changes to the triage worker"
  pubsub_topic = google_pubsub_topic.findings.id

  # Deliberately wide. The worker filters and counts what it drops, so the
  # vulnerability volume is recorded rather than discarded upstream where
  # nothing could report it.
  streaming_config {
    filter = "state = \"ACTIVE\" OR state = \"INACTIVE\""
  }
}

# The config publishes as its own agent, which Google names only after the
# config exists. Hence the reference rather than a literal.
resource "google_pubsub_topic_iam_member" "scc_publisher" {
  project = var.project_id
  topic   = google_pubsub_topic.findings.name
  role    = "roles/pubsub.publisher"
  member  = "serviceAccount:${google_scc_v2_project_notification_config.findings.service_account}"
}

# One object per verdict, keyed on the finding, its event time and its
# state. Versioning keeps a corrected verdict from erasing the first one.
resource "google_storage_bucket" "ledger" {
  project                     = var.project_id
  name                        = var.ledger_bucket_name
  location                    = var.region
  force_destroy               = false
  uniform_bucket_level_access = true
  public_access_prevention    = "enforced"

  versioning {
    enabled = true
  }

  # A verdict older than a year is history, not state.
  lifecycle_rule {
    condition {
      age = 365
    }
    action {
      type = "Delete"
    }
  }

  # Noncurrent versions are the audit trail, and a short tail is enough.
  lifecycle_rule {
    condition {
      num_newer_versions = 5
    }
    action {
      type = "Delete"
    }
  }
}
