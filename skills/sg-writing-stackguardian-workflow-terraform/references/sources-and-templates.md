# Sources and templates

Where a workflow's IaC comes from. "(live)" = reproduced against a real org with provider 1.12.3;
"(unverified)" = inferred from code, not executed. Everything else was read in provider / api /
core / sg-run-controller source.

## 1. Git source — `stackguardian_workflow_git`

Path: `vcs_config.iac_vcs_config.custom_source = { source_config_dest_kind, config = {...} }`.
The provider always sends `useMarketplaceTemplate = false`; there is no attribute for it.

| `source_config_dest_kind` | Use for | `auth` for a private repo |
|---|---|---|
| `GITHUB_COM` | github.com via the StackGuardian GitHub App connector | `/integrations/github_com` (singleton id) or `/secrets/<pat>` |
| `GITHUB_APP_CUSTOM` | GitHub Enterprise / your own GitHub App | `/integrations/<connector>`; shared runners must reach the GHE API, else use a private runner |
| `GITLAB_COM` | gitlab.com | `/integrations/<connector>` |
| `BITBUCKET_ORG` | bitbucket.org | `/integrations/<connector>` (API-token connectors also need `bitbucketEmail` on the connector) |
| `AZURE_DEVOPS` | dev.azure.com (PAT connector) | `/integrations/<connector>` |
| `AZURE_DEVOPS_SP` | dev.azure.com via service principal | `/integrations/<connector>` |
| `GIT_OTHER` | any other host (there is no AWS CodeCommit kind, from code), SSH URLs, self-hosted GitLab/GitHub without a connector | **only** `/secrets/<name>`: for https the secret value becomes the URL's user part, so store `user:token` (e.g. `oauth2:<token>` for GitLab; unverified per host); for `git@`/`ssh://` store a private key |

Rules:

- **Always set `is_private`.** The API rejects a missing value (`{"isPrivate": ["required"]}`).
  Public repo: `is_private = false`, no `auth`, any kind. Private without auth:
  `{"auth": ["auth required for isPrivate"]}`. Private `GIT_OTHER` with a connector:
  `{"auth": ["only secrets supported for GIT_OTHER"]}`.
- **The kind must equal the connector's kind** (the dashboard always copies it from the
  connector). The provider does no host inference: a GitHub App connector on a github.com repo
  needs `GITHUB_APP_CUSTOM`, not `GITHUB_COM`. Let Terraform copy it:
  `source_config_dest_kind = data.stackguardian_connector.vcs.settings.kind`.
- Other kind/auth mismatches (e.g. `/secrets/...` on `GITLAB_COM`) are accepted at create and fail
  at clone: `Unsupported 'auth' for private repo of '<KIND>' sourceConfigDestKind`.
- `repo`: `https://…` or SSH (`git@host:org/repo.git`, `ssh://…`). `http://` fails at run. For VCS
  triggers use the plain https URL (no trailing slash): the webhook is matched by URL string.
  With `GITHUB_COM` / `GITHUB_APP_CUSTOM` the server parses `<owner>/<repo>` out of the URL at
  create; a URL it cannot parse fails with 404 `Invalid GitHub repo` (from code).
- `ref`: branch, tag or commit; omitted = the remote default branch. Clones are `--depth=1`, so a
  commit SHA works only if the git server allows fetch-by-SHA.
- `working_dir`: path inside the repo; never checked at create. At run a missing directory fails
  with `No such directory exists: <path>`, one without `.tf` files with `No OpenTofu/Terraform files
  found in the working directory of the specified repository`.
- `include_sub_module` is stored but **ignored at run** (depth-1 fetch, submodules stay empty).
  Vendor submodules or use module sources instead.
- `git_sparse_checkout_config`: newline-separated non-cone patterns; `working_dir` must be inside
  them or the directory is empty.
- Private Terraform module sources on the same VCS work: the run configures a git credential
  helper from the workflow's `auth`.

## 2. Template source — `stackguardian_workflow_from_template`

```terraform
vcs_config = {
  iac_vcs_config = { iac_template_id = "/acme/vpc-module:3" } # /<owner-org>/<template>:<revision>
  iac_input_data = { schema_type = "FORM_JSONSCHEMA", data = jsonencode({ cidr = "10.20.0.0/16" }) }
}
```

