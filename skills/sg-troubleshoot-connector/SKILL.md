---
name: sg-troubleshoot-connector
description: Guided diagnosis for a StackGuardian connector (integration) that is not working, starting from a failed workflow run or from a named connector. Reads the run's error and logs, identifies the cloud or version-control connector the run actually used, tests it with authenticate_integration, matches the exact platform error text to a cause, and walks the fix (cloud-side trust, rotating or editing the connector with update_connector, workflow wiring), then re-tests. Use when a run failed with a connector, credential, authentication, permission or git clone error; "connector not working", "credentials expired", "token expired/revoked"; AssumeRole / AssumeRoleWithWebIdentity / OIDC / federated credential / workload identity errors; AWS_INTEGRATION_ERROR, GIT_ERROR, "is not correctly configured", "Connector ... does not exist", "Failed to authenticate against role"; a private repo that won't clone; or authenticate_integration / a connector test reports a failure.
---

# Troubleshoot Connector — Guided Flow

A connector is an org-wide stored credential: **cloud** (AWS, Azure, GCP —
used as a workflow's deployment connector) or **version control** (GitLab,
Bitbucket, Azure DevOps, GitHub App — used to clone a private repo). Follow
the steps IN ORDER and stop as soon as the cause is clear.

Rules for the whole flow:
- Never surface parameter or field names (`deploymentPlatformConfig`,
  `gitAuthRef`, `roleArn`, `validateConnection`, `AdminTaskError`...) to the
  user. Say "the workflow's cloud connector", "the repo credential", "the role
  ARN", "testing the connection", "the run's start error".
- Never ask for, print or summarise a credential value. Values shown as
  `[REDACTED]` are masks, not the real secret — never send one back.
- Never start a run yourself. When a re-run is the next step, say so and name
  `create_workflow_run` as the action the user can approve.
- `authenticate_integration` is a live check that also rewrites the stored
  status. Call it once per diagnosis and once after a fix — never in a loop.

## Step 1 — Get the error

**From a failed run.**
1. Find it: `search_workflow_runs(searchQuery=<run id or workflow name>,
   wfrunStatuses=['PLAN_FAILED','APPLY_FAILED','DESTROY_FAILED'])`, or
   `parentId=<workflow path>` for one workflow's history (drop the status
   filter if nothing comes back). Take `WfRunFullId`.
2. `get_workflow_run(workflowRunId=<id>)` — the live status (the search index
   can lag). In the raw `run`, read:
   - `AdminTaskError`: set when the run failed **before** a runner started
     (connector lookup, credential fetch). Logs may then be empty.
   - `SGInternals.RuntimeErrors[].name/message`: a named code
     (`AWS_INTEGRATION_ERROR`, `GIT_ERROR`, `ADMIN_JOB_ERROR`,
     `SECRET_RESOLUTION_ERROR`). Only private runners record these today;
     on shared runners the same failure shows only as an `[SG_ERROR]` line.
3. `get_workflow_run_logs(workflowRunId=<id>, errorsOnly=true)` — the
   `[SG_ERROR]` lines. If they are generic ("Something unexpected happened",
   "Runtime Exception"), re-read with `errorsOnly=false, tail=true,
   maxLines=300`: the provider's own message (AWS STS, Entra `AADSTS…`, Google
   IAM, git) sits in the step output just above.

**From a named connector** ("my AWS connector stopped working"): find it with
`search_orchestrator_resources(resourceTypes=['INTEGRATION.CLOUD',
'INTEGRATION.VCS'], searchQuery=<hint>)` and go to Step 3. To find a failing
run that used it, `cross_reference(targetKind='cloud_integration' |
'git_integration', targetId='/integrations/<id>')` lists the workflows, then
`search_workflow_runs(parentId=<workflow path>)` their recent runs.

## Step 2 — Which connector did the run use?

Read `run.RuntimeParameters` from Step 1 (it includes per-run overrides):
- **Cloud**: `deploymentPlatformConfig` — **only the first entry is used**
  (more than one cloud connector on a workflow is a platform defect, see
  Step 6). Its `config.integrationId` is the connector. With no entry, a
  `SG_CONNECTOR_NAME` environment variable may name one instead.
