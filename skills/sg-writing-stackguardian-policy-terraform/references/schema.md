# Provider 1.12.3 schema — `stackguardian_policy`

Generated from `terraform providers schema -json` (StackGuardian/stackguardian 1.12.3).
`= {...}` / `= [{...}]` are nested **attributes** (`name = …`), never blocks.
`optional+computed` without state carry-over: omit it while changing anything else and it is
sent as `null` (cleared) — declare every top-level attribute.

Accepted values (parsed at apply, not at validate):

| Attribute | Values |
|---|---|
| `policy_type` | `GENERAL` (the provider cannot write `FILTER.INSIGHT`) |
| `policies_config[].on_fail`, `.on_pass` | `FAIL`, `WARN`, `PASS`, `APPROVAL_REQUIRED` — both required by the API |
| `policy_input_data.schema_type` | `TIRITH_JSON` (inline Tirith), `FORM_JSONSCHEMA` (marketplace template inputs), `RAW_JSON`, `NONE` |
| `custom_source.source_config_kind` | `SG_POLICY_FRAMEWORK` (Tirith), `OPA_REGO` |
| `custom_source.source_config_dest_kind` | `INLINE` (Tirith only), `GITHUB_COM`, `GITHUB_APP_CUSTOM`, `GITLAB_COM`, `BITBUCKET_ORG`, `AZURE_DEVOPS`, `GIT_OTHER` |
| `custom_source.additional_config` | JSON string, e.g. `jsonencode({ opaQuery = "pkg.allow" })` (not read back — see sources-and-lifecycle §1) |
| `policy_vcs_config.policy_template_id` | `/<owner-org>/<template>:<revision>` |

Data source `stackguardian_policy`: look up by `id` (`resource_name` input deprecated); returns the
same attributes, all computed — except that its `id` output is always `""`.

### resource stackguardian_policy
```
approvers: list(string)  [optional+computed]
description: string  [optional+computed]
enforced_on: list(string)  [optional+computed]
id: string  [optional+computed]
number_of_approvals_required: number  [optional+computed]
policies_config = [{...}]  [optional+computed]
  name: string  [REQUIRED]
  on_fail: string  [optional]
  on_pass: string  [optional]
  policy_input_data = {...}  [optional]
    data: string  [REQUIRED]
    schema_type: string  [REQUIRED]
  policy_vcs_config = {...}  [optional]
    custom_source = {...}  [optional]
      additional_config: string  [optional]
      config = {...}  [optional+computed]
        auth: string  [optional]
        git_core_auto_crlf: bool  [optional+computed]
        git_sparse_checkout_config: string  [optional]
        include_submodule: bool  [optional]
        is_private: bool  [optional]
        ref: string  [optional]
        repo: string  [optional]
        working_dir: string  [optional]
      source_config_dest_kind: string  [optional+computed]
      source_config_kind: string  [REQUIRED]
    policy_template_id: string  [optional]
    use_marketplace_template: bool  [REQUIRED]
  skip: bool  [optional]
policy_type: string  [REQUIRED]
resource_name: string  [REQUIRED]
tags: list(string)  [optional+computed]
```
