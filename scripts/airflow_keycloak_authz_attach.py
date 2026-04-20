#!/usr/bin/env python3
"""
Attach Keycloak UMA role policies to Airflow client permissions (singleton / no --teams).

`airflow keycloak-auth-manager create-all` creates scopes, resources, and permissions but does not
link any policies to those permissions unless multi-team mode + create-team is used. Without
policies, Keycloak returns 403 for every API call.

Role policies are named Allow-<Role> and reference realm roles with the exact names:
Viewer, User, Op, Admin, SuperAdmin (see infra/terraform/keycloak-realm/main.tf).

Run inside the Airflow API server pod (same as scripts/airflow-keycloak-rbac.sh):

  kubectl cp scripts/airflow_keycloak_authz_attach.py batch/deploy/airflow-api-server:/tmp/
  kubectl exec -n batch deploy/airflow-api-server -- \\
    env AIRFLOW__KEYCLOAK_AUTH_MANAGER__SERVER_URL=http://keycloak.platform.svc.cluster.local:8080 \\
    python3 /tmp/airflow_keycloak_authz_attach.py

Or: bash scripts/airflow-keycloak-authz-attach.sh
"""
from __future__ import annotations

import json
import os
import sys

from keycloak import KeycloakAdmin
from keycloak.exceptions import KeycloakGetError, KeycloakPostError

# Realm roles that Airflow's Keycloak provider binds to Allow-* policies
ROLE_NAMES = ("Viewer", "User", "Op", "Admin", "SuperAdmin")

# Admin scope permission uses HTTP verbs + LIST (matches provider create-permissions)
ADMIN_SCOPES = ["GET", "POST", "PUT", "DELETE", "MENU", "LIST"]


def _get_role_id(client: KeycloakAdmin, client_uuid: str, role_name: str) -> str:
    try:
        r = client.get_realm_role(role_name)
        return r["id"]
    except KeycloakGetError:
        r = client.get_client_role(client_id=client_uuid, role_name=role_name)
        return r["id"]


def _policy_url(client: KeycloakAdmin, client_uuid: str, policy_type: str | None = None) -> str:
    realm = client.connection.realm_name
    if policy_type:
        return f"admin/realms/{realm}/clients/{client_uuid}/authz/resource-server/policy/{policy_type}"
    return f"admin/realms/{realm}/clients/{client_uuid}/authz/resource-server/policy"


def _get_policy_id(
    client: KeycloakAdmin, client_uuid: str, policy_name: str, *, policy_type: str | None = None
) -> str | None:
    url = _policy_url(client, client_uuid, policy_type=policy_type)
    data_raw = client.connection.raw_get(url)
    policies = json.loads(data_raw.text)
    match = next((p for p in policies if p.get("name") == policy_name), None)
    return match["id"] if match else None


def ensure_role_policy(client: KeycloakAdmin, client_uuid: str, role_name: str) -> None:
    policy_name = f"Allow-{role_name}"
    if _get_policy_id(client, client_uuid, policy_name, policy_type="role"):
        print(f"Policy '{policy_name}' already exists, skip.")
        return
    role_id = _get_role_id(client, client_uuid, role_name)
    payload = {
        "name": policy_name,
        "type": "role",
        "logic": "POSITIVE",
        "decisionStrategy": "UNANIMOUS",
        "roles": [{"id": role_id}],
    }
    try:
        client.create_client_authz_role_based_policy(
            client_id=client_uuid, payload=payload, skip_exists=True
        )
        print(f"Created role policy '{policy_name}'.")
    except KeycloakPostError as e:
        if e.response_code == 409:
            print(f"Policy '{policy_name}' already exists (409), skip.")
        else:
            raise


def _scope_ids(client: KeycloakAdmin, client_uuid: str, names: list[str]) -> list[str]:
    scopes = client.get_client_authz_scopes(client_uuid)
    return [s["id"] for s in scopes if s["name"] in names]


def _resource_ids(client: KeycloakAdmin, client_uuid: str, names: list[str]) -> list[str]:
    resources = client.get_client_authz_resources(client_uuid)
    return [r["_id"] for r in resources if r["name"] in names]


def _get_perm(client: KeycloakAdmin, client_uuid: str, name: str) -> dict | None:
    perms = client.get_client_authz_permissions(client_uuid)
    return next((p for p in perms if p.get("name") == name), None)


def _assoc_scope_policy_ids(client: KeycloakAdmin, client_uuid: str, permission_id: str) -> list[str]:
    realm = client.connection.realm_name
    url = (
        f"admin/realms/{realm}/clients/{client_uuid}/authz/resource-server/permission/scope/"
        f"{permission_id}/associatedPolicies"
    )
    data_raw = client.connection.raw_get(url)
    policies = json.loads(data_raw.text)
    return [p.get("id") for p in policies if p.get("id")]


def _assoc_resource_policy_ids(client: KeycloakAdmin, client_uuid: str, permission_id: str) -> list[str]:
    realm = client.connection.realm_name
    url = (
        f"admin/realms/{realm}/clients/{client_uuid}/authz/resource-server/permission/resource/"
        f"{permission_id}/associatedPolicies"
    )
    data_raw = client.connection.raw_get(url)
    policies = json.loads(data_raw.text)
    return [p.get("id") for p in policies if p.get("id")]


