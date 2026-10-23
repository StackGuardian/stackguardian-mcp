# Automation and outputs

Schedules, drift detection, VCS triggers, notifications, webhooks, chaining, reading outputs.
"(live)" = reproduced with provider 1.12.3; "(unverified)" = inferred from code.

## 1. Schedules — `user_schedules`

```terraform
user_schedules = [{
  cron  = "0 8 ? * MON-FRI *"   # EventBridge: min hour day-of-month month day-of-week year; UTC
  state = "ENABLED"             # ENABLED | DISABLED
  desc  = "weekday morning run" # <= 255 chars; "" fails validate — omit instead
}]
```

- `name` is computed: the server generates `<org>-<group>-<workflow><random>` (live). Never set or
  edit it; an unknown name on update makes the server drop that schedule.
- 6 fields, `?` in day-of-month **or** day-of-week, always UTC. A 5-field cron fails the create
  with `Invalid CRON expression provided for schedule: <name>`. ≤10 schedules.
- **A scheduled run is a full run with default action `apply`.** The provider cannot attach run
  inputs (plan-only, destroy, different variables), so on TERRAFORM/OPENTOFU workflows pair
  schedules with `approval_pre_apply = true` or keep them on non-prod workflows.
- **Removing schedules** (`workflow_git`): set `user_schedules = []` and apply — the server deletes
  them, then the provider reports a one-time *inconsistent result* (live; not tainted); then delete
  the attribute (clean plan). Deleting the attribute directly sends `null`, which drops the field
  but leaves the EventBridge schedules firing (from code). To pause instead, `state = "DISABLED"`.
- **Adding** a schedule to an existing workflow ends in a one-time *inconsistent result*
  (`user_schedules[0].name` was null, now generated; live); re-plan — it is clean afterwards.
- Schedules fire even on inactive workflows (and activate them).

## 2. Drift detection

```terraform
terraform_config = {
  terraform_version       = "1.5.7"
  managed_terraform_state = true
  drift_check             = true
  drift_cron              = "0 */6 * * ? *" # always set it with drift_check = true (<= 20 chars)
}
mini_steps = { notifications = { email = { drift_detected = [{ recipients = ["platform@acme.com"] }] } } }
```

- A drift run happens only after the workflow has a **COMPLETED** run whose action was apply, plan
  or refresh; it reuses that run's inputs. A new workflow never drifts until it has run.
- Drift runs are an org entitlement (paid orgs); elsewhere they are silently skipped.
- They run only `pre_plan`/`post_plan` steps (+ hooks when `run_*_hooks_on_drift = true`), no
  policies, no chaining. A firing drift schedule re-activates a deactivated workflow.
- Only real resource drift is reported (not code changes). `drift_check = false` deletes the drift
  schedule (`workflow_from_template` also clears `drift_cron`; on `workflow_git` remove it yourself).
  Without `drift_cron` the server schedules every 6 hours (`0 */6 * * ? *`) without writing it into
  the config. CUSTOM workflows cannot drift-check.
- A drift tick on a workflow that has never run activates it (billed) even though no drift run
  happens.

## 3. VCS triggers — `stackguardian_workflow_git.vcs_triggers`

```terraform
vcs_triggers = {
  tracked_branch      = "main"                                    # default: config.ref, then repo default branch
  push                = { createWfRun = { enabled = true } }      # push to tracked_branch -> apply
  pull_request_opened = { createWfRun = { enabled = true } }      # PR into tracked_branch -> plan
  pull_request_modified = { createWfRun = { enabled = true } }    # set together with pull_request_opened
  approval_pre_apply  = true                                      # push/tag runs pause before apply
}
```

| Key | Effect |
|---|---|
| `push` | a push to `tracked_branch` creates a run: `apply` (or `plan` with `plan_only = true`, apply-with-approval with `approval_pre_apply = true`) |
| `pull_request_opened` / `pull_request_modified` | PR (opened / new commits) targeting `tracked_branch` → always `plan` on the PR branch |
| `all_pull_requests` | any PR, ignores `tracked_branch` |
| `create_tag` | a tag push → run with the tag as ref, action follows `plan_only`/`approval_pre_apply` |
| `plan_only` | push/tag runs only plan (wins over `approval_pre_apply`) |
| `file_triggers_enabled` + `file_trigger_patterns` | only run when a changed file matches an fnmatch glob (`["*.tf", "infra/**"]`); provider docs: GitLab only |
| `gh_webhook_url` | computed |

- The inner map key is literally `createWfRun`. There is no `type` key: the provider sends
  `source_config_dest_kind` as the trigger type. Comment-back, check-run and tag-regex options
  the API has are not exposed in 1.12.3.
