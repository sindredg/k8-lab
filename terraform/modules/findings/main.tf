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
