# Lifecycle: create, update, replace, destroy, import

"(live)" = reproduced with provider 1.12.3 against a real org; "(unverified)" = inferred.

## 1. When a mistake surfaces

| Stage | Catches |
|---|---|
| `terraform validate` | block syntax, unknown/missing **top-level** attributes, `""` in most strings (`description`, `desc`, `ref`, `working_dir`, env var fields, …). Misspelled keys **inside** nested objects pass and are dropped (live) |
| `plan` | template-revision lookups (`workflow_from_template` upgrades), template/revision `runtime_source` auth rules and immutable fields |
| `apply` (API 400/403/404) | enum values, Terraform > 1.5.7 on create, CUSTOM + `terraform_config`, `is_private` missing, private repo without auth, bare template id, reserved `resource_name`s, config-time policies (403) |
| apply → *inconsistent result* | values the server rewrites (see §3) |
| first run | connector/secret/runner/step-template/template-access problems, repo/backend layout, hooks |

## 2. Create

- New workflows are **inactive** (`IsActive "0"`) until any run (manual, schedule, trigger, drift)
  activates them. Free-plan orgs without a payment method can hit 402 `Active workflow quota
  exhausted` on that first run. Terraform cannot set activation.
- `id`: slug `^[-a-zA-Z0-9_]+$`, used verbatim. `resource_name` is only a display name; omitted →
  random 21 characters (live). Reserved names are rejected: `orgs, wfgrps, stacks, wfs, wfruns,
  policies, secrets, integrations, runnergroups, templates, outputs, logs, listall, …`. The check
  covers `resource_name` only: an `id` such as `listall` is accepted but shadowed by the API route
  of the same name (from code). Keep reserved words out of ids too.
- An `id` already used in the group → 409 `Workflow ID not unique`. A 409 from workflow create is
  also the API's fallback status for other create failures, so read the message (from code).
- A `workflow_group_id` that does not exist is **auto-created** by the server with a junk
  description/tags (for nested paths a top-level group named after the leaf — from code). Always reference the
  group resource.
- Config-time policies in scope evaluate the new definition: a failing rule returns
  `403 Workflow policy (<policy>:<rule>) failed: Expression: … | …` (live) and nothing is created.

## 3. Update and clearing

`stackguardian_workflow_git` (live):

| Attribute class | Removing it from config |
|---|---|
| `tags`, `approvers` (Optional+Computed) | **keeps** the server value — set `[]` to clear |
| `description`, `context_tags`, `environment_variables`, `mini_steps`, `deployment_platform_config`, `wf_steps_config`, `iac_input_data` (Optional) | clears it on the next apply. Don't write `[]`/`{}` for these: the server clears them but the provider reads null back → one-time *inconsistent result* (live) |
| `user_schedules` | set `[]`, apply (schedules deleted, one-time inconsistent result), then remove it — deleting it directly leaves the schedules firing |
| `vcs_triggers` | removing it unregisters nothing — keep it with every `enabled = false` (automation §3) |
| `resource_name` | in-place rename (cosmetic) |

`stackguardian_workflow_from_template`: every inherited attribute is Optional+Computed with
UseStateForUnknown — removing one keeps its current value; suppress with an empty top-level value
(`references/sources-and-templates.md` §2).

**Write what the server stores**, or apply fails with *Provider produced inconsistent result
after apply* (on create the resource is also tainted; live):
- always set `terraform_config.terraform_version` (server stamps `1.5.7` / `1.11.x`), never `terraform_config = {}`;
- approver emails in lowercase.

Recovery: fix the config to the value the server holds; after a failed **create** also run
`terraform untaint <address>`; the plan must be empty.

Other update facts: the whole `terraform_config` and `vcs_config` are sent on every update;
changing `runner_constraints` while a run is queued/running/awaiting approval → 409; the provider
PATCHes `workflow_git` with `upgradeMode=PRESERVE_SETTINGS` and `workflow_from_template` without one.