- Trigger runs carry the workflow's own `terraform_config`, so `terraform_config.approval_pre_apply
  = true` gates push/tag applies too; `vcs_triggers.approval_pre_apply = true` additionally forces
  the gate on push/tag runs when the workflow's own flag is false. PR runs only plan.
- Requirements: git source only (no triggers on `workflow_from_template`), `repo` in https form
  (the event's repo URL is compared as a string, SSH URLs never match), `is_private = true` with
  a connector `auth` (needed to register GitLab / Bitbucket / Azure DevOps webhooks; GitHub
  events arrive through the StackGuardian GitHub App, so the repo must be in that installation).
  The provider documents `GITHUB_COM`, `GITHUB_APP_CUSTOM`, `GITLAB_COM`; the platform also
  accepts `BITBUCKET_ORG`, `AZURE_DEVOPS`, `AZURE_DEVOPS_SP` (unverified through the provider).
- Triggers are registered by a second API call after create. **If it fails, the provider deletes
  the workflow it just created**: `VCS trigger registration failed: … The workflow was deleted …`.
  On update a failure only errors.
- **Stopping triggers:** keep the attribute and set every event's `enabled = false`. Removing
  `vcs_triggers` unregisters nothing (the API has no removal path; the stored triggers are read back
  into state, so later applies keep reporting a diff/inconsistent result — from code), and remote
  webhooks are never deleted — clean them up in the VCS.
- Adding `vcs_triggers` to an existing workflow can end in a one-time *inconsistent result*
  (computed trigger fields planned as null; from code) — re-plan afterwards.
- Changing the repo or kind clears stored triggers but leaves the remote webhook behind.
- Org entitlement `GitRuns` must be enabled.

## 4. Notifications — `mini_steps.notifications.email`

```terraform
mini_steps = {
  notifications = {
    email = {
      errored           = [{ recipients = ["oncall@acme.com", "team@acme.com"] }] # one object, many recipients
      approval_required = [{ recipients = ["approvers@acme.com"] }]
    }
  }
}
```

- Email only (no Slack/Teams attribute exists). Keys: `approval_required`, `cancelled`,
  `completed`, `drift_detected`, `errored` (sent upper-case to the API).
- Only the **first** object of each list is read; put all addresses in its `recipients`.
- Emails are actually sent for `errored`, `approval_required` and `drift_detected` (the run's
  initiator is added). `completed` and `cancelled` are accepted and stored, but no email is sent —
  use a webhook for those.
- Approvers of a paused run are emailed by the platform automatically; `approval_required` is only
  for extra recipients.

## 5. Webhooks — `mini_steps.webhooks`

```terraform
mini_steps = {
  webhooks = {
    completed = [{
      webhook_name   = "deploy-done"
      webhook_url    = "https://hooks.acme.com/sg"
      webhook_secret = "$${secret::sg-webhook-hmac}" # never inline: it is returned unmasked by the API and not sensitive in state
    }]
  }
}
```

- Events: `approval_required`, `cancelled`, `completed`, `drift_detected`, `errored`.
- POST body: org, workflow group, workflow, run ids, status, trigger details and a subset of
  runtime parameters. Header `StackGuardian-Webhook-Signature` =
  base64(HMAC-SHA256(body, secret)). No retries and no timeout — a hanging endpoint delays the
  run's final status.

## 6. Workflow chaining — `mini_steps.wf_chaining`

```terraform
mini_steps = {
  wf_chaining = {
    completed = [{
      workflow_group_id    = stackguardian_workflow_group.web.id          # bare id, "parent/child" when nested
      workflow_id          = stackguardian_workflow_git.cdn_invalidate.id # bare id
      workflow_run_payload = jsonencode({ TerraformAction = { action = "apply" } })
    }]
    errored = [{ workflow_group_id = "ops", workflow_id = "page-oncall" }]
  }
}
```

- Only `completed` and `errored`. For a stack target set `stack_id` (+ `stack_run_payload`) and no
  `workflow_id`.
- Targets are not validated; reference the target resource so it exists first. A mistyped target
  is created on the fly by the run API (`createIfNotExists` defaults to true) (unverified).
- `workflow_run_payload`: JSON string of run overrides, typically `TerraformAction.action`
  (`apply`, `destroy`, `plan`, `plan-destroy`, `refresh`). Omitted = the target's default (apply).
- Chained runs are started as the parent run's executor (shared runners) or with the runner's
  token (private runners); drift runs never chain; a failed chain start is only logged.

## 7. Outputs

```terraform
data "stackguardian_workflow_outputs" "network" {
  workflow_group = stackguardian_workflow_group.prod.id
  workflow       = stackguardian_workflow_git.network.id
}

locals {
  vpc_id = jsondecode(data.stackguardian_workflow_outputs.network.data["vpc_id"]).value
}
```

- `data` is a map of JSON strings, one per Terraform output, each `{value, type, sensitive}`;
  `data_json` is the whole file. CUSTOM steps write their own shape (no `.value` envelope).
- It reads the **latest** outputs at plan time and fails until they exist: inactive workflow →
  `Request failure to read workflow outputs` (live); no outputs yet → `Workflow output is not valid
  JSON`. A config that creates a workflow cannot read its outputs in the same apply — gate the data
  source with `count = var.<producer>_has_run ? 1 : 0` (`examples/outputs_and_references.tf`).
- Sensitive Terraform outputs come back masked (`<sensitive>`).
- If only the next run needs the value (not Terraform), use `$${workflow::<group>.<wf>.outputs.<key>.value}`
  in an env var or input instead (`references/execution.md` §7).
- Stacks: `stackguardian_stack_outputs`, `stackguardian_stack_workflow_outputs`.
