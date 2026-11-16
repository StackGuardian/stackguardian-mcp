---
name: sg-manage-connectors
description: Guided flow for managing an existing StackGuardian connector (integration) with get_connector, authenticate_integration, update_connector, trigger_connector_discovery_scan and delete_connector. Covers inspecting a connector (auth method, which credentials are set, last test result, discovery), testing it, editing it (rename, description, tags, context tags, role ARN, tenant / subscription / client id, session duration, GitLab / Azure DevOps / GitHub Enterprise URLs), rotating a credential (AWS access key, Azure client secret, GCP service-account key, GitLab / Bitbucket / Azure DevOps token, GitHub App private key / client secret / webhook secret), enabling, disabling or re-scoping cloud inventory discovery and starting a discovery scan, and deleting a connector after an impact report of the workflows, stacks, runner groups, templates and policies that use it. Use when the user wants to edit, rename, retag, rotate, re-key, update, test, check or delete a connector or integration, switch its role ARN or tenant, turn discovery on or off, scan a cloud account now, or asks "what uses this connector".
---

# Manage Connectors — Guided Flow

A connector is an org-wide stored credential: **cloud** (AWS, Azure, GCP —
a workflow's deployment connector) or **version control** (GitLab,
Bitbucket, Azure DevOps, custom GitHub App — clones private repos). Creating
one is the `sg-create-connector` skill; a connector that fails, or a run that
failed because of one, is the `sg-troubleshoot-connector` skill. This skill
covers everything in between. Follow the steps IN ORDER, skipping those the
user didn't ask for, but always start with Step A.

Never surface parameter or field names (`connectorId`, `config`,
`secretFieldsSet`, `awsSecretAccessKey`, `validateConnection`,
`confirmDelete`...) to the user. Speak of "the connector", "the role ARN",
"the client secret", "testing the connection", "confirming the delete".
Fetch ids with tools; never ask the user to recall them.

## Step A — Find and inspect

1. Find it: `search_orchestrator_resources(resourceTypes=['INTEGRATION.CLOUD',
   'INTEGRATION.VCS'], searchQuery=<name, provider or account hint>)`. A
   connector created a moment ago may not be indexed yet; if the user knows
   the id, go straight to step 2.
