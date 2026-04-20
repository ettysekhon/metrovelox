# Apache Polaris external PDP — OpenVelox decision policy.
#
# Polaris sends one request per authorizable operation to the decision
# endpoint `POST /v1/data/polaris/authz` (package-level query — Polaris
# reads the `allow` field from the returned document) with a JSON body
# of the shape documented at
# https://polaris.apache.org/releases/1.3.0/managing-security/external-pdp/opa/#input-document-structure
#
# `actor.principal` is the Polaris principal name (e.g. `root`, `trino`,
# `platform-admin`) and `actor.roles` is the list of Polaris principal-
# roles currently activated on the caller (e.g. `service_admin`,
# `trino_service`). OIDC roles coming from Keycloak are rewritten by the
# `polaris.oidc.principal-roles-mapper` mappings in
# helm/polaris/values-gke.tmpl.yaml (polaris-admin -> service_admin,
# polaris-viewer -> polaris_viewer) *before* they reach this policy, so
# this file only knows Polaris-native role names.
#
# Design:
#   * default deny
#   * explicit allow lists per principal-role, covering *only* data-plane
#     operations (catalogs, namespaces, tables, views)
#   * privilege-management operations (ADD_*_GRANT_TO_*, CREATE_PRINCIPAL,
#     CREATE_POLICY, etc.) intentionally fall through to deny so they
#     stay inside Polaris-native RBAC — see the "Important Policy
#     Considerations" note at
#     https://polaris.apache.org/releases/1.3.0/managing-security/external-pdp/opa/
#   * warehouse scope is enforced via the parent chain on TABLE/VIEW/
#     NAMESPACE targets — `trino_service` cannot touch catalogs outside
#     our three warehouses (`raw`, `curated`, `analytics`)
#
# All additions to `PolarisAuthorizableOperation` in future Polaris
# releases land on the deny side by default. Widen explicitly and add a
# test for each new op.

package polaris.authz

import future.keywords.if
import future.keywords.in
import future.keywords.every

# ─────────────────────────────── defaults ───────────────────────────────

default allow := false

# Polaris probes `<policy-uri>` (the `polaris.authz` package) and reads
# `.allow` from the response document. All concrete rules are funnelled
# through `data_plane_allow` to make tests (which evaluate `allow`) and
# Polaris agree.
allow if data_plane_allow

# ─────────────────────── operation groupings ────────────────────────────
#
# Mirror the sections in the upstream `PolarisAuthorizableOperation` enum.
# Grouping keeps reviewers honest: a new op always lands in exactly one
# set, and a new role-rule only has to reference the set, not every op.

catalog_read_ops := {
	"LIST_CATALOGS",
	"GET_CATALOG",
}

catalog_write_ops := {
	"CREATE_CATALOG",
	"UPDATE_CATALOG",
	"DELETE_CATALOG",
}

namespace_read_ops := {
	"LIST_NAMESPACES",
	"LOAD_NAMESPACE_METADATA",
	"NAMESPACE_EXISTS",
}

namespace_write_ops := {
	"CREATE_NAMESPACE",
	"UPDATE_NAMESPACE_PROPERTIES",
	"DROP_NAMESPACE",
}

table_read_ops := {
	"LIST_TABLES",
	"LOAD_TABLE",
	"LOAD_TABLE_WITH_READ_DELEGATION",
	"TABLE_EXISTS",
}

# `..._WITH_WRITE_DELEGATION` is critical: Flink's Iceberg sink asks for
# this operation on every table commit and would be denied by a read-only
# allow-list that forgets it. See doc linked in header.
table_write_ops := {
	"CREATE_TABLE_DIRECT",
	"CREATE_TABLE_DIRECT_WITH_WRITE_DELEGATION",
	"CREATE_TABLE_STAGED",
	"CREATE_TABLE_STAGED_WITH_WRITE_DELEGATION",
	"REGISTER_TABLE",
	"LOAD_TABLE_WITH_WRITE_DELEGATION",
	"UPDATE_TABLE",
	"UPDATE_TABLE_FOR_STAGED_CREATE",
	"DROP_TABLE_WITHOUT_PURGE",
	"DROP_TABLE_WITH_PURGE",
	"RENAME_TABLE",
	"COMMIT_TRANSACTION",
	"REPORT_METRICS",
	"SEND_NOTIFICATIONS",
}