## 4. Replacement and immutable fields

| Change | `workflow_git` | `workflow_from_template` |
|---|---|---|
| `id` | replace | replace |
| `workflow_group_id` | **inconsistent result**; workflow stays in the old group, diff never goes away (live) | replace |
| `wf_type` | sent, ignored by the server → inconsistent result (unverified) | same |

Replacement = delete + create: the new workflow gets a new internal KSUID, so **SG-managed
Terraform state, run history and artifacts do not carry over** — the new workflow plans from an
empty state. To move or re-type a workflow that manages live infrastructure: destroy its
infrastructure first (run), or move it in the dashboard and re-import at the new address, or keep
managed state off and use your own backend.

For a group move you really want, change the value and run
`terraform apply -replace=stackguardian_workflow_git.<name>`.

## 5. Destroy

`terraform destroy` of a workflow resource:
- deletes the workflow, its runs, schedules, drift schedule and artifacts — including
  SG-managed state;
- **never runs `terraform destroy`**: cloud resources are orphaned;
- is refused while any run is not terminal (`Workflow <id> cannot be deleted as it is currently
  running or queued.` / `… has workflow run(s) that are not in a terminal state (found
  APPROVAL_REQUIRED)`), returned as 400; cancel or finish runs first;
- does not remove VCS webhooks.

Tear-down order for managed infrastructure: trigger a **destroy run** on the workflow (dashboard,
API `POST …/wfs/<id>/wfruns/` with `TerraformAction.action = "destroy"`, or sg-cli), wait for it,
then remove the resource. A group can only be deleted once it is empty. A published template
revision can only be deleted after a passed deprecation date (sources-and-templates §3).

Out-of-band deletes: `workflow_git`, `workflow_template` and `workflow_template_revision` have no
404 handling — every later plan errors `Error reading workflow_git`; run
`terraform state rm <address>`. `workflow_from_template` drops itself from state (and destroying
one that is already gone succeeds).

## 6. Import

| Resource | Import id |
|---|---|
| `stackguardian_workflow_git`, `stackguardian_workflow_from_template` | `<workflow_group_id>/<workflow_id>` — nested group: `parent/child/wf` (split on the last `/`) |
| `stackguardian_workflow_template` | template id |
| `stackguardian_workflow_template_revision` | `<template>:<n>` — the first plan then fails `template_id cannot be changed` (import sets no `template_id`; from code). Avoid importing revisions; recreate or leave them unmanaged |
| `stackguardian_workflow_step_template_revision` | `<template>:<n>` (the next plan replaces it: `template_id` is not read back) |

```terraform
import {
  to = stackguardian_workflow_git.payments_api
  id = "payments/prod/payments-api"
}
```

Plan immediately after importing: expect diffs on server-normalized values (lowercased approvers,
stamped `terraform_version`, schedule names) and write them into the config.
`terraform plan -generate-config-out=generated.tf` (Terraform ≥ 1.5) writes the current values of
every `import` block target for you — start from that file.

## 7. Error catalog

