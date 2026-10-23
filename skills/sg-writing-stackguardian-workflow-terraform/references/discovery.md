# Discovering what exists in the org (StackGuardian MCP server)

Every id a workflow or policy references — connectors, secrets, runner groups, groups, other
workflows, templates — must already exist, and most mistakes (bare ids, display names instead of
ids, typos) apply cleanly and only fail at run time. When the StackGuardian MCP server is
connected (tools such as `search_orchestrator_resources`, `search_workflows`, `search_policies`,
`get_subscription`; in Claude Code they appear as `mcp__stackguardian__<tool>`), **look the values up
before writing HCL** and present the real options to the user instead of guessing or asking them
to type ids from memory.

## Ground rules

1. **Same org.** The MCP server derives its org from its own login; the provider uses
   `STACKGUARDIAN_ORG_NAME`. Check that result rows carry `OrgId = "/orgs/<that org>"` before using
   any id; if they differ, stop and ask.
2. **Read-only.** Use the search/get tools only. Don't create or change workflows, groups,
   templates or policies through MCP write tools when Terraform is meant to own them (the resource
   would then exist outside state and the apply fails with 409 or adopts it). Exception: **secrets**
   — the provider has no secret resource, so a missing secret is created out of band (MCP
   `create_secret`, see the `sg-manage-secrets` skill, or the dashboard); Terraform only references it.
3. **Still guard at plan time.** Keep `data "stackguardian_connector"` / `data
   "stackguardian_runner_group"` / `data "stackguardian_workflow_group"` lookups in the HCL: MCP
   finds the value when you write the code, the data source fails the plan if it later disappears.
4. **Search lags writes by ~20–30 s.** Something created a moment ago may not be listed yet.
5. **Values vs names.** Rows have an id (`ResourceId` / `SubResourceId`) and a display
   `ResourceName`; they often differ (`/integrations/deployment-role` is displayed as
   `sg-nonprod-2`, groups get random suffixes like `GCP-4jc2fd3k`). Always use the id.
6. **No MCP?** Fall back to data sources and ask the user for ids; never invent them.

## Lookups

Use `fields=[...]` on `search_orchestrator_resources` to keep responses small, `searchQuery` for a
name/id substring, and `lastEvaluatedKey` to page.

