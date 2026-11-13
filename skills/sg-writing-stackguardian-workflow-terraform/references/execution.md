# Execution: how a workflow actually runs

What each attribute does when a run executes. "(live)" = reproduced with provider 1.12.3;
"(unverified)" = inferred. The rest is read in api / core / sg-run-controller /
workflow-step-templates source.

## 1. `wf_type`

| `wf_type` | Runs | Required | Forbidden |
|---|---|---|---|
| `TERRAFORM` | steps generated from `terraform_config` (plan → [approval] → apply) | non-null `terraform_config` | top-level `wf_steps_config` (400) |
| `OPENTOFU` | same generated steps, OpenTofu binary | non-null `terraform_config` | top-level `wf_steps_config` |
| `CUSTOM` | your `wf_steps_config`, in order | non-empty `wf_steps_config` (not enforced: 201, then `Workflow Steps not set`) | `terraform_config`, even `{}` (400 `not allowed for CUSTOM Workflow Type`) |

`wf_type` is fixed at create: the server drops it on update. Treat a change as
`terraform apply -replace=<addr>` (which loses managed state — see lifecycle).

## 2. Terraform / OpenTofu versions — `terraform_config.terraform_version`

- Write it **bare** and **always**: `"1.5.7"`, `"1.4.7"`, `"1.11.x"`, never `"TERRAFORM-1.5.7"`
  (template revisions can carry that engine prefix; the provider strips it and compares bare values). Omitting it lets the server
  stamp a default (`1.5.7` / `1.11.x`) that the provider did not plan → inconsistent result (live).
- Org workflow defaults (org settings) fill `terraform_version`, `terraform_bin_path` and
  `wf_step_template_revision_id` at create when the config omits them, and `runner_constraints`
  when that is omitted (from code). Another reason to write them: an omitted value can come back
  as the org's version or private runner.
- **Terraform: ≤ 1.5.7** (last MPL release). `1.5.x`, `1.4.x`, `1.3.x` are pre-cached; other ≤1.5.7
  patches are downloaded at run (needs egress on private runners). Above 1.5.7 on create or
  update: `400 Terraform <v> is above the highest managed version (1.5.7). Set
  wfStepTemplateRevisionId …` (live on create; the update path runs the same check).
- **OpenTofu: any ≥ 1.6** (`1.11.x`, `1.10.x`, `1.9.x` cached). Core passes the version without an
  engine prefix, and the step picks the binary from the number: a bare `0.x`–`1.5.x` runs
  **Terraform** even with `wf_type = "OPENTOFU"`. `X.Y.x` = highest cached patch (else the newest
  released). No ranges, no `~>`, no `latest`.
- Escape hatches for newer Terraform:
  1. `stackguardian_workflow_from_template` + `terraform_config.wf_step_template_revision_id =
     "/<org>/<step-template>:<rev>"` (your own runtime image, sources-and-templates §4).
  2. Private runner binary: `runner_constraints = { type = "private", names = [...] }`,
     `terraform_bin_path = [{ source = "/opt/tf/terraform", target = "/opt/tf/terraform", read_only = true }]`
     and `terraform_version = "/opt/tf/terraform"` (the mounted path; must be executable).
  3. An org execution preset (runtime image) is applied server-side at **create** only; a later
     update re-sends `terraform_config` without it, and the update-time version check then
     rejects it. Prefer 1 or 2.
- In OpenTofu workflows, hooks that call `terraform` get the image's Terraform 1.5.x; use `tofu`
  or `"$SG_TF_BIN_PATH"`.

## 3. `terraform_config` keys