### Template id

| Form | Result |
|---|---|
| `/<owner-org>/<name>:<n>` | ✅ Use this, also for your own org (other orgs' templates hit the provider bug below) |
| `<name>:<n>` (bare) | ❌ 404 `Template <name>:<n> of type IAC does not exist` (live) — the provider docs are wrong here. The provider's own revision lookup resolves a bare id against your org, so plan passes; the API create is what rejects it |
| `/<org>/<name>:latest` or `:<alias>` | Works, but the **code** (repo/ref of the revision) is re-resolved on every run while the **settings** stay frozen from create; the provider never re-resolves on its own. Pin a number |
| `/<org>/<name>` (no suffix) | Resolves to the parent skeleton, not a revision. Never |

- Build it from a resource: `"/${var.org}/${stackguardian_workflow_template_revision.v1.id}"`
  (the revision's `id` is `<template>:<n>`).

### Provider 1.12.3: only templates owned by your org work

The provider fetches the revision itself (on create, on every update, and at plan when
`iac_template_id` changes) and sends the template's **owner** org as `x-sg-orgid`; the API answers
401 unless that is the caller's org. So any template of another org — every `/stackguardian/…`
marketplace template, templates shared with you — fails at apply (live):

```
Error: Error reading workflow template revision
Could not read template revision "/stackguardian/aws-s3-demo-website:16" to resolve workflow defaults: 401: {"message":"Unauthorized"}
```

Workarounds until the provider is fixed:
1. **Own-org copy** — `stackguardian_workflow_template` + `_revision` pointing at the same
   repo/ref and inputs, then `workflow_from_template` on `/<your-org>/<copy>:<n>`
   (`examples/own_template.tf`).
2. **`stackguardian_workflow_git`** on the template's source repository, with the settings written
   out (no template linkage or upgrades).
3. Create that workflow outside Terraform (dashboard / API / MCP `create_workflow`). Importing it
   does not help: every later update re-fetches the revision and 401s.

Pick 1 when several workflows should share the definition and receive upgrades, 2 for a single
workflow. Switching a workflow between `workflow_git` and `workflow_from_template` later is a new
resource type, i.e. a replacement (managed state does not carry over).

To see what a marketplace revision contains (repo, ref, working dir, inputs, Terraform settings),
read it with **your** org in the header — this works although the provider's call does not:

```bash
curl -s -H "Authorization: apikey $STACKGUARDIAN_API_KEY" -H "x-sg-orgid: <your-org>" \
  "$STACKGUARDIAN_API_URI/api/v1/templatetypes/IAC/stackguardian/aws-s3-demo-website:16/"
# .msg.RuntimeSource = git source, .msg.InputSchemas[].encodedData = base64 JSON Schema
```
- **Platform access rules** (relevant once the provider bug below is fixed, and for the API): the
  revision must be published (`is_public = "1"`), owned by your org (drafts are fine), or shared
  with your org; otherwise create succeeds and every run fails `<id> is a private template and
  can only be used by its owner org and orgs the template is shared with`. There is no
  subscription check anywhere.
- `wf_type` must fit the template: TERRAFORM/OPENTOFU templates → TERRAFORM or OPENTOFU (both
  generate the same steps; OpenTofu on a Terraform template works if the code is OpenTofu-compatible,
  unverified); step-based
  (CUSTOM/ANSIBLE_PLAYBOOK/HELM/…) templates → `CUSTOM`. `CUSTOM` on a Terraform template is rejected: the provider merges the template's `terraform_config` into
  the request → 400 `not allowed for CUSTOM Workflow Type` (from code).
- A deleted, archived or unshared revision breaks every run of every workflow that uses it.

### Inheritance (the provider merges the revision into your config at plan/create time)

| You write | Result |
|---|---|
| attribute omitted | inherited from the revision (live) |
| top-level `tags = []`, `approvers = []`, `environment_variables = []`, `deployment_platform_config = []`, `user_schedules = []`, `wf_steps_config = []`, `context_tags = {}`, `mini_steps = {}` | template value suppressed (live for tags/env vars) |
| `description = ""` | suppressed |
| `terraform_config = { pre_plan_hooks = [] }` (any `*_hooks`, `*_wf_steps_config`, `terraform_bin_path`) | **not** suppressed: server keeps the template's value → *inconsistent result*, resource tainted (live) |
| `""` on `terraform_version`, `drift_cron`, `terraform_plan_options`, `terraform_init_options` | not suppressed → template value (inconsistent result if the template sets it) |
| `terraform_config.wf_step_template_revision_id = ""` | the exception: sent as-is, so the template's runtime image is dropped and the platform default image is used (from code) |
| `false` / `0` on `terraform_config` booleans / `timeout` | honoured |
| `null` | same as omitted (inherits) |

You cannot remove a template's nested `terraform_config` values from a `workflow_from_template`
workflow. Publish a revision without them, or use `stackguardian_workflow_git`.

- **`iac_input_data` omitted** → the provider sends the template's `FORM_JSONSCHEMA` defaults
  (top-level `properties[].default`, recursively, but not inside `oneOf/anyOf/allOf`) (live).
  Declared → it replaces the template's inputs **entirely** (no key merge), so repeat every
  input you need. `data = "{}"` → no inputs. `data = ""` → inherits.
- Removing an attribute from config later **keeps the value already in state**; it is only
  re-inherited when the revision changes.
- `resource_name` is never inherited: set it, or the server invents a random 21-character name.
- `vcs_triggers` does not exist on this resource (the platform supports triggers only for git
  sources).
- `terraform_config.wf_step_template_revision_id` exists **only** on this resource (custom
  runtime image, §4).

### Upgrading to a new revision

Change `…:1` → `…:2` and apply. Attributes you **declared** keep your values; attributes you
**left out** adopt the new revision's values (defaults when the revision has none: approvals
count 0, CPU 512, memory 1024, runner `{type = "shared"}`, from code). Live-verified: undeclared
tags/CPU/memory moved to the new revision's values, declared ones stayed, and an undeclared
`iac_input_data` was **dropped** because the new revision had no input schema.

**Two applies** when you create the new revision in the same configuration: the revision id is
unknown at plan time, so switching `iac_template_id` in the same apply fails with *Provider
produced inconsistent final plan* (live). Apply the new revision first, then change the
reference. A wrong id fails at *plan*:
`Could not read template revision "<id>" to resolve workflow defaults`. The provider sends no
`upgradeMode`, so this is not the dashboard's "Upgrade" (which reconciles inputs and can reset
settings) — review the plan.

