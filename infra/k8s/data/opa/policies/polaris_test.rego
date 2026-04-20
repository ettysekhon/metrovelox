# Unit tests for infra/k8s/data/opa/policies/polaris.rego.
#
# Run locally with:
#   scripts/opa-test.sh          # wrapper, installs opa if missing
#   opa test infra/k8s/data/opa/policies/   # raw invocation
#
# Every test here is seeded from one of the three principal-roles the
# platform provisions today (see scripts/polaris-bootstrap-principals.sh
# and helm/polaris/values-gke.tmpl.yaml `polaris.oidc.principal-roles-
# mapper.mappings`). Adding a new role / catalog / operation? Add a
# happy-path and a deny test for it here — the policy itself is
# default-deny so forgetting a role means silent failure in prod.

package polaris.authz

import future.keywords.if

# Canonical inputs used by most tests. Overridden with `with input as ...`
# per-test to exercise edge cases.
_target_table(catalog, ns, table) := {
	"type": "TABLE",
	"name": table,
	"parents": [
		{"type": "CATALOG", "name": catalog},
		{"type": "NAMESPACE", "name": ns},
	],
}

_target_catalog(catalog) := {
	"type": "CATALOG",
	"name": catalog,
	"parents": [],
}

_req(principal, roles, action, targets) := {
	"actor": {"principal": principal, "roles": roles},
	"action": action,
	"resource": {"targets": targets, "secondaries": []},
	"context": {"request_id": "test"},
}

# ─────────────── service_admin (human admins, bootstrap root) ───────────

test_service_admin_can_create_catalog if {
	allow with input as _req(
		"platform-admin",
		["service_admin"],
		"CREATE_CATALOG",
		[_target_catalog("new_catalog")],
	)
}

test_service_admin_can_drop_table if {
	allow with input as _req(
		"platform-admin",
		["service_admin"],
		"DROP_TABLE_WITH_PURGE",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_service_admin_can_commit_transaction if {
	allow with input as _req(
		"root",
		["service_admin"],
		"COMMIT_TRANSACTION",
		[_target_table("raw", "tfl", "line_status")],
	)
}

# Flink's `IcebergFilesCommitter` calls the fine-grained table-metadata
# ops on every checkpoint. Regression test for the production outage
# where the initial policy only listed the coarser CRUD ops and denied
# `ADD_TABLE_SNAPSHOT` on every commit, stalling the streaming pipeline.
test_service_admin_can_add_table_snapshot if {
	allow with input as _req(
		"root",
		["service_admin"],
		"ADD_TABLE_SNAPSHOT",
		[_target_table("raw", "tube", "line_status")],
	)
}

test_service_admin_can_set_snapshot_ref if {
	allow with input as _req(
		"root",
		["service_admin"],
		"SET_TABLE_SNAPSHOT_REF",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_service_admin_can_set_table_properties if {
	allow with input as _req(
		"root",
		["service_admin"],
		"SET_TABLE_PROPERTIES",
		[_target_table("curated", "tfl", "bike_occupancy")],
	)
}

# Privilege-management stays inside Polaris-native RBAC — OPA always
# denies, even for the `service_admin` role.
test_service_admin_cannot_add_principal_grant if {
	not allow with input as _req(
		"platform-admin",
		["service_admin"],
		"ADD_PRINCIPAL_GRANT_TO_PRINCIPAL_ROLE",
		[{"type": "PRINCIPAL_ROLE", "name": "trino_service", "parents": []}],
	)
}

test_service_admin_cannot_create_principal if {
	not allow with input as _req(
		"platform-admin",
		["service_admin"],
		"CREATE_PRINCIPAL",
		[{"type": "PRINCIPAL", "name": "evil", "parents": []}],
	)
}

test_service_admin_cannot_create_policy if {
	not allow with input as _req(
		"platform-admin",
		["service_admin"],
		"CREATE_POLICY",
		[{"type": "POLICY", "name": "my_policy", "parents": []}],
	)
}

# ─────────────── trino_service (Trino coordinator) ──────────────────────

test_trino_can_load_table_read_delegation if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"LOAD_TABLE_WITH_READ_DELEGATION",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_trino_can_load_table_write_delegation if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"LOAD_TABLE_WITH_WRITE_DELEGATION",
		[_target_table("curated", "tfl", "line_status")],
	)
}

test_trino_can_list_namespaces if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"LIST_NAMESPACES",
		[_target_catalog("analytics")],
	)
}