# Fine-grained Iceberg table-metadata ops that Polaris emits on every
# snapshot commit coming through the REST catalog. Flink's
# `IcebergFilesCommitter` triggers `ADD_TABLE_SNAPSHOT` +
# `SET_TABLE_SNAPSHOT_REF` on each checkpoint; schema/partition evolution
# and table-properties updates flow through the rest. Trino and Spark
# commits hit the same code path, so these are gated identically to the
# coarser `table_write_ops` above. Kept as a separate set to make the
# "what changed when upstream added an op?" review obvious. See
# https://github.com/apache/polaris/blob/release/1.3.x/polaris-core/src/main/java/org/apache/polaris/core/auth/PolarisAuthorizableOperation.java
table_metadata_write_ops := {
	"ASSIGN_TABLE_UUID",
	"UPGRADE_TABLE_FORMAT_VERSION",
	"ADD_TABLE_SCHEMA",
	"SET_TABLE_CURRENT_SCHEMA",
	"ADD_TABLE_PARTITION_SPEC",
	"ADD_TABLE_SORT_ORDER",
	"SET_TABLE_DEFAULT_SORT_ORDER",
	"ADD_TABLE_SNAPSHOT",
	"SET_TABLE_SNAPSHOT_REF",
	"REMOVE_TABLE_SNAPSHOTS",
	"REMOVE_TABLE_SNAPSHOT_REF",
	"SET_TABLE_LOCATION",
	"SET_TABLE_PROPERTIES",
	"REMOVE_TABLE_PROPERTIES",
	"SET_TABLE_STATISTICS",
	"REMOVE_TABLE_STATISTICS",
	"REMOVE_TABLE_PARTITION_SPECS",
}

view_read_ops := {
	"LIST_VIEWS",
	"LOAD_VIEW",
	"VIEW_EXISTS",
}

view_write_ops := {
	"CREATE_VIEW",
	"REPLACE_VIEW",
	"DROP_VIEW",
	"RENAME_VIEW",
}

all_read_ops := catalog_read_ops | namespace_read_ops | table_read_ops | view_read_ops

all_write_ops := catalog_write_ops | namespace_write_ops | table_write_ops | table_metadata_write_ops | view_write_ops

all_data_ops := all_read_ops | all_write_ops

# Warehouses that the platform currently owns. Any operation whose target
# chain resolves to a catalog outside this set is denied for non-admin
# roles. Keep in sync with `WAREHOUSES` in
# scripts/polaris-bootstrap-principals.sh and the `additionalCatalogs`
# list in helm/trino/values-*.tmpl.yaml.
warehouses := {"raw", "curated", "analytics"}

# ─────────────────────── principal allow rules ──────────────────────────

# service_admin — human admins (mapped from Keycloak `polaris-admin`) and
# the bootstrap `root` service principal. Full data-plane access across
# every catalog. Privilege management still routes through Polaris-native
# RBAC, so `ADD_*_GRANT`, `CREATE_POLICY`, `CREATE_PRINCIPAL`, ... are
# NOT listed and therefore fall through to deny.
data_plane_allow if {
	"service_admin" in input.actor.roles
	input.action in all_data_ops
}

# trino_service — used by the Trino coordinator. Full CRUD on tables,
# views and namespaces within our three warehouses. Creating or deleting
# the catalogs themselves stays with admins. Warehouse scope is enforced
# by `target_inside_openvelox_warehouses`.
data_plane_allow if {
	"trino_service" in input.actor.roles
	input.action in trino_service_allowed_ops
	target_inside_openvelox_warehouses
}

trino_service_allowed_ops := catalog_read_ops |
	namespace_read_ops | namespace_write_ops |
	table_read_ops | table_write_ops | table_metadata_write_ops |
	view_read_ops | view_write_ops

# polaris_viewer — reserved for future read-only humans. Can list + load
# across all warehouses but cannot mutate anything.
data_plane_allow if {
	"polaris_viewer" in input.actor.roles
	input.action in all_read_ops
	target_inside_openvelox_warehouses
}

# ─────────────────────── warehouse-scope helper ─────────────────────────

# True when every target in the request either:
#   * is one of our warehouses (CATALOG target with name ∈ warehouses), OR
#   * has a CATALOG parent whose name ∈ warehouses.
# An empty targets list (service-level ops like LIST_CATALOGS) passes —
# the role-level allow-list is what gates those.
target_inside_openvelox_warehouses if {
	count(input.resource.targets) == 0
}

target_inside_openvelox_warehouses if {
	count(input.resource.targets) > 0
	every target in input.resource.targets {
		target_catalog(target) in warehouses
	}
}

# target_catalog returns the catalog name associated with a target, or is
# undefined if it cannot be resolved. Undefined makes the enclosing
# `in warehouses` check fail closed, which is what we want.
target_catalog(target) := target.name if {
	target.type == "CATALOG"
}

target_catalog(target) := parent.name if {
	target.type != "CATALOG"
	some parent in target.parents
	parent.type == "CATALOG"
}
