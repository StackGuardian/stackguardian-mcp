# Reading plan JSON

`terraform show -json <planfile>` and `tofu show -json <planfile>` produce the same structure.
The parts that matter for a review:

| Key                                                              | What it holds                                                                    |
| ---------------------------------------------------------------- | -------------------------------------------------------------------------------- |
| `resource_changes[]`                                             | One entry per resource instance in the plan, including unchanged ones            |
| `resource_changes[].address`                                     | Full address, e.g. `module.db.aws_db_instance.main` or `aws_instance.web[0]`     |
| `resource_changes[].mode`                                        | `managed` for resources, `data` for data sources                                 |
| `resource_changes[].type`                                        | Resource type, e.g. `aws_db_instance`                                            |
| `resource_changes[].change.actions`                              | What happens to it (table below)                                                 |
| `resource_changes[].change.before` / `after`                     | Attribute values before and after. `after` is `null` for a delete                |
| `resource_changes[].change.after_unknown`                        | Attributes only known after apply, marked `true`                                 |
| `resource_changes[].change.before_sensitive` / `after_sensitive` | Which attributes are sensitive, marked `true`                                    |
| `resource_changes[].change.replace_paths`                        | For a replacement, the attribute paths that force it                             |
| `resource_changes[].action_reason`                               | Why a resource is replaced or deleted, when Terraform records it                 |
| `output_changes`                                                 | Output values, with the same `actions`, `before`, `after` and `*_sensitive` keys |

## Actions

| `actions`              | Meaning                                                                          |
| ---------------------- | -------------------------------------------------------------------------------- |
| `["no-op"]`            | No change                                                                        |
| `["create"]`           | Created                                                                          |
| `["read"]`             | Data source read during apply                                                    |
| `["update"]`           | Changed in place                                                                 |
| `["delete", "create"]` | Replaced: the old one is destroyed first, so the resource is missing for a while |
| `["create", "delete"]` | Replaced: the new one is created first (`create_before_destroy`)                 |
| `["delete"]`           | Destroyed                                                                        |

A replacement always contains `delete`. That is why the `no-deletes` policy also fails on
replacements.

## Common `action_reason` values

| Value                                                    | Meaning                                                  |
| -------------------------------------------------------- | -------------------------------------------------------- |
| `replace_because_cannot_update`                          | An attribute in `replace_paths` cannot change in place   |
| `replace_because_tainted`                                | The resource is marked tainted                           |
| `replace_by_request`                                     | Someone asked for it with `-replace`                     |
| `delete_because_no_resource_config`                      | The resource was removed from the configuration          |
| `delete_because_count_index` / `delete_because_each_key` | A `count` or `for_each` no longer includes this instance |
| `delete_because_no_module`                               | The module that contained it was removed                 |

## Sensitive values are in plain text

The plan JSON contains sensitive values unmasked. Only the `before_sensitive` and
`after_sensitive` markers say which ones they are. Before you quote any value, check the marker
for that exact attribute or output:

- `"after_sensitive": {"password": true}`: the `password` attribute is sensitive.
- `"after_sensitive": true` on an output: the whole output is sensitive.
- Nested objects and lists mirror the attribute's shape; a `true` anywhere above a value covers
  it.

When in doubt, do not quote the value.

## Resource types the `no-stateful-deletes` policy watches

These usually hold data that a delete or replacement destroys. The list is a starting point;
add the types your projects use to a copy of the policy.

| Cloud        | Types                                                                                                                                                                                                                                                                 |
| ------------ | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| AWS          | `aws_db_instance`, `aws_rds_cluster`, `aws_dynamodb_table`, `aws_s3_bucket`, `aws_efs_file_system`, `aws_ebs_volume`, `aws_elasticache_replication_group`, `aws_docdb_cluster`, `aws_neptune_cluster`, `aws_redshift_cluster`, `aws_opensearch_domain`, `aws_kms_key` |
| Google Cloud | `google_sql_database_instance`, `google_storage_bucket`, `google_bigquery_dataset`, `google_spanner_instance`, `google_compute_disk`                                                                                                                                  |
| Azure        | `azurerm_mssql_database`, `azurerm_postgresql_flexible_server`, `azurerm_mysql_flexible_server`, `azurerm_cosmosdb_account`, `azurerm_storage_account`, `azurerm_managed_disk`                                                                                        |

A type that is not in the plan is skipped. If none of them is in the plan, Tirith reports the
policy as not evaluated (exit `1`): say "no data-holding resources of the watched types in this
plan" rather than "could not check".