## 3. Your own templates — `stackguardian_workflow_template` + `_revision`

The template is a container; the revision holds the content. Minimal pair: `examples/own_template.tf`.

- `template_name` becomes the template `id` when it is slug-shaped; otherwise the server
  slugs it and appends a random suffix (live: `ZZ Skill Test 20261021` →
  `zz-skill-test-20261021-gpuzsrbeas6u`). Set `id` to pin it. Revisions are
  `<template>:1`, `:2`, … (the provider creates the template without a skeleton revision, so your
  first revision is `:1`).
- **Set `runtime_source` on every revision.** A revision holds exactly what you send: nothing is
  copied from the template or the previous revision. A revision without it has an empty source
  and every run fails with `Template has no git repository in RuntimeSource` (from code).
- `user_job_cpu` and `user_job_memory` are **required** on a revision.
- `source_config_kind`: `TERRAFORM`, `OPENTOFU`, `ANSIBLE_PLAYBOOK`, `HELM`, `KUBECTL`,
  `CLOUDFORMATION`, `CUSTOM`. `wf_steps_config` on a TERRAFORM/OPENTOFU revision is a plan error.
- Plan-time checks on `runtime_source`: every kind except `GIT_OTHER` needs `auth` starting with
  `/integration` **even for a public repo**; `GIT_OTHER` auth must start with `/secrets/`
  (`Invalid runtime_source Configuration`). Public repo without a connector → `GIT_OTHER` with
  `is_private = false` and no `auth` (live).
- Pin `runtime_source.config.ref` to a tag or commit in published revisions: a branch keeps moving
  under every workflow that uses the revision.