2. `get_connector(connectorId='/integrations/<id>')` (add
   `includeScanInfo=true` when discovery matters, e.g. Step E). Tell the user,
   in plain words:
   - **What it is**: name, provider, and the auth method (OIDC / role with
     external id / access keys / token / GitHub App / service principal,
     federated or with a secret / managed identity).
   - **Its settings**: the non-secret values — role ARN, tenant /
     subscription / client ids, GCP project, region, session duration, VCS
     URLs, description, tags.
   - **Which credentials are set** — by name only ("an access key secret is
     stored"). Values are never readable; nothing can show them, only replace
     them.
   - **Last test**: passed / failed and when, or never tested.
   - **Discovery** (cloud only): on or off, regions, daily or weekly, last
     scan.
3. The id in the response is permanent. Keep it for every later call.

A connector **group** (multi-account AWS Organizations or Azure
multi-subscription) can be read here but not changed — see Out of scope.

## Step B — Test

1. `authenticate_integration(integrationId='/integrations/<id>')`. It is a
   live check at the provider that also updates the stored status: once per
   ask, never in a loop.
2. Read `diagnosis` first. Passed with no diagnosis → say so and stop.
3. Not every failure is a credential verdict:
   - **Rate-limited (429)** or **not responding** → no verdict; retry later,
     and for not-responding check a self-hosted host is reachable from the
     internet. Never tell the user to rotate on these.
   - **Private** → StackGuardian deliberately doesn't probe this git host
     (only private runners reach it). No verdict either way.
4. A real failure (rejected token, missing scope, cloud rejected the trust)
   → switch to the `sg-troubleshoot-connector` skill, which has the
   cause-by-cause table. Don't guess fixes here.

## Step C — Edit settings

For name, description, tags, context tags, and non-secret config: role ARN,
session duration, tenant / subscription / client ids, region, VCS URLs.
An Azure DevOps connector's URLs can't be changed here (the platform drops
them on edit) — create a new connector for a different host.

1. Confirm the change in plain words, then call
   `update_connector(connectorId=..., <only what changes>)`:
   - name / description: `name=`, `description=`;
   - tags: `tags=[...]` replaces the whole list — start from the current
     tags when the user adds or removes one;
   - context tags: `contextTags={"key": "value"}` merges; `{"key": null}`
     removes that key;
   - config: `config={<only the keys that change>}`, e.g.
     `{"roleArn": ...}`, `{"armTenantId": ...}`, `{"durationSeconds": 7200}`.
     The tool keeps every stored key you don't send, secrets included.
2. Testing the connection is on by default whenever the config changes, and
   a failed test means nothing was saved. Leave it on. Turn it off only when
   the user is knowingly changing the cloud side afterwards (e.g. a new role
   ARN whose trust is created next), and test with Step B once it's done.
3. What can't change:
   - The connector's id: workflows reference it, so it is fixed. A rename
     changes only the display name.
   - Its kind (e.g. access keys → OIDC, PAT → service principal): create a
     new connector (`sg-create-connector`), repoint each workflow to it with the
     `sg-update-workflow` skill (Step F's report lists them), then delete the old
     one (Step F).
   - An Azure DevOps service principal's mode (federated vs client secret).
4. Relay `warnings` in plain words. Notably: an edit resets a connector
   that was limited to some workflow groups back to **org-wide** (a platform
   behaviour) — tell the user, and that they can re-limit it in the dashboard.
5. Report back from the response: what changed, and the test result.

## Step D — Rotate a credential

### Handling the credential
Before asking for the new value, tell the user:
- Use a **dedicated, least-privilege, ideally short-lived** credential made
  for StackGuardian — never a personal, root or admin key.
- The value becomes part of this AI conversation (and any transcript or log
  of it). If that is not acceptable, rotate it in the StackGuardian dashboard
  instead. Rotate it again if this conversation is ever shared.
- No tool ever returns it; it cannot be read back, only replaced.

Then ask them to paste it **once**, pass it straight to the tool, and never
repeat, summarise or store it elsewhere in the conversation. Relay the
response's `credentialHandling` note.

### Rotating
1. Send **only** the new secret field in `config`, e.g.
   `{"awsSecretAccessKey": ...}` (plus `"awsAccessKeyId"` when the key pair
   changes), `{"armClientSecret": ...}`, `{"gcpConfigFileContent": <new key
   file>}`, `{"token": ...}`, `{"azureCreds": ...}`,
   `{"githubAppPemFileContent": ...}`, `{"githubAppClientSecret": ...}`,
   `{"githubAppWebhookSecret": ...}`. Field names per kind are in the
   `create_connector` tool description.
2. **Never send back anything `get_connector` showed as hidden or
   `[REDACTED]`** — that is a mask, not the secret, and sending it would
   overwrite the real value. The tool refuses it; don't try to work around
   that. Omitted secrets stay as stored.
3. Per-provider notes:
   - **AWS access keys**: suggest moving to OIDC or a role with external id
     instead — nothing secret passes through the chat and nothing expires.
     That is a new connector (Step C, "what can't change").
   - **GitLab**: the token type (personal / group / project) and hosting
     (gitlab.com / self-managed / dedicated) are fixed at creation; a
     different type means a new connector. A personal token's username
     travels with the token — send both when either changes.
   - **Bitbucket**: re-validates its credential on **every** settings
     change, so any Bitbucket config edit (not just a rotation) must include
     the token — the current one or a new one — and, for an API token, the
     username and Atlassian email if they changed.
   - **GitHub App**: rotate each secret separately as GitHub issues it; a new
     webhook secret must also be set on the App itself.
4. Testing stays on: a rejected new value is not saved. On failure →
   `sg-troubleshoot-connector`.
5. Tell the user: workflows use the new credential from their next run;
   runs already in progress keep the old one. Once the next run works, they
   should revoke the old key or token at the provider.

## Step E — Discovery (cloud connectors only)

Discovery runs scheduled cloud inventory scans. It is off unless the user
asks.

1. To turn it on, change regions or interval, or pause it:
   `update_connector(connectorId=..., discovery={"enabled": true | false,
   "regions": [...], "intervalMinutes": 1440 | 10080})` — daily or weekly
   (default weekly). Send only what changes — anything left out keeps its
   current value, so pausing is just `discovery={"enabled": false}`.
   - **AWS**: one or more region codes (`eu-central-1`, `us-east-1`...) when
     turning it on for the first time or changing regions.
   - **Azure / GCP**: always every region — omit regions or pass `["all"]`.
2. To scan **now**, only when the user explicitly asks: it starts scan runs
   in their account. Call `trigger_connector_discovery_scan(connectorId=...)`
   and report how many scans started and how many were skipped. It refuses
   when discovery isn't configured — set it up in step 1 first. Results show
   up in the cloud inventory once the scans finish; they are not instant.

## Step F — Delete

1. Suggest the safer order first: repoint every dependent to another
   connector (`sg-update-workflow`), then delete.
2. Call `delete_connector(connectorId=...)` **without** confirming the
   delete. Nothing is deleted; the response is an impact report.
3. Show the user what still references it — workflows, stacks, runner
   groups (including their storage backends), templates (one row per
   template, with the `revisions` whose git source uses it), and policies —
   both those attached to the connector (`via: "enforcedOn"`) and those
   whose rules pull their policy code from git through it
   (`via: "ruleGitAuth"`, naming the `rules`) — and the coverage limits from
   `sweepCoverage`: the report can't see Terraform state backends configured
   in code, `SG_CONNECTOR_NAME` environment variables, the git auth of
   IAC_POLICY / WORKFLOW_STEP templates, or users of a shared template in
   other orgs. Ask them to check those themselves.
   - **Impact unknown**: if `total` is `null` (`sweepFailed` names the part
     that failed or timed out), say so plainly — the list may be incomplete,
     never "nothing uses it". Retry the call first. A confirmed delete is
     refused while the impact is unknown; the only way past it is
     `ignoreSweepFailures=true`, and pass that **only** after the user
     explicitly says to delete without knowing what still uses the
     connector — never on your own.
4. Say plainly:
   - Deleting is permanent. Every dependent still pointing at it **fails at
     its next run**; the platform does not repoint or block anything.
   - Deleting **never touches the cloud or git side**: the IAM role and OIDC
     provider, Azure app registration / federated credential / managed
     identity, GCP workload identity pool or service account, access keys,
     tokens and GitHub App all stay. Tell the user to remove or revoke them
     themselves if they are no longer needed.
5. Only after an explicit yes, call `delete_connector(connectorId=...,
   confirmDelete=true)` (plus `ignoreSweepFailures=true` only in the
   impact-unknown case above, with that explicit acceptance). If it reports
   the connector was already gone, say so — nothing was deleted by this call.

## "What uses this connector?"

Without deleting: `cross_reference(targetKind='cloud_integration' |
'git_integration', targetId='/integrations/<id>')` lists the workflows,
stacks and runner groups (cloud) or workflows, stacks and templates (version
control) that reference it; `count=true` gives just the number. Policies
attached to the connector or authenticating their rules' git through it, and
the gaps above, are only covered by Step F's report.

## Out of scope — send the user to the dashboard

- Connector groups (multi-account AWS Organizations, Azure
  multi-subscription): read-only here; edit, rotate or delete them, and their
  child connectors, in the dashboard.
- Re-authorising GitHub.com (StackGuardian GitHub App) and Azure DevOps
  OAuth connectors: their credentials come from a browser flow.
- Limiting a connector to specific workflow groups.