| Message (abridged) | Cause | Fix |
|---|---|---|
| `Missing Organization Name` … `unknown configuration value for the StackGuardian API URI` (or `API Key`) | no `api_uri` / `STACKGUARDIAN_API_URI` (or key); the summary says "Organization Name" for all three settings — read the detail | set the region URL / key |
| `401 Unauthorized` | key from another org/region, or `apikey ` prefix added by hand | right region + org, raw key |
| `Template <x> of type IAC does not exist` | bare or misspelled `iac_template_id` | `/<org>/<name>:<n>` |
| `{"TerraformConfig": ["required for TERRAFORM/OPENTOFU"]}` | missing `terraform_config` | add it with `terraform_version` |
| `not allowed for CUSTOM Workflow Type` | `terraform_config` on CUSTOM | remove it |
| `Terraform <v> is above the highest managed version (1.5.7)` | Terraform ≥ 1.6 | ≤ 1.5.7, OpenTofu, or execution §2 escape hatches |
| `{"isPrivate": ["required"]}` / `auth required for isPrivate` / `only secrets supported for GIT_OTHER` | source config | sources-and-templates §1 |
| `{"ResourceName": ["<x> cannot be used"]}` | reserved name (also as an approver string) | rename |
| `403 Workflow policy (<p>:<r>) failed …` | a config-time policy in scope | satisfy the rule or fix the policy |
| `409 Cannot update RunnerConstraints while there are workflow runs …` | active runs | wait / cancel |
| `409 Workflow ID not unique` | `id` taken in that group (from code) | import it or pick another id |
| `404 Invalid GitHub repo` | `GITHUB_COM`/`GITHUB_APP_CUSTOM` repo URL without `<owner>/<repo>` (from code) | fix `repo` |
| `400 Duplicate workflow step names found: <n>` | two steps share a `name` (from code) | rename |
| `Invalid schema type` (apply) | `wf_step_input_data.schema_type` other than `FORM_JSONSCHEMA` (from code) | `FORM_JSONSCHEMA` |
| `Published template cannot be deleted. Please deprecate the template first.` / `… until the deprecation effective date has passed` | destroying a published revision (live) | sources-and-templates §3 |
| plan: `Unable to read workflow template revision.` (403) | revision data source given `/<org>/<name>:<n>` (live) | bare `<name>:<n>` |
| run: `Template has no git repository in RuntimeSource` | template revision without `runtime_source` (from code) | set it on the revision |
| `Provider produced inconsistent result after apply` | server-normalized value, `workflow_group_id` change on `workflow_git` | §3 / §4 |
| run: `Connector <x> does not exist` | bare or wrong `integration_id` | `/integrations/<id>` |
| run: `Secret specified for '<var>' does not exist` / `Failed to retrieve referenced secret: ${secret::x}` | missing secret | create it |
| run: `Workflow Steps not set` | CUSTOM without steps | add `wf_steps_config` |
| run: `'<id>' required for '<step>' workflow step not found` | wrong step template id/revision | fix `wf_step_template_id` |
| run: `<id> is a private template and can only be used by its owner org …` | template not public/shared | publish / share |
| plan: `Found more than 1 terraform state backend blocks` | repo backend + managed state | remove one |
| plan: `No state backend is configured, nor StackGuardian-managed …` | no backend, managed state off | enable managed state or add a backend |
| run: `Failed to build workflow run: Error 2` | opaque build error — often private runner `names` with a `/runnergroups/` prefix | bare runner group id |

## 8. Migrating from the 0.x `stackguardian_workflow`

Old: `resource "stackguardian_workflow" "x" { wfgrp = "…"; data = jsonencode({ ResourceName, WfType, VCSConfig, … }) }`.
New: one attribute per API field in snake_case (`VCSConfig.iacVCSConfig.customSource.config.isPrivate`
→ `vcs_config.iac_vcs_config.custom_source.config.is_private`), `wfgrp` → `workflow_group_id`,
`ResourceName` → `id` (+ `resource_name`), template sources → `stackguardian_workflow_from_template`.
Keep the existing workflows:
1. With the **old** provider version still installed, `terraform state rm stackguardian_workflow.<name>`
   (a type the new provider no longer has may not be decodable later; `moved` cannot change types).
   Terraform ≥ 1.7 alternative: `removed { from = stackguardian_workflow.<name>  lifecycle { destroy = false } }`.
2. Write the new resource plus an `import` block with `<group>/<workflow-id>`, `terraform init -upgrade`.
3. Plan until it shows `1 to import, 0 to add, 0 to change, 0 to destroy`, then apply and drop the import block. Only `docs-guides-assets/onboarding/project-test` in
the provider repo still shows the old style.