- Immutable, and a plan **error** rather than a replacement: `id`, `source_config_kind`,
  `runtime_source.config.repo` (template); `template_id`, `source_config_kind`, `repo` (revision).
  Create a new resource instead. Server-side a revision also refuses changes to
  `runtime_source.source_config_dest_kind`, and once published or deprecated to
  `runtime_source.config.auth` (`Cannot update <keys> for a template`, from code).
- Terraform > 1.5.7 in a revision's `terraform_config` is rejected like on a workflow
  (execution §2, from code).
- `is_public` on a **revision**: `"1"` = published (afterwards only description, deprecation,
  alias and notes can change — `Cannot update <keys> for a published template`); `"0"` = draft,
  usable only by the owner org (live). On the **template**: `"1"` = listed publicly for other orgs
  (400 `A template with private repo cannot be made public`); `shared_orgs_list` entries are
  `/orgs/<org>` (a bare name never matches).
- `input_schemas = [{ type = "FORM_JSONSCHEMA", encoded_data = base64encode(jsonencode(<JSON
  Schema>)) }]` — the `default`s are what `workflow_from_template` inherits as inputs.
- API-created templates are not subscribed to their own org, so the dashboard shows "Inactive".
  Terraform-created workflows still use them.
- Read has no 404 handling on both resources: after an out-of-band delete, `terraform state rm`.
- Set `alias` on revisions (an unset alias may read back as `""` → inconsistent result; from code).
  Rules (from code): not a pure integer, not `latest`, only `[A-Za-z0-9._-]`, unique within the
  template; `""` removes it. `/<org>/<template>:<alias>` then works as an `iac_template_id`
  (but pin a number, §2).
- **Deprecation and delete** (live unless marked):
  - `deprecation` cannot be set when the revision is created (`409 Deprecation cannot be set when
    creating a template`): add it in a later apply. It is also refused on a draft (`Cannot set
    Deprecation on a template revision that is not published`, from code).
  - `effective_date` is epoch **milliseconds** as a string (`"1798675200000"` = 2026-12-31 UTC).
    The server stores whatever string you send and compares it with the current time in ms, so a
    seconds value lies in 1970 and the revision is deprecated at once.
  - Once the date has passed, only the deprecation message and alias can change, and the date
    cannot move later (`Cannot update effectiveDate for a template that has already been
    deprecated`). Moving a future date earlier, into the past, works.
  - Deleting a published revision (`terraform destroy`, or removing the resource) is refused
    until it is deprecated and the date has passed: `Published template cannot be deleted. Please
    deprecate the template first.` / `Published template cannot be deleted until the deprecation
    effective date has passed`. To tear down: apply a `deprecation` with a past date, then
    destroy. Drafts (`is_public = "0"`) delete freely.
- Import: template `id`; revision `<template>:<n>`. The `stackguardian_workflow_template_revision`
  **data source** takes the bare `<template>:<n>` of your own org only; a `/<org>/` prefix fails
  with `Unable to read workflow template revision.` and a misleading `403: {"msg":""}` (live).

## 4. Custom runtime image (Terraform > 1.5.7, extra CLIs)

- `stackguardian_workflow_step_template` + `_revision` with
  `source_config_kind = "DOCKER_IMAGE"` and `runtime_source = { source_config_dest_kind =
  "CONTAINER_REGISTRY", config = { docker_image = "<registry>/<image>:<tag>" } }` (required on the
  revision; write them on the template too). Private registries: `config.auth = "/secrets/<name>"`
  plus `docker_registry_username`; shared runners cannot pull private non-ECR images.
- Build `FROM public.ecr.aws/stackguardian/workflow-steps/iac-base:v5.0.0`, install as root, switch
  back to `USER stackguardian`, keep ENTRYPOINT/CMD, don't modify `/usr/local/bin`.
- Use it with `workflow_from_template.terraform_config.wf_step_template_revision_id =
  "/<org>/<step-template>:<rev>"`, or as a CUSTOM step's `wf_step_template_id`.
- `stackguardian_workflow_git` has no `wf_step_template_revision_id`. Newer Terraform there means:
  switch to OpenTofu, an org-level execution preset (runtime image) applied server-side at create,
  or a private runner binary (`references/execution.md` §2).
