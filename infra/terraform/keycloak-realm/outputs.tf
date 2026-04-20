output "realm_id" {
  value = keycloak_realm.openvelox.id
}

output "client_ids" {
  value = {
    airflow            = keycloak_openid_client.airflow.client_id
    argocd             = keycloak_openid_client.argocd.client_id
    grafana            = keycloak_openid_client.grafana.client_id
    web                = keycloak_openid_client.web.client_id
    api                = keycloak_openid_client.api.client_id
    mlflow             = keycloak_openid_client.mlflow.client_id
    flink_ui           = keycloak_openid_client.flink_ui.client_id
    trino              = keycloak_openid_client.trino.client_id
    polaris_console    = keycloak_openid_client.polaris_console.client_id
    kafka_broker       = keycloak_openid_client.kafka_broker.client_id
    kafka_ui           = keycloak_openid_client.kafka_ui.client_id
    kafka_flink        = keycloak_openid_client.kafka_flink.client_id
    kafka_tfl_producer = keycloak_openid_client.kafka_tfl_producer.client_id
  }
}

output "client_secrets" {
  sensitive = true
  value = {
    airflow            = keycloak_openid_client.airflow.client_secret
    argocd             = keycloak_openid_client.argocd.client_secret
    grafana            = keycloak_openid_client.grafana.client_secret
    flink_ui           = keycloak_openid_client.flink_ui.client_secret
    mlflow             = keycloak_openid_client.mlflow.client_secret
    trino              = keycloak_openid_client.trino.client_secret
    kafka_broker       = keycloak_openid_client.kafka_broker.client_secret
    kafka_ui           = keycloak_openid_client.kafka_ui.client_secret
    kafka_flink        = keycloak_openid_client.kafka_flink.client_secret
    kafka_tfl_producer = keycloak_openid_client.kafka_tfl_producer.client_secret
    openvelox_api      = keycloak_openid_client.api.client_secret
  }
}