| Need (Terraform attribute) | Call | Map the row to HCL |
|---|---|---|
| Cloud connector → `deployment_platform_config` | `search_orchestrator_resources(resourceTypes=["INTEGRATION.CLOUD"], searchQuery="<hint>", fields=["ResourceId","ResourceName","ResourceType","ParentId","OrgId"])` | `integration_id = ResourceId` (already `/integrations/<id>`); `kind = ResourceType` without `INTEGRATION.` (e.g. `AWS_RBAC`). A child of a connector group (`ParentId = /orgs/<org>/integrationgroups/<g>`) is `/integrationgroups/<g>/integrations/<id>` |
| VCS connector → `custom_source.config.auth`, `source_config_dest_kind` | same with `INTEGRATION.VCS` | `auth = ResourceId`; `source_config_dest_kind = ResourceType` without `INTEGRATION.` (`GITHUB_COM`, `GITHUB_APP_CUSTOM`, `GITLAB_COM`, …). None fits the repo host → `GIT_OTHER` + a secret |
| Secret → env var, `auth` (GIT_OTHER), webhook secret | `search_orchestrator_resources(resourceTypes=["SECRET"], searchQuery="<hint>", fields=["ResourceId","ResourceName"])` | `ResourceId = /secrets/<name>` → `text_value = "$${secret::<name>}"` (or `secret_id = "/secrets/<name>"`). Values are never returned. Missing → have it created first (rule 2) |
| Private runner group → `runner_constraints.names` | `search_orchestrator_resources(resourceTypes=["RUNNER"])`; or read `RunnerGroupId` off an existing workflow from `search_workflows` | `names = ["<id>"]` — the last segment of `/runnergroups/<id>`; check it is active and has connected runners |
| Workflow group → `workflow_group_id`, policy `enforced_on` | `search_orchestrator_resources(resourceTypes=["WORKFLOW_GROUP"], searchQuery="<hint>", fields=["ResourceId","ResourceName","SubResourceId","ParentId","OrgId"])` | Use **`SubResourceId`** (`/wfgrps/PROD/GCP-4jc2fd3k`): `workflow_group_id = "PROD/GCP-4jc2fd3k"`, `enforced_on = ["/wfgrps/PROD/GCP-4jc2fd3k"]`. `ResourceId` is only the leaf for nested groups |
| Existing workflow → chaining target, `${workflow::…}` reference, policy scope, import | `search_workflows(searchQuery="<hint>")` (filters: `parentId`, `workflowTypes`, `stackId=""` for standalone) | `SubResourceId = /wfgrps/<g>/wfs/<w>` → `enforced_on` entry as-is; `wf_chaining = { workflow_group_id = "<g>", workflow_id = "<w>" }`; import id `<g>/<w>`. Rows with a `StackId` belong to a stack — not a `workflow_git` import |
| Output keys for `${workflow::<g>.<w>.outputs.<key>.value}` | `get_workflow_outputs(resourceId="<SubResourceId>")` | key names (Terraform outputs need `.value`) |
| Own IaC template → `iac_template_id` | `search_marketplace_templates(templateType="IAC", searchQuery="<hint>")` then `get_marketplace_template_by_id(templateType="IAC", templateId="/<org>/<name>:<n>")` | `iac_template_id = "/<org>/<name>:<n>"` (pin a number); `IsPublic "0"` = draft; decode `InputSchemas[].encodedData` for the inputs and defaults; `RuntimeSource` shows repo/ref. Covers templates **owned by** the org only |
| Step templates → `wf_step_template_id` | `get_subscription(subscriptionTypes=["WORKFLOW_STEP"], fields=["TemplateId","TemplateName","OwnerOrg"])`, `search_marketplace_templates(templateType="WORKFLOW_STEP")` for own ones | `/<owner>/<name>:<rev>`. StackGuardian's public steps (`/stackguardian/ansible:18`, …) work without a subscription and may not be listed |
| Policy templates → `policy_template_id` | `get_subscription(subscriptionTypes=["IAC_POLICY"])` | `/<owner>/<name>:<n>`; pin a revision that exists |
| Existing policies (names, scopes) | `search_policies(searchQuery="<hint>")`, then `get_orchestrator_resource_by_id(parentId="/orgs/<org>", resourceId="/policies/<id>")` | avoid name/id collisions; the row's `PoliciesConfig` and `Scope` show current rules and scope |
| What would this change affect? | `search_workflows(parentId="/orgs/<org>/wfgrps/<g>")`, `search_workflows(cloudIntegrationIds=["/integrations/<c>"])`, `cross_reference(targetKind="cloud_integration" \| "git_integration" \| "runner_group" \| "iac_template" \| "policy_template", targetId=…)` | preview a policy scope's blast radius; find workflows depending on a template/connector before changing it |
| Name already taken? | the searches above with the planned id as `searchQuery` | an existing id → import instead of create (409 otherwise) |

## Worked flow (workflow from a private repo)

1. `INTEGRATION.VCS` search → pick the connector whose kind matches the repo host →
   `auth`, `source_config_dest_kind`.
2. `INTEGRATION.CLOUD` search → user picks the account → `integration_id`, `kind`.
3. `SECRET` search for every secret the code needs → `$${secret::<name>}`; list the missing ones.
4. `WORKFLOW_GROUP` search → target group's `SubResourceId` (or create a new group resource).
5. `search_workflows(searchQuery="<planned id>")` in that group → make sure the id is free.
6. Write the HCL with those values plus the matching data sources, then `terraform plan`.