| Key | Behaviour |
|---|---|
| `managed_terraform_state` | Server/run default **false**. `true` = SG writes a `backend "local"` override and stores state for you — the repo must then have **no** `backend` block (`Found more than 1 terraform state backend blocks …`). `false` = the repo **must** have one (`No state backend is configured, nor StackGuardian-managed terraform state backend is used`). A `cloud {}` block does not count as a backend |
| `approval_pre_apply` | pause after a plan **with changes**; no-change plans complete without apply or approval. See §10 |
| `drift_check` / `drift_cron` | automation-and-outputs §2 |
| `terraform_plan_options` / `terraform_init_options` | appended to the command, split on whitespace (no quoting: use `-var-file=x.tfvars`, not `-var 'a=b c'`). SG inputs win over `-var`/`-var-file` here |
| `timeout` | seconds **per step** (default 2100 = 35 min). Ignored when a shared run falls back to Fargate (fixed 2 h there) |
| `terraform_bin_path` | mount list, **private runners only** (400 `only works on private runners` otherwise) |
| `pre_init_hooks` … `post_apply_hooks` | §5 |
| `pre_plan/post_plan/pre_apply/post_apply_wf_steps_config` | §5 |
| `run_pre_init/pre_plan/post_plan_hooks_on_drift` | run those hooks during drift runs too (default false) |
| `wf_step_template_revision_id` | `workflow_from_template` only — custom runtime image |

Not settable: `terraformApplyOptions`. For a tfvars file in the repo use
`terraform_plan_options = "-var-file=env/prod.tfvars"` (only plan takes var files).
`terraform_config` is replaced **whole** on every update, which the provider handles by always
sending the full object.

## 4. Inputs — `vcs_config.iac_input_data`

- `data` is a JSON **string**: `jsonencode({...})`. Malformed JSON silently becomes `{}`.
- It is written to a temporary `.tfvars.json` and passed to `plan` with `-var-file`; types are
  kept (numbers, lists, maps). It overrides repo `*.tfvars` and `-var` in `terraform_plan_options`.
  Keys the module does not declare produce warnings, not errors.
- `schema_type`: `RAW_JSON` for git workflows, `FORM_JSONSCHEMA` for template workflows. The run
  ignores it; it only matters for template upgrades. `NONE`, `RAW_HCL` and `NO_CODE_JSON` exist,
  don't hand-write them. On `workflow_git` both `schema_type` and `data` are required once the
  block is present; for "no inputs" omit `iac_input_data`.
- String values that are exactly `"$${secret::name}"` are resolved at run (a missing secret fails
  the run).

## 5. Hooks and lifecycle steps (TERRAFORM / OPENTOFU)

- `*_hooks`: lists of shell command strings. Each runs as `/bin/sh -c "<item>"` (busybox; **no bash,
  jq, tflint or cloud CLIs**; python, git and curl exist). Non-zero exit fails the run.
- Order: `pre_init` → init → `pre_plan` → plan → `post_plan` → policies/infracost; apply step:
  `pre_apply` → apply → outputs → `post_apply`. `pre_init` runs before backend validation, so it can
  generate files. Plan hooks and apply hooks run in **different containers**; share files through
  the workspace (`/mnt/sg_workspace/...`), not `/tmp`.
- Hooks start in the image's app directory, **not** the repo. Start with
  `cd "$MOUNTED_IAC_SOURCE_CODE_DIR" && …` (repo checkout + `working_dir`, set on shared and
  private runners; `LOCAL_IAC_SOURCE_CODE_DIR` is unset before hooks run).
- Extra tools in a hook: download them (linux/amd64 image, egress needed) to `/tmp`, e.g. a sketch —
  pin a release you have checked:
  `"cd \"$MOUNTED_IAC_SOURCE_CODE_DIR\" && curl -sSLo /tmp/tflint.zip https://github.com/terraform-linters/tflint/releases/download/<version>/tflint_linux_amd64.zip && python -m zipfile -e /tmp/tflint.zip /tmp && chmod +x /tmp/tflint && /tmp/tflint --init && /tmp/tflint"`.
  For anything heavier, bake the tools into a custom step image (sources-and-templates §4).
- `*_wf_steps_config`: full steps (§6 shape) in their own container, ≤5 per phase. Don't set
  both hooks and steps for the same phase (the dashboard treats them as exclusive).
  `pre_apply_wf_steps_config` also runs on plan-only runs. `pre_init` has hooks only.
