---
name: sg-create-connector
description: Guided flow for creating a StackGuardian connector (integration) with the create_connector tool — a cloud connector that workflows deploy through (AWS OIDC or IAM role with external id, Azure service principal with federated credentials or managed identity, GCP Workload Identity Federation, or static keys / client secret / service-account key) or a version-control connector that clones private repos (GitLab token, Bitbucket API or access token, Azure DevOps PAT or service principal, custom GitHub App / GitHub Enterprise). Walks the user through the cloud-side trust setup FIRST (OIDC provider, trust policy, federated credential, workload identity pool) with exact per-region values, then creates and tests the connector and hands back the reference for create_workflow / create_stack / update_workflow. Use when the user wants to connect a cloud account, subscription or project, set up AWS/Azure/GCP credentials, OIDC or a role for StackGuardian, connect GitLab/Bitbucket/Azure DevOps/a GitHub App, or when create_workflow / create_stack / create_policy reports that no suitable connector exists.
---

# Create Connector — Guided Flow

A connector is an org-wide, stored credential: a **cloud** connector gives
workflow runs access to an AWS account, Azure subscription or GCP project; a
**version-control** connector lets StackGuardian clone private repositories.
Follow the steps IN ORDER. Never surface parameter names like `roleArn`,
`armClientId`, `gcpConfigFileContent` or `validateConnection`; speak of "the
role ARN", "the client id", "the configuration file", "testing the
connection". Fetch ids with tools; never ask the user to recall them.

## Step 0 — Reuse beats create

1. List what exists:
   `search_orchestrator_resources(resourceTypes=['INTEGRATION.CLOUD'])` or
   `['INTEGRATION.VCS']`, with `searchQuery=<provider or account hint>`.
2. If one fits, inspect it with `get_connector(connectorId=<id>)` (kind, auth
   method, role ARN / ids, last authentication) and offer it. If it may be
   stale, `authenticate_integration(integrationId=<id>)` tests it. A working
   existing connector ends this skill: hand back its `referenceAs` (Step 8).
3. Create only when nothing fits, or the user explicitly wants a new one.

## Step 1 — Provider and auth method

Ask which provider, then offer its methods, recommended first. Say why in one
line: the recommended methods pass **nothing secret through this chat**.

| Provider | Method (kind) | One-line trade-off |
|---|---|---|
| AWS | OIDC (`AWS_OIDC`) — recommended | Short-lived tokens, nothing to rotate; needs an IAM OIDC provider + role. |
| AWS | IAM role + external id (`AWS_RBAC`) | No stored key; StackGuardian's AWS accounts assume your role. |
| AWS | Access keys (`AWS_STATIC`) | Long-lived key passes through this chat; rotate it yourself. |
| Azure | Service principal, federated (`AZURE_OIDC`) — recommended | No secret; federated credential on an app registration. |
| Azure | Managed identity (`AZURE_MANAGED_ID_OIDC`) | No secret; federated credential on a user-assigned identity. |
| Azure | Service principal, client secret (`AZURE_STATIC`) | Secret passes through this chat and expires. |
| GCP | Workload Identity Federation (`GCP_OIDC`) — recommended | No key; the config file holds no secret. |
| GCP | Service-account key (`GCP_STATIC`) | Private key passes through this chat. |
| GitLab | Token (`GITLAB_COM`) | Personal, group or project access token. |
| Bitbucket | API token or workspace access token (`BITBUCKET_ORG`) | App passwords are refused (deprecated by Atlassian). |
| Azure DevOps | Service principal (`AZURE_DEVOPS_SP`) or PAT (`AZURE_DEVOPS`) | Federated SP needs no secret; a PAT is tied to one user. |
| GitHub Enterprise / own App | Custom GitHub App (`GITHUB_APP_CUSTOM`) | Several secrets (client secret, private key, webhook secret). |
| GitHub.com | — | Dashboard only (see Out of scope). |

