# GCP KMS keyring + key for Vault auto-unseal.
# Vault uses this key to encrypt/decrypt its master key at startup,
# eliminating the need for manual `vault operator unseal`.

resource "google_kms_key_ring" "vault" {
  project  = var.project_id
  name     = "vault-unseal"
  location = var.region

  depends_on = [google_project_service.apis]
}

resource "google_kms_crypto_key" "vault_unseal" {
  name     = "vault-unseal-key"
  key_ring = google_kms_key_ring.vault.id

  lifecycle {
    prevent_destroy = true
  }
}

output "vault_kms_key_ring" {
  value = google_kms_key_ring.vault.name
}

output "vault_kms_crypto_key" {
  value = google_kms_crypto_key.vault_unseal.name
}