- Drift runs skip hooks unless the matching `run_*_hooks_on_drift = true`, and never run apply-phase
  hooks or steps.

## 6. CUSTOM workflows

```terraform
wf_type = "CUSTOM"
wf_steps_config = [{
  name                = "run-playbook"                      # slug [A-Za-z0-9_-], unique; spaces break the container name
  wf_step_template_id = "/stackguardian/ansible:18"         # /<owner-org>/<step-template>:<rev>
  wf_step_input_data  = {
    schema_type = "FORM_JSONSCHEMA"                         # the only value; anything else fails at apply
    data        = jsonencode({ playbookPath = "site.yml", ansibleAction = "run" })
  }
  approval = false                                          # true pauses BEFORE this step
  timeout  = 1800                                           # seconds
}]
```

- ≤10 steps; `wf_step_template_id` and `data` are not validated at create (a wrong id: every run
  fails `'<id>' required for '<name>' workflow step not found`). Two steps with the same `name`
  → 400 `Duplicate workflow step names found: <name>` (from code).
- **Step-level `environment_variables` are never injected**; use workflow-level ones (every step
  gets them).
- `mount_points` (and `terraform_bin_path`) only work on private runners (shared runners ignore
  or reject them); `/var/run/docker.sock` is refused.
- `cmd_override` replaces the container command. It is a string: private runners (Docker) accept
  it; on shared runners it goes into the ECS task `command`, which expects a list, so it is expected
  to fail there (from code, unverified at run time).
- `approval = true` on a step pauses before it — also when it is the last step.
- With `approvers` set, at least one step needs `approval = true`, otherwise nothing pauses.
- `iac_input_data` is still passed to IaC-style steps (Ansible extra-vars file, CloudFormation
  parameters).

Built-in step templates (owner `stackguardian`, latest published revision on 2026-09-28):

| Template | Required inputs (`data`) | Notable optional inputs |
|---|---|---|
| `/stackguardian/ansible:18` | `playbookPath` (`playbook.yml`), `ansibleAction` `run`\|`dry-run`\|`check-diff` | `ansibleOptions`, `inventoryType` `hosts`\|`script` + `inventory` (path or host list) / `inventoryScript`; `ANSIBLE_SSH_PRIVATE_KEY` env var |
| `/stackguardian/kubernetes:13` | `cmdToExec` `kubectl`\|`helm`, `kubectlVersion` `1.36`…`1.33`\|`custom` (+`kubectlVersionCustom`), `workingNamespace` | kubectl: `kubectlAction` `apply`\|`delete`\|`get`, `kubeymlfile`; helm: `helmAction` `upgrade`\|`status`\|`uninstall`\|`list`, `helmReleaseName`, `helmChartPath`, `helmSet`; cluster via `KUBECONFIG_DATA` env or connector + `K8S_CLUSTER_NAME` |
| `/stackguardian/cloudformation:2` | `cfAction` `create-changeset`\|`apply-changeset`\|`delete-stack`\|`drift-detection`, `cfStackName` | `cfTemplateFile` xor `cfS3TemplateURL`, `cfParamsFile`, `cfCapabilities`; region from `AWS_REGION` (default eu-central-1). Use two steps: create then apply the changeset |
| `/stackguardian/terragrunt:1` | `terraformAction`, `terraformVersion` (≤1.5.7), `terragruntVersion` `0.62.0`; `managedTerraformState` for plan/plan-destroy/drift-detection | |
| `/stackguardian/sg-common-utils:1` | none published | "cloud providers' cli tools and common shell utils" (its image contents are not documented) — drive it with `cmd_override` on a private runner |

Older revisions (`ansible:14`, `kubernetes:3`, `cloudformation:1`) are what the dashboard still
pins; their inputs differ (e.g. `kubernetes:3` offers kubectl 1.23–1.26). Inputs are never
validated server-side, so check the revision you pin.

## 7. Environment variables and runtime references