- **Version control**: `vcsConfig.iacVCSConfig.customSource` —
  `sourceConfigDestKind` is the provider, `config.isPrivate` whether a
  credential is needed, `config.auth` the credential: `/integrations/<id>` (a
  connector) or `/secrets/<name>` (a vault secret → `sg-manage-secrets` skill).
  A workflow built from a library template clones with the **template
  owner's** credential, which the user may not control.
- Other places a connector hides: a runner group's storage backend, and a
  policy's git source.

If the run record is unavailable, read the workflow:
`get_orchestrator_resource_by_id(parentId=<group path>, resourceId='/wfs/<wf>')`
(`DeploymentPlatformConfig`, `VCSConfig`).

## Step 3 — Read and test the connector

1. `get_connector(connectorId='/integrations/<id>')` → `kind`, `authMethod`,
   non-secret `config` (role ARN, tenant/subscription/client ids, GCP project,
   VCS URLs, session duration), `secretFieldsSet` (names only) and the last
   stored `authentication`. A not-found error here means the connector was
   deleted → the "does not exist" row in Step 4.
2. `authenticate_integration(integrationId='/integrations/<id>')` and read
   `diagnosis` first, then `status`, `statusCode`, `reason`, `msg`:
   - **`authenticated: true`, no diagnosis** → the credential and trust work
     from StackGuardian. The fault is elsewhere: the run used a different
     connector (Step 2), the cloud identity lacks a *permission* for what the
     run did (AccessDenied / AuthorizationFailed / 403 on a specific API in
     the logs — grant it; that is not a connector problem), or a
     runner-specific difference (Step 4).
   - **401 / DISCONNECTED** → the token or key was rejected: revoked,
     expired, or mis-entered → rotate it (Step 5).
   - **403** → it authenticates but lacks a scope; `reason` names it.
   - **429 (rate-limited) and NOT_RESPONDING (unreachable)** are **not
     credential verdicts**. Never tell the user to rotate on these. Retry
     later; for NOT_RESPONDING check that a self-hosted host is reachable
     from the internet (firewall, IP allow list).
   - **PRIVATE** → StackGuardian deliberately does not probe this connector
     (a git server only private runners can reach). No verdict either way;
     the only real test is a run on a private runner that can reach the host.
   - **Cloud `authenticated: false`** → the cloud rejected the stored
     credential or the trust; match the kind's rows in Step 4.

## Step 4 — Symptom → cause → fix

Match error text as a **substring**; `<…>` parts vary. Rows marked *(provider)*
quote AWS/Microsoft/Google/git wording, which can vary by tool version.

### Any connector