## Step 2 — Values every OIDC setup needs

Ask which StackGuardian region the user logs into, and their org name (it is
in the dashboard URL after `/orgs/`, or in any full `/orgs/<org>/...` id a tool
returns). Then use:

| | EU (`app.stackguardian.io`) | US (`us.stackguardian.io`) |
|---|---|---|
| Issuer = audience (`<host>`) | `https://api.app.stackguardian.io` | `https://api.us.stackguardian.io` |
| Subject | `/orgs/<org>` | `/orgs/<org>` |

The subject is the same for every connector in the org. The run container
reads the token from `/mnt/sg_workspace/user/stackguardian.oidc`.

## Step 3 — Cloud-side setup FIRST

Walk the user through their branch and wait until they confirm it is done
(except AWS role without an external id — see 3b). Permissions are the
user's choice: recommend least privilege (read-only for discovery, scoped
write for deployments), never admin by default. The dashboard also offers a
CloudFormation quick setup for AWS (Connectors → Cloud providers); mention it,
but do not paste a CloudFormation link yourself.

### 3a. AWS OIDC
1. IAM → Identity providers → Add provider → OpenID Connect; provider URL and
   audience both `<host>`
   (`aws iam create-open-id-connect-provider --url <host> --client-id-list <host>`).
2. Create a role with this trust policy (`<hostname>` = `<host>` without
   `https://`), attach the permissions policy the user chooses, and copy the
   role ARN:
   ```json
   {
     "Version": "2012-10-17",
     "Statement": [{
       "Effect": "Allow",
       "Principal": {"Federated": "arn:aws:iam::<AWS_ACCOUNT_ID>:oidc-provider/<hostname>"},
       "Action": "sts:AssumeRoleWithWebIdentity",
       "Condition": {"StringEquals": {
         "<hostname>:aud": "<host>",
         "<hostname>:sub": "/orgs/<org>"
       }}
     }]
   }
   ```

### 3b. AWS role + external id
The role trusts StackGuardian's AWS accounts and requires an external id that
contains the org name:
```json
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Principal": {"AWS": ["arn:aws:iam::476299211833:root", "arn:aws:iam::163602625436:root"]},
    "Action": "sts:AssumeRole",
    "Condition": {"StringEquals": {"sts:ExternalId": "<EXTERNAL_ID>"}}
  }]
}
```
Two orders — ask which the user prefers:
- **User picks the external id** (must contain the org name, e.g.
  `<org>:<random>`): they create the role with it first, then Step 5 as
  normal, passing it.
- **Let StackGuardian generate it**: agree the role name now (the ARN is
  predictable: `arn:aws:iam::<account>:role/<name>`), create the connector in
  Step 5 with connection testing OFF and no external id, take
  `generated.externalId` from the response, have the user create the role
  with it in the trust policy, then test with `authenticate_integration`.

Session length defaults to 1 hour; ask only if the user needs longer runs
(15 min – 12 h).

### 3c. Azure — service principal (federated) or managed identity
1. Service principal: Entra ID → App registrations → New registration
   (single tenant). Managed identity: create a user-assigned managed identity.
2. Add a federated credential, scenario "Other issuer": issuer `<host>`,
   subject `/orgs/<org>`, audience `<host>`, name e.g. `StackGuardian-Trust`.
   (`az ad app federated-credential create --id <appId> --parameters '{"name":"StackGuardian-Trust","issuer":"<host>","subject":"/orgs/<org>","audiences":["<host>"]}'`,
   or `az identity federated-credential create --identity-name <mi> -g <rg> --name StackGuardian-Trust --issuer <host> --subject /orgs/<org> --audiences <host>`.)
3. Role assignment on the subscription: Reader for discovery, Contributor or a
   narrower custom role for deployments.