test_trino_can_create_table_in_warehouse if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"CREATE_TABLE_DIRECT",
		[_target_table("curated", "tfl", "new_table")],
	)
}

# Trino also emits the fine-grained table-metadata ops on CTAS and other
# schema-evolving statements. Keep its surface in sync with
# service_admin so no future Trino release silently regresses.
test_trino_can_add_table_snapshot if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"ADD_TABLE_SNAPSHOT",
		[_target_table("curated", "tfl", "bike_occupancy")],
	)
}

test_trino_cannot_add_table_snapshot_outside_warehouses if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"ADD_TABLE_SNAPSHOT",
		[_target_table("shadow_warehouse", "tfl", "bike_occupancy")],
	)
}

# trino_service must NOT be able to create / drop top-level catalogs.
test_trino_cannot_create_catalog if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"CREATE_CATALOG",
		[_target_catalog("shadow_catalog")],
	)
}

test_trino_cannot_delete_catalog if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"DELETE_CATALOG",
		[_target_catalog("analytics")],
	)
}

# Cross-warehouse writes are denied by the target-scope guard: the
# catalog `shadow_warehouse` isn't in our warehouses set.
test_trino_cannot_write_outside_warehouses if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"CREATE_TABLE_DIRECT",
		[_target_table("shadow_warehouse", "tfl", "exfil")],
	)
}

test_trino_cannot_grant_privileges if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"ADD_CATALOG_ROLE_TO_PRINCIPAL_ROLE",
		[{"type": "PRINCIPAL_ROLE", "name": "trino_service", "parents": []}],
	)
}

# ─────────────── polaris_viewer (future read-only humans) ───────────────

test_viewer_can_read_table if {
	allow with input as _req(
		"analyst",
		["polaris_viewer"],
		"LOAD_TABLE_WITH_READ_DELEGATION",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_viewer_cannot_update_table if {
	not allow with input as _req(
		"analyst",
		["polaris_viewer"],
		"UPDATE_TABLE",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_viewer_cannot_write_delegate if {
	not allow with input as _req(
		"analyst",
		["polaris_viewer"],
		"LOAD_TABLE_WITH_WRITE_DELEGATION",
		[_target_table("curated", "tfl", "line_status")],
	)
}

# Read-only outside our warehouses is still denied.
test_viewer_cannot_read_outside_warehouses if {
	not allow with input as _req(
		"analyst",
		["polaris_viewer"],
		"LOAD_TABLE",
		[_target_table("shadow_warehouse", "x", "y")],
	)
}

# ─────────────── no roles / unknown roles / unknown action ──────────────

test_unauthenticated_denied if {
	not allow with input as _req(
		"anon",
		[],
		"LOAD_TABLE_WITH_READ_DELEGATION",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

test_unknown_role_denied if {
	not allow with input as _req(
		"mystery",
		["not_a_polaris_role"],
		"LOAD_TABLE_WITH_READ_DELEGATION",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

# Future ops we haven't heard of default-deny for trino_service — this
# ensures policy changes in upstream Polaris can never silently widen
# trino's authority.
test_unknown_action_denied_for_trino if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"SOME_NEW_FUTURE_OP",
		[_target_table("analytics", "tube", "line_status_latest")],
	)
}

# Sanity check: service_admin is likewise default-deny for unknown ops
# (we allow-list all_data_ops, not "everything").
test_unknown_action_denied_for_admin if {
	not allow with input as _req(
		"platform-admin",
		["service_admin"],
		"SOME_NEW_FUTURE_OP",
		[_target_catalog("analytics")],
	)
}

# ─────────────── multi-target scoping ───────────────────────────────────
#
# Polaris rename operations carry both the source and the destination in
# `targets`. If *either* is outside our warehouses the request must be
# denied for trino_service.
test_trino_cannot_rename_out_of_warehouse if {
	not allow with input as _req(
		"trino",
		["trino_service"],
		"RENAME_TABLE",
		[
			_target_table("curated", "tfl", "line_status"),
			_target_table("shadow_warehouse", "tfl", "line_status"),
		],
	)
}

test_trino_can_rename_within_warehouses if {
	allow with input as _req(
		"trino",
		["trino_service"],
		"RENAME_TABLE",
		[
			_target_table("curated", "tfl", "line_status"),
			_target_table("curated", "tfl", "line_status_v2"),
		],
	)
}