```terraform
environment_variables = [
  { kind = "PLAIN_TEXT", config = { var_name = "API_TOKEN", text_value = "$${secret::api-token}" } },
  { kind = "PLAIN_TEXT", config = { var_name = "VPC_ID", text_value = "$${workflow::network.vpc.outputs.vpc_id.value}" } },
  { kind = "VAULT_SECRET", config = { var_name = "LEGACY", secret_id = "/secrets/legacy-token" } },
]
```

- `var_name`: `^[A-Za-z_][A-Za-z0-9_]*$`, ≤80. `text_value`: non-empty, ≤4000. ≤20 variables.
- `kind`: the API accepts only `PLAIN_TEXT` and `VAULT_SECRET` (`SECRET_VALUE`, `SECRET_REF`,
  `TEXT` from older provider docs are a 400). The 1.12.3 docs list only `PLAIN_TEXT` and call
  `secret_id` "Not used", but the run still resolves `VAULT_SECRET` + `secret_id =
  "/secrets/<name>"` (≤80 chars), failing with `Secret specified for '<var>' does not exist` when
  it is missing (from code). Prefer the `${secret::}` form.
- References (write `$${` in HCL — `${` is Terraform interpolation):

  | Reference | Resolves to |
  |---|---|
  | `${secret::<name>}` | org secret (double colon; a dot in the name → `Invalid secret interpolation syntax`) |
  | `${ext-secret::azure-kv::<vault>.<secret>[.<version>]}` | Azure Key Vault; the workflow's connector must be an AZURE_* kind |
  | `${workflow::<group>.<workflow>.outputs.<key>.value}` | latest output of a Terraform workflow (`.value` is Terraform's envelope; nested group: `parent/child`; in a stack: `<group>.<stack>.<wf>`) |

  Resolved only when the **whole value** is the reference (`"pre-${secret::x}"` stays literal), and
  only in `environment_variables[].config.text_value`, `iac_input_data.data` string values,
  `wf_steps_config[].wf_step_input_data.data`, and webhook secrets. A missing workflow-level secret
  fails the run; inside step input data it silently stays a literal.
- The Terraform step runs `os.path.expandvars` on every value **after** secrets are resolved:
  `$NAME` inside a value — including inside a secret's value — is replaced if `NAME` is an env var. Values with newlines (PEM keys) break shared-runner env files — base64
  them.
- Reserved names (set by the platform, don't reuse): `SG_*`, `LOCAL_*`, `MOUNTED_*`, `BASE64_*`,
  `VCS_AUTH_CREDS`, `ORG_ID`, `WORKFLOW_GROUP_ID`, `WORKFLOW_ID`, `WORKFLOW_RUN_ID`, `STACK_ID`,
  `AWS_WEB_IDENTITY_TOKEN_FILE`, `AWS_SHARED_CREDENTIALS_FILE`, `AWS_CONFIG_FILE`,
  `GOOGLE_APPLICATION_CREDENTIALS`, `ARM_OIDC_TOKEN_FILE_PATH`, `ARM_USE_OIDC`. Special inputs:
  `SG_OIDC_ENABLED` (issue an OIDC token), `SG_CONNECTOR_NAME` (use that connector when
  `deployment_platform_config` is empty), `INFRACOST_API_KEY`.
- Env var values are visible in state and to anyone who can read the workflow: never inline a
  credential; reference it.

## 8. Cloud credentials — `deployment_platform_config`

- At most **one** entry: `{ kind, config = { integration_id = "/integrations/<connector>" } }`;
  a connector inside a connector group: `/integrationgroups/<group>/integrations/<connector>`.
- Nothing is checked at create. Wrong id → every run: `Connector <name> does not exist`.
  Unconfigured connector → `AWS/Azure/GCP Integration '<id>' is not correctly configured.`
- Set `kind` to the connector's kind. What each injects: `AWS_STATIC` keys + region;
  `AWS_RBAC` assume-role session creds (**no region** — set `region` in your provider block);
  `AWS_OIDC` role ARN + web-identity token; `AZURE_*` `ARM_*`; `GCP_*` `GOOGLE_CREDENTIALS`.
  `AZURE_MANAGED_ID_OIDC` is accepted by the API but missing from the provider SDK enum
  (unverified through the provider).
- `profile_name` appears to be ignored at run (inferred from code): AWS credentials land in the
  `default` profile. Don't set
  `profile`, keys or `assume_role` in your AWS provider block.
- Connector-scoped policies (`enforced_on = ["/integrations/<c>"]`) match this `integration_id`.
- Managing the connector itself (`resource "stackguardian_connector"`, schema 1.12.3, details from
  code): set `id` (otherwise derived from `resource_name`, random-suffixed when not a slug);
  `settings = { kind = "AWS_RBAC", config = [{ role_arn = "…", external_id = "<org>:<random>",
  duration_seconds = "3600" }] }` — `config` is a **list** of one object and `duration_seconds` a
  string. In 1.12.3 the credential attributes (`aws_secret_access_key`, `arm_client_secret`,
  `gitlab_creds`, …) are **not** marked sensitive and land in state: prefer RBAC/OIDC kinds, or
  create key-based connectors outside Terraform and only look them up.

## 9. Runners and job size

- `runner_constraints = { type = "shared" }` (default) or
  `{ type = "private", names = ["<runner group id>"] }` — exactly one name, the bare id
  (= `resource_name` for slug names), ≤113 chars. Changing it while runs are active → 409.
- Private runner problems surface as `Runner group <name> is not active`, a run stuck QUEUED
  (workflow shows PAUSED) until an agent connects, or the opaque `Failed to build workflow run: Error 2`
  (e.g. `/runnergroups/` prefix in `names`, or `type = "private"` without `names` — accepted at create, from code).
- `runner_constraints` omitted → the org's workflow default runner if one is set, else shared
  (from code).
- Managing the group itself (`resource "stackguardian_runner_group"`, schema in
  `references/schema.md`; behaviour from code): set `id` — it is what `names` takes, and without
  it a non-slug `resource_name` gets a random suffix. `storage_backend_config` is required:
  `{ type = "aws_s3", aws_region, s3_bucket_name, auth = { integration_id = "/integrations/<c>" } }`
  or `{ type = "azure_blob_storage", azure_blob_storage_account_name, azure_blob_storage_access_key }`
  (the key is not marked sensitive in 1.12.3). `max_number_of_runners` defaults to 1. A new group
  has no runners: runs pause until an agent registers with the token from
  `data "stackguardian_runner_group_token" { runner_group_id = "<bare id>" }` (not sensitive in
  1.12.3 — wrap outputs in `sensitive()`). Deleting a group that is the org's default runner → 409.
- `user_job_cpu` (ECS units, 1024 = 1 vCPU) / `user_job_memory` (MiB), defaults 512/1024. Use valid
  Fargate pairs: 256→512–2048, 512→1024–4096, 1024→2048–8192, 2048→4096–16384, 4096→8192–30720.
  On private runners memory is a hard limit (OOM = exit 137).

## 10. Approvals

- TERRAFORM/OPENTOFU: `terraform_config.approval_pre_apply = true` gates apply. CUSTOM: a step's
  `approval = true`. `approvers` alone gates nothing.
- `approvers`: lowercase emails (the server lowercases; mixed case → inconsistent result, live),
  `<userpool>/<idp>/<email>`, or SSO groups `<userpool>/group/<groupId>`. API-key callers cannot
  approve.
- `number_of_approvals_required`: `N` = N distinct approvers; `0` with approvers = **all**; empty
  `approvers` = **anyone** with approve permission. N > len(approvers) never completes.
- Any rejection → run CANCELLED. Plan-approval and policy approvals gate the *next* step, so when
  the plan step is the last one (plan-only runs without pre-apply steps) nothing pauses; a step's own
  `approval = true` pauses even on the last step.
- Approvers are emailed automatically when a run pauses (no notification config needed).