def attach_scope_permission(
    client: KeycloakAdmin,
    client_uuid: str,
    *,
    permission_name: str,
    policy_name: str,
    scope_names: list[str],
    resource_names: list[str],
    decision_strategy: str = "AFFIRMATIVE",
) -> None:
    perm = _get_perm(client, client_uuid, permission_name)
    if not perm:
        print(f"Permission '{permission_name}' not found, skip.")
        return
    permission_id = perm["id"]
    policy_id = _get_policy_id(client, client_uuid, policy_name)
    if not policy_id:
        raise RuntimeError(f"Policy '{policy_name}' not found — create realm roles + run again.")
    existing = [x for x in _assoc_scope_policy_ids(client, client_uuid, permission_id) if x]
    policy_ids = list(dict.fromkeys([*existing, policy_id]))
    scope_ids = _scope_ids(client, client_uuid, scope_names)
    resource_ids = _resource_ids(client, client_uuid, resource_names) if resource_names else []
    payload = {
        "id": permission_id,
        "name": permission_name,
        "type": "scope",
        "logic": "POSITIVE",
        "decisionStrategy": decision_strategy,
        "scopes": scope_ids,
        "policies": policy_ids,
    }
    if resource_ids:
        payload["resources"] = resource_ids
    client.update_client_authz_scope_permission(
        payload=payload, client_id=client_uuid, scope_id=permission_id
    )
    print(f"Attached '{policy_name}' to scope permission '{permission_name}'.")


def attach_resource_permission(
    client: KeycloakAdmin,
    client_uuid: str,
    *,
    permission_name: str,
    policy_name: str,
    resource_names: list[str],
    decision_strategy: str = "AFFIRMATIVE",
) -> None:
    perm = _get_perm(client, client_uuid, permission_name)
    if not perm:
        print(f"Permission '{permission_name}' not found, skip.")
        return
    permission_id = perm["id"]
    policy_id = _get_policy_id(client, client_uuid, policy_name)
    if not policy_id:
        raise RuntimeError(f"Policy '{policy_name}' not found.")
    existing = [x for x in _assoc_resource_policy_ids(client, client_uuid, permission_id) if x]
    policy_ids = list(dict.fromkeys([*existing, policy_id]))
    resource_ids = _resource_ids(client, client_uuid, resource_names)
    payload = {
        "id": permission_id,
        "name": permission_name,
        "type": "resource",
        "logic": "POSITIVE",
        "decisionStrategy": decision_strategy,
        "resources": resource_ids,
        "scopes": [],
        "policies": policy_ids,
    }
    client.update_client_authz_resource_permission(
        payload=payload, client_id=client_uuid, resource_id=permission_id
    )
    print(f"Attached '{policy_name}' to resource permission '{permission_name}'.")


def main() -> int:
    server_url = os.environ.get(
        "AIRFLOW__KEYCLOAK_AUTH_MANAGER__SERVER_URL", "http://keycloak.platform.svc.cluster.local:8080"
    )
    realm = os.environ.get("AIRFLOW__KEYCLOAK_AUTH_MANAGER__REALM", "openvelox")
    user = os.environ.get("KEYCLOAK_BOOTSTRAP_USERNAME", "admin")
    password = os.environ.get("KEYCLOAK_BOOTSTRAP_PASSWORD", "")
    if not password:
        print("ERROR: KEYCLOAK_BOOTSTRAP_PASSWORD is required.", file=sys.stderr)
        return 1

    client = KeycloakAdmin(
        server_url=server_url,
        username=user,
        password=password,
        realm_name=realm,
        user_realm_name=os.environ.get("KEYCLOAK_BOOTSTRAP_USER_REALM", "master"),
        client_id="admin-cli",
        verify=True,
    )
    clients = client.get_clients()
    matches = [c for c in clients if c.get("clientId") == "airflow"]
    if not matches:
        print("ERROR: Keycloak client 'airflow' not found.", file=sys.stderr)
        return 1
    client_uuid = matches[0]["id"]

    for rn in ROLE_NAMES:
        ensure_role_policy(client, client_uuid, rn)

    # ReadOnly — same matrix as team flow (GET+LIST on readable paths); singleton adds MENU on same permission.
    for role in ("Viewer", "User", "Op", "Admin"):
        attach_scope_permission(
            client,
            client_uuid,
            permission_name="ReadOnly",
            policy_name=f"Allow-{role}",
            scope_names=["GET", "MENU", "LIST"],
            resource_names=[],
            decision_strategy="AFFIRMATIVE",
        )

    # Admin — full API scope permission
    for role in ("Admin", "SuperAdmin"):
        attach_scope_permission(
            client,
            client_uuid,
            permission_name="Admin",
            policy_name=f"Allow-{role}",
            scope_names=ADMIN_SCOPES,
            resource_names=[],
            decision_strategy="AFFIRMATIVE",
        )

    # User / Op resource permissions
    for role in ("User", "Admin", "SuperAdmin"):
        attach_resource_permission(
            client,
            client_uuid,
            permission_name="User",
            policy_name=f"Allow-{role}",
            resource_names=["Dag", "Asset"],
        )
    for role in ("Op", "Admin", "SuperAdmin"):
        attach_resource_permission(
            client,
            client_uuid,
            permission_name="Op",
            policy_name=f"Allow-{role}",
            resource_names=["Connection", "Pool", "Variable", "Backfill"],
        )

    # Newer provider / multi-team remnants: attach broad policies if these permissions exist.
    for extra in ("ViewAccess", "GlobalList", "MenuAccess"):
        if not _get_perm(client, client_uuid, extra):
            continue
        for role in ("Admin", "SuperAdmin"):
            attach_scope_permission(
                client,
                client_uuid,
                permission_name=extra,
                policy_name=f"Allow-{role}",
                scope_names=ADMIN_SCOPES,
                resource_names=[],
                decision_strategy="AFFIRMATIVE",
            )

    print("Done. Log out of Airflow and sign in again (or clear site data) so UMA picks up roles.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