4. Collect tenant id, subscription id and client id (the app's application id,
   or the managed identity's client id) — all GUIDs.

### 3d. GCP Workload Identity Federation
1. Create a workload identity pool, then an OIDC provider in it: issuer
   `<host>`, allowed audience `<host>`, attribute mapping
   `google.subject = assertion.sub`.
2. Grant access via service-account impersonation to a least-privilege
   service account, for principals with subject `/orgs/<org>`
   (member `principal://iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL>/subject//orgs/<org>`,
   role `roles/iam.workloadIdentityUser`).
3. Download the client library config with OIDC token path
   `/mnt/sg_workspace/user/stackguardian.oidc` (or
   `gcloud iam workload-identity-pools create-cred-config projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER> --service-account=<SA_EMAIL> --credential-source-file=/mnt/sg_workspace/user/stackguardian.oidc --output-file=sg-gcp.json`).
   It must have `"type": "external_account"`, `audience` =
   `//iam.googleapis.com/projects/<PROJECT_NUMBER>/locations/global/workloadIdentityPools/<POOL>/providers/<PROVIDER>`,
   `token_url` = `https://sts.googleapis.com/v1/token`, and
   `credential_source.file` = the token path with no `format` or
   `{"type": "text"}` (the token file is a bare JWT, so a `json` format fails
   every run). It holds no key, so it is safe to paste.

For `GCP_STATIC`, use the service-account key file exactly as Google issued
it: it must keep `token_uri` (`https://oauth2.googleapis.com/token`), which
runs need even though the connection test passes without it.

## Step 4 — Static credentials and VCS tokens

### Handling credentials safely
Applies to AWS access keys, Azure client secrets, GCP service-account keys,
every VCS token and the GitHub App secrets. Before asking, tell the user:
- Prefer a recommended method from Step 1 when one fits.
- Use a **dedicated, least-privilege, ideally short-lived** credential made
  for StackGuardian — never a personal, root or admin key.
- The value becomes part of this AI conversation (and any transcript or log
  of it). If that is not acceptable, create the connector in the StackGuardian
  dashboard instead. Rotate the credential if the conversation is shared.
- No tool ever returns it; it cannot be read back, only replaced.

Then ask them to paste it **once**, pass it straight to the tool, and never
repeat, summarise or store it elsewhere in the conversation. Relay the
response's `credentialHandling` note.

### What each VCS provider needs
- **GitLab**: personal token with scope `api` (needs the GitLab username), or
  a group/project token with role Reporter or higher and scopes `api` +
  `read_repository`. Self-managed or Dedicated: also the web URL
  (`https://gitlab.example.com`) and API URL (`.../api/v4`).
- **Bitbucket**: an **API token** (needs username + Atlassian email) with
  Read on Account, Me, Project, Pull request, Repository, User, Workspace; or
  a **workspace access token** with Read on Account, Projects, Repositories.
  Repository/project access tokens can't list repositories — steer away.
- **Azure DevOps service principal**: the app (Step 3c, federated, or with a
  client secret — fixed at creation) added as a user to the DevOps org with
  Basic access and at least Reader on the projects; collect tenant,
  subscription and client ids. **PAT**: a token with at least Code (Read).
- **Custom GitHub App / GitHub Enterprise**: create the App with repository
  permissions Read on contents, metadata, webhooks and Read & write on checks,
  code scanning alerts, commit statuses, pull requests; organization Read on
  webhooks; subscribe to the push / pull request / create / delete / check
  events the user needs. Webhook URL:
  `<host>/api/v1/webhooks/github/?integrationId=/orgs/<org>/integrations/`
  (exactly what the dashboard shows — the platform does not read the query
  value, so don't append the connector id);
  webhook secret: a random string the user generates and also sets on the
  App. Collect App id, client id, client secret, installation id (from the URL
  after installing), private key (PEM as-is is fine). Enterprise: web URL
  `https://<host>` and API URL `https://<host>/api/v3`.

A plain git host with no provider connector uses a token stored as a secret
instead — switch to the `sg-manage-secrets` skill.

## Step 5 — Name, confirm, create

1. Ask for a connector name; the id defaults to its slug (lower-case letters,
   digits, `_`, `-`). Keep AWS OIDC ids short — the tool warns when the
   AWS session name would exceed 64 characters. Optional description and tags.
2. Show a summary: provider, method, name/id, the non-secret values (role
   ARN, tenant/subscription/client ids, project from the GCP file, VCS URLs),
   "a credential is set" (never the value), whether the connection will be
   tested, and discovery (off unless asked, Step 7). Wait for a yes.
3. Call `create_connector(name=..., config={"kind": <KIND>, ...fields},
   connectorId=..., description=..., tags=...)`. Testing the connection is on
   by default; pass `validateConnection=false` only for the AWS
   generated-external-id order (3b) or when the trust is knowingly not ready.

## Step 6 — Interpret the result

- **Success** → note `authentication`, relay `warnings`, continue to Step 8.
- **`authenticationFailed`** → the provider rejected the probe. Walk the
  checklist, fix, retry:
  - AWS OIDC: provider URL and audience exactly `<host>` for the right region;
    trust `aud`/`sub` conditions spelled as in 3a; correct account id in the
    provider ARN; role ARN copied right.
  - AWS role: both principals trusted; external id identical in trust and
    connector; role ARN right.
  - Azure: federated credential issuer/subject/audience exact (no trailing
    slash); role assignment on that subscription; client id is the app's or
    identity's, not the object id.
  - GCP: pool provider issuer/audience; `google.subject = assertion.sub`
    mapping; impersonation granted to subject `/orgs/<org>`; file is the
    downloaded `external_account` config.
  - Static/VCS: key or token expired, revoked, or missing scopes above;
    self-hosted URL reachable from the internet.
  If the user wants to save first and fix later, re-call with testing off —
  except GCP workload identity federation: the platform must reach Google to
  resolve the project, so it can't be saved until the trust works (the tool
  refuses and says why).
  After a failed create that carried a secret, retry under a **new**
  connector id — a retry on the same id can silently keep the first value.
- **`idTaken`** → show `existingConnector` (name, kind, auth method) and ask:
  reuse it (go to Step 8) or pick another id.
- **`warnings`** → relay in plain words: a URL host that doesn't resolve
  publicly (StackGuardian may not reach a private host; private runners may
  still work), the AWS session-name length, a GCP token path that isn't the
  StackGuardian one.

## Step 7 — Optional discovery (only if the user asks)

Only when the user wants cloud inventory / compliance scanning on this
connector: pass `discovery={"enabled": true, "regions": [...],
"intervalMinutes": 1440 | 10080}` (daily or weekly). AWS needs at least one
region code (e.g. `eu-central-1`); Azure and GCP use `["all"]`. Say it runs
scans in the background. It can also be added later with
`update_connector(connectorId=..., discovery=...)`.

## Step 8 — Hand back

1. If the connection wasn't tested at creation, or the trust was set up
   afterwards, run `authenticate_integration(integrationId=<connectorId>)` and
   relay its `diagnosis` when it fails.
2. Give the user the response's `referenceAs` and continue where they came
   from:
   - cloud → the deployment connector in `sg-create-workflow`, `sg-create-stack` or
     `sg-update-workflow` (`deployment={"connectorId": "/integrations/<id>"}`);
   - VCS → the private repo's git source credential in `sg-create-workflow` or
     `sg-create-stack` (`gitAuthRef="/integrations/<id>"`).
3. Later edits or rotation use `update_connector` (send only the new secret
   value; never send back a masked one).

## Out of scope — send the user to the dashboard

- Connector groups: multi-account AWS Organizations and Azure
  multi-subscription setups.
- GitHub.com via the StackGuardian GitHub App (browser install) and Azure
  DevOps OAuth (browser consent). The tool refuses both kinds.