| Error text / symptom | Cause | Fix |
|---|---|---|
| `Connector <id> does not exist` | The workflow points at a deleted connector (deletes don't check references). | Pick a replacement or recreate it (`sg-create-connector`), then repoint the workflow (`sg-update-workflow`). `cross_reference` on the old id lists every other workflow, stack and runner still pointing at it. |
| `Failed to fetch Integration from SG_CONNECTOR_NAME environment variable` | That variable names a connector that doesn't exist (format `<id>` or `<group>/<id>`). | Fix the variable, or set a deployment connector on the workflow. |
| Two or more cloud connectors on one workflow; the run uses the wrong account | Only the first is used (platform defect). | Keep one cloud connector per workflow, or put the intended one first (`sg-update-workflow`). |
| `Failed to generate AWS credentials for Storage Backend (S3)` | The runner group's storage-backend role can't be assumed. | Fix that role's trust / external id — it is the runner group's connector, not the workflow's. |

### AWS

| Error text / symptom | Cause | Fix |
|---|---|---|
| `AWS Integration Error. Failed to authenticate against role configured in AWS Integration.` (`AWS_INTEGRATION_ERROR`) | Role + external id connector: the role's trust doesn't allow StackGuardian (principals `arn:aws:iam::476299211833:root` and `arn:aws:iam::163602625436:root`), the external id differs between trust and connector, or the role ARN is wrong. | Compare the trust policy with `sg-create-connector` §3b; the external id there must equal the connector's. Also check the session duration below. |
| Session duration missing or empty in `get_connector` config, run fails at start or with `AWS_INTEGRATION_ERROR` | Platform defect: no default is applied. | `update_connector(config={"durationSeconds": 3600})`. |
| *(provider)* `InvalidIdentityToken` / `No OpenIDConnect provider found` | OIDC: no identity provider in that AWS account for the region's issuer. | Create it with URL and audience = the issuer (`sg-create-connector` §2/§3a). |
| *(provider)* `AccessDenied` on `AssumeRoleWithWebIdentity` | OIDC trust conditions don't match: `<host>:aud` must be the issuer URL, `<host>:sub` must be `/orgs/<org>`; provider ARN must be in the role's account. | Correct the trust policy (`sg-create-connector` §3a). |
| OIDC fails for one region's org only, or after an org move | Wrong issuer: EU is `https://api.app.stackguardian.io`, US is `https://api.us.stackguardian.io`. Ask which dashboard the user logs into. | Add the right provider and fix the trust keys (`<host>` = issuer without `https://`). |
| Connection test fails only for a long connector id; trust looks right | Older platform builds sent a session name over AWS's 64-character cap. Current builds shorten it. | Recreate with a shorter id, or report it as a platform defect (Step 6). |
| `AWS Integration '<id>' is not correctly configured.` | Access-key connector: the stored key could not be read. | Re-enter the keys (Step 5); prefer moving to OIDC. |
| Works on shared runners, fails on a private runner (role + external id) | The role is assumed by StackGuardian when the run starts; if that fails, a private runner falls back to its **own host's** instance role, which the trust must then allow. | Trust StackGuardian's principals with the external id, or also trust the runner host's role. |

### Azure

| Error text / symptom | Cause | Fix |
|---|---|---|
| `Azure Integration '<id>' is not correctly configured.` | The connector's stored ids/secret could not be read. | Re-enter them with `update_connector` (Step 5). |
| *(provider)* `AADSTS70021` (no matching federated identity record) | Federated credential mismatch: issuer and audience must be the region's issuer URL, subject `/orgs/<org>` — exact, no trailing slash, scenario "Other issuer". | Fix the federated credential on the app or managed identity (`sg-create-connector` §3c). |
| *(provider)* `AADSTS7000222` / `AADSTS7000215` (client secret expired / invalid) | Client-secret connector: the secret expired or was mis-entered. | New secret in Entra ID → rotate (Step 5); consider federated instead. |
| *(provider)* `AuthorizationFailed` | Authenticated, but no role assignment on that subscription (or the subscription id is wrong). | Assign Reader/Contributor/custom role on the subscription. |
| Client id rejected | The object id was used instead of the application (client) id. | `update_connector(config={"armClientId": <app id>})`. |
| `Failed to authenticate to Azure Key Vault '<vault>'. Deployment platform is not Azure` | A Key Vault secret reference needs an Azure deployment connector on the workflow. | Set an Azure cloud connector (`sg-update-workflow`). |

### GCP

| Error text / symptom | Cause | Fix |
|---|---|---|
| `GCP Integration '<id>' is not correctly configured.` | The stored configuration file could not be read. | Re-upload it with `update_connector` (Step 5). |
| *(provider)* audience mismatch / `invalid_grant` on token exchange | Workload Identity provider: issuer or allowed audience isn't the region's issuer URL, or the file's `audience` names another pool/provider. | Fix the provider, or regenerate the configuration file (`sg-create-connector` §3d). |
| *(provider)* `iam.serviceAccounts.getAccessToken` denied | Impersonation not granted to subject `/orgs/<org>`, or mapping isn't `google.subject = assertion.sub`. | Grant Workload Identity User on the service account to that principal. |
| Terraform works, but `gcloud`/SDK steps can't find credentials on a **private runner** | Platform defect: private runners only get `GOOGLE_CREDENTIALS`, not `GOOGLE_APPLICATION_CREDENTIALS`. | In a custom step write `$GOOGLE_CREDENTIALS` to a file and export `GOOGLE_APPLICATION_CREDENTIALS`, or use a shared runner. |

### Version control (`GIT_ERROR`, `ADMIN_JOB_ERROR`, start errors)

| Error text / symptom | Cause | Fix |
|---|---|---|
| *(git)* `Authentication failed`, `could not read Username`, `Repository not found` (`GIT_ERROR`) | Token revoked/expired, missing scope, or no access to that repo. | `authenticate_integration`, then rotate or re-scope (scopes: `sg-create-connector` Step 4). |
| `No authentication method provided to authenticate against private repo` | Repo marked private with no usable credential. When it ends "...specified in the IaC template." the template owner's credential is missing. | Set the repo credential (`sg-update-workflow`); for a library template, the template owner must fix it. |
| `No authentication method provided to authenticate against git ssh repo.` | SSH repo URL with no key. | Store the key as a secret and reference it (`sg-manage-secrets`), or use an https URL with a connector. |
| `<auth> does not exist` (may start `[SG_DEBUG]`) | The repo credential points at a deleted connector or secret. | Repoint it (`sg-update-workflow`) or recreate. |
| `Unsupported 'auth' for private repo of '<KIND>' sourceConfigDestKind` | The credential is the wrong type for that provider (e.g. a secret where a connector is required). | Use a connector of that provider (`sg-create-connector`). |
| `<auth> not configured. Please configure it under Integrations` | GitHub.com: the StackGuardian GitHub App isn't installed on the repo's owner. | Install it from the dashboard (Connectors → GitHub). |
| `Github App Custom integration (<id>) is not configured properly` / `GitHub Enterprise Edition (EE) integration being utilized is not configured correctly.` / `Failed calling GitHub API with error` | Custom GitHub App: App id or private key missing/wrong, installation removed, or the GitHub API host unreachable from shared runners. | Re-enter App id / installation id / private key (Step 5); for an internal GitHub Enterprise use a private runner. |
| `bitbucketEmail is required for API_TOKEN auth` | Bitbucket API-token connector without the Atlassian account email. | Add the email (Step 5). |
| `Failed to get Bitbucket VCS credentials:` (other text) | Token rejected or wrong auth type. | Test, then rotate (Step 5). |
| `Azure DevOps SP integration is missing required ARM credentials` / `...is not configured properly - missing required ARM credentials` | Tenant, subscription or client id missing on the connector. | Fill them in (Step 5). |
| *(provider)* `AADSTS…` during Azure DevOps clone | Federated: issuer/subject/audience mismatch on the app; or the app isn't a user in the DevOps org with at least Reader on the project. | Fix as in the Azure table; add the app to the DevOps org. |
| `OIDC token file not found at` | The run's OIDC token wasn't mounted (Azure DevOps federated or Key Vault). | Re-run once; if it repeats, it is a platform defect (Step 6). |

## Step 5 — Fix, re-test, hand back

1. **Cloud-side fixes** (trust policy, OIDC provider, federated credential,
   role assignment, token scopes) are done by the user in their cloud or git
   provider. Give exact values (issuer, subject, external id, role ARN) from
   `get_connector` and `sg-create-connector`, then wait for "done".
2. **Connector-side fixes** use `update_connector(connectorId=...,
   config={<only the keys that change>})`. Connection testing stays on by
   default; leave it on. The tool keeps stored secrets you don't send.
   - Rotation: send only the new secret field. Before asking for it, follow
     the credential-handling guidance in `sg-create-connector` ("Handling
     credentials safely", also in `sg-manage-connectors`): dedicated,
     least-privilege credential, pasted once, never repeated; or rotate in
     the dashboard if it must not pass through this chat.
   - The kind can't change (e.g. access keys → OIDC): create a new connector
     (`sg-create-connector`), then repoint workflows (`sg-update-workflow`).
   - Relay the response's `warnings` — notably that an edit resets a
     connector limited to some workflow groups back to org-wide.
3. `authenticate_integration` once more and relay the result.
4. Tell the user the fix applies to the next run. Offer a re-run and name
   `create_workflow_run` as the action they can approve — only start it on
   their explicit yes.

## Step 6 — When it's the platform, say so

If the cause is a known platform defect, tell the user plainly, give the
workaround, and stop iterating on their configuration. Known items
(`docs/connector_api_upstream_bugs.md`):
- **#12** only the first cloud connector on a workflow is used.
- **#13** role + external id connector without a session duration fails.
- **#14** private runners give GCP steps `GOOGLE_CREDENTIALS` only.
- **#2** a retry after a failed connector create can keep the old secret —
  create under a new id instead.
- **#3** deleting a connector leaves workflows pointing at it.
- Session names over 64 characters on older platform builds (Step 4, AWS).

If nothing matches after Steps 1–4, summarise what was checked (connector,
test result, exact error line, runner type) so the user can send it to
StackGuardian support.
