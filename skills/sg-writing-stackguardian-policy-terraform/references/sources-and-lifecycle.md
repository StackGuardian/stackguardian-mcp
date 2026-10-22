# Rule sources, scope, verdicts and provider behaviour

"(live)" = reproduced with provider 1.12.3 against a real org; "(unverified)" = inferred from
code. The rest was read in api / core / sg-run-controller / workflow-step-templates source.

## 1. Where a rule's body comes from

Each `policies_config[]` rule has exactly one source.

### Inline Tirith (most rules)

```terraform
policy_vcs_config = {
  use_marketplace_template = false
  custom_source = { source_config_kind = "SG_POLICY_FRAMEWORK", source_config_dest_kind = "INLINE" }
}
policy_input_data = { schema_type = "TIRITH_JSON", data = jsonencode({ meta = {...}, evaluators = [...], eval_expression = "..." }) }
```

Omitting `policy_vcs_config` also works (the platform defaults to inline Tirith; live), but
declaring it keeps config and state describing the same thing. Declare `skip = false` too: until
September 2026 the platform silently skipped a config rule that lacked either the `skip` key or
`policy_vcs_config`. Now only `skip = true` disables a rule (from code).

### Tirith from git

`source_config_kind = "SG_POLICY_FRAMEWORK"` + a git `source_config_dest_kind` + `config`. The file
**must be named `tirith.json`** inside `working_dir`. Git-hosted Tirith is runtime-only: config
rules (`stackguardian/json`) must be inline.

### OPA / Rego from git

```terraform
custom_source = {
  source_config_kind      = "OPA_REGO"
  source_config_dest_kind = "GITHUB_COM"            # never INLINE
  config = { repo = "https://github.com/acme/opa", ref = "main", working_dir = "terraform", is_private = true, auth = "/integrations/github_com" }
  additional_config = jsonencode({ opaQuery = "terraform.guardrails.allow" })
}
```

- The step runs `opa eval --data <working_dir> --input tf_plan.json data` with **OPA 0.55** (Rego v0:
  use `import future.keywords.if` / `…contains`; `import rego.v1` needs OPA ≥ 0.59 and fails to parse). `input` is the plan JSON
  (`input.resource_changes`, `input.planned_values`, `input.configuration`).
- `opaQuery` is a dotted path relative to `data`, **without** `data.`: `package terraform.guardrails`
  + rule `allow` → `terraform.guardrails.allow`. It must be a boolean (`default allow = false`);
  `deny[msg]` sets, strings or an undefined rule → `on_fail`.
- **No `opaQuery` → every Rego policy passes** unless OPA itself errors.
- Provider bug (live): `additional_config` is stored but read back as null → first apply ends with
  *Provider produced inconsistent result after apply* and the policy is tainted. Then:
  `terraform untaint <address>` and `lifecycle { ignore_changes = all }`; change the policy only with
  `terraform apply -replace=<address>` (and untaint again). Verify the stored `additionalConfig`
  afterwards (MCP `get_orchestrator_resource_by_id` or the API).
  - `ignore_changes = [policies_config]` is **unsafe** (live): the next change to description, tags,
    scope or approvers PATCHes the rules from state (`additional_config = null`) and the server
    drops `opaQuery` — the Rego policy silently passes everything from then on.
  - Without any `ignore_changes`, every apply re-sends `opaQuery` and reports the inconsistent
    result again (from code) — safe but noisy.
  - Managing OPA policies outside Terraform (dashboard / MCP `create_policy`) until the provider is
    fixed is a reasonable choice.
- `policy_input_data` (optional) is written into the Rego directory, where OPA should load it
  under `data` (unverified).

### Git source rules (Tirith or OPA)

- `is_private` is required (`{"isPrivate": ["required"]}`) and so is `repo`; private needs `auth`
  (`/integrations/<connector>` or `/secrets/<name>` — nothing else matches its pattern);
  `GIT_OTHER` accepts only `/secrets/`. A `working_dir` that is not a plain relative/absolute path
  fails with `Invalid Linux file path for working directory.` (from code).
- Kinds: `GITHUB_COM`, `GITHUB_APP_CUSTOM`, `GITLAB_COM`, `BITBUCKET_ORG`, `AZURE_DEVOPS`,
  `GIT_OTHER`. The API also accepts `AZURE_DEVOPS_SP` since October 2026, but provider 1.12.3
  rejects it before the request (`… is not a valid …`). A **private `GITHUB_APP_CUSTOM`** policy repo fails at run
  (`No credentials exposed to authenticate against private repo …`).
- The attribute is `include_submodule` here (workflows: `include_sub_module`). Leading/trailing
  `/` in `working_dir` are stripped (`terraform/` = `terraform`).

### Marketplace policy templates

```terraform
policy_vcs_config = {
  use_marketplace_template = true
  policy_template_id       = "/stackguardian/aws-best-practices-all:2"
}
```

- Form `/<owner-org>/<template>:<revision>`, type `IAC_POLICY`. Pin a number (`:latest`/aliases are
  resolved per run). The id is **not checked at create**: a wrong or deleted template breaks every
  run in scope (`'<id>' not found. Make sure that it is registered in Marketplace`). Check the
  revision exists first (e.g. `aws-best-practices-all` has revisions 1 and 2, not 3):
  `curl -H "Authorization: apikey $KEY" -H "x-sg-orgid: <your-org>" "$STACKGUARDIAN_API_URI/api/v1/templatetypes/IAC_POLICY/stackguardian/aws-best-practices-all:2/"`.
- No subscription is required; the template must be public, yours, or shared with you.
- `use_marketplace_template = true` without `policy_template_id` → `{"policyTemplateId": ["required
  when useMarketplaceTemplate"]}`; `false` without `custom_source` → `{"customSource": ["required
  when not useMarketplaceTemplate"]}` (from code).
- StackGuardian's bundles are checkov (`SG_INTERNAL_P2`) run on the plan; templates with an input
  schema ignore your `policy_input_data`.
- The dashboard also stores a `policyTemplate` field; the provider has no such attribute and does
  not need it.

## 2. Scope — `enforced_on`

Resolved fresh at every workflow create/update and every run build, by **exact string match**
(no validation, no existence check):

| Entry | Matches |
|---|---|
| `"*"` | every workflow and stack of the org — use it alone |
| `/wfgrps/<g>` | the group and everything under it (each ancestor prefix of a workflow's group path is tried) |
| `/wfgrps/<parent>/<child>` | a nested group (flat path, not `/wfgrps/p/wfgrps/c`) |
| `/wfgrps/<g>/wfs/<wf>` | one workflow |
| `/wfgrps/<g>/stacks/<s>` / `…/stacks/<s>/wfs/<wf>` | a stack (with its workflows) / one stack workflow |
| `/integrations/<c>` | workflows with that connector in any `deployment_platform_config[].config.integration_id` |
| `/integrationgroups/<g>` or `/integrationgroups/<g>/integrations/<c>` | connector-group scopes |

- Effective policies = union of all matches; a narrower scope cannot relax a broader one.
- `[]` or no attribute → **nothing**. Legacy policies stored without the attribute appear to be
  treated as org-wide until touched (from code).
- A typo (`/wfgrps/platfrom`, trailing `/`, `/orgs/...`, a bare workflow name) matches nothing and
  nobody tells you — build entries from resource ids.
- Workflows in the internal `__SG_OWNED__` group are exempt.

## 3. Verdicts

- `on_fail` applies when the rule evaluates false; `on_pass` when it evaluates true **or is fully
  skipped**. Values: `FAIL` (block), `WARN` (record, continue), `PASS`, `APPROVAL_REQUIRED`.
  They are remappings, not severities: `on_pass = "FAIL"` inverts a rule, `on_fail = "PASS"`
  disables it (use `skip = true` instead).
- Both are required by the API: omitting `on_pass` → `400 PoliciesConfig[0].onPass: "" is not a
  valid choice.` (live).
- Within one rule, results combine as FAIL > WARN > APPROVAL_REQUIRED > PASS. Across rules: any
  FAIL errors the run (before any approval is requested); otherwise any APPROVAL_REQUIRED pauses it —
  a WARN elsewhere does not suppress the approval.
- Runtime results land in the run's `PolicyEvalResults`; config-time results in
  `PolicyEvalResults.configPoliciesEvaluated.<policy>.rules.<rule>` on the workflow (a config-time
  `WARN` shows there as `warned`; the API/Terraform caller sees nothing).
- Config-time 403 text: `Workflow policy (<policy>:<rule>) failed: Expression: <expr> | <evaluator
  messages>`, or `requires approval` in place of `failed`; several rules are joined by newlines.
  Stacks say `Stack policy (…)` (from code).
- A crash inside Tirith (bad provider, bad document, unresolvable `${…}` reference) → `on_fail` at
  runtime, a block at config time (`Tirith evaluation error: …`).

## 4. Approvals

- Policy-level: `approvers` + `number_of_approvals_required` are shared by every rule of the
  policy. `N` = N distinct approvers; `0` = **all** listed approvers; a count larger than the list
  never completes. Any rejection cancels the run.
- Approvers: lowercase emails, `<userpool>/<idp>/<email>`, or SSO groups `<userpool>/group/<id>`.
- Runtime `APPROVAL_REQUIRED` gates the **next** step (normally `apply`); if the plan step is the
  last one (plan-only runs, PR plans) nothing pauses.
- Config-time `APPROVAL_REQUIRED` is a 403 on workflow create/update and an approval gate before
  step 0 at run time.
- Without approvers the run still pauses; with an empty approver map anyone with approve permission
  can release it (sg-run-controller main), and the executor is emailed. Always set approvers.
- Runtime approvals match `/policies/<resource_name>` against the policy's id: keep `resource_name`
  a slug, don't set a different `id`, and don't rename a policy that uses APPROVAL_REQUIRED — any of
  these makes approvers never match.
- The platform's own "approve before apply" for plans with changes is
  `terraform_config.approval_pre_apply` on the workflow, not a policy.

## 5. Provider behaviour (`stackguardian_policy`, 1.12.3)

| Topic | Behaviour |
|---|---|
| Validation | none; enums are parsed at apply: `Fail to convert policyConfig terraform type to go type` / `<v> is not a valid …` |
| `policy_type` | only `"GENERAL"` (hardcoded on create/update/read). `FILTER.INSIGHT` → inconsistent result |
| Omitted `enforced_on`, `tags`, `approvers`, `description`, `policies_config` | sent as `null` whenever anything else changes → cleared server-side (live: scope wiped to `[]`). Always declare them |
| `on_fail` / `on_pass` | optional in HCL, required by the API (400 when missing, live) |
| `policy_input_data.data` | must be a JSON **object** string (`jsonencode`); invalid JSON fails at apply; read back re-marshalled with sorted keys |
| `additional_config` | inconsistent result (see §1 OPA) |
| Empty values | `tags = []`, `approvers = []`, `enforced_on = []`, `description = ""` round-trip (live); `policies_config = []` → inconsistent result (live) |
| `id` | derived from `resource_name` (verbatim when it is a slug, else random-suffixed); renaming `resource_name` is in place and keeps the id; changing `id` forces replacement |
| API limits (from code) | `resource_name` ≤ 100 chars, `description` ≤ 512 (the provider docs say 256), `tags` ≤ 10, `policies_config` ≤ 25 rules. A rule `name` must be a slug (`[-a-zA-Z0-9_]`, 1–100) or the API returns 400 — the 1.12.3 docs call it free-form |
| `context_tags` | the API has `ContextTags` on a policy; the provider has no attribute for it. `${curr_workflow.attrs.ContextTags.<k>}` references read the *workflow's* context tags |
| Import | `terraform import stackguardian_policy.x <policy-id>` |
| Out-of-band delete | dropped from state on refresh |
| Destroy | hard delete; new runs and workflow writes stop seeing it immediately (runs already built keep a snapshot). The dashboard refuses to delete a policy that still has scope; the API does not |

## 6. Rolling out safely

- A config rule in scope blocks `terraform apply` of the `stackguardian_workflow_*` resources it
  judges (`403 Workflow policy (<policy>:<rule>) failed: Expression: … | …`, live) — including in
  the same Terraform run that creates the policy. Create/fix workflows first (`depends_on` on the
  policy makes it land after them in one apply; later updates are still judged), or roll out with
  `on_fail = "WARN"`.
- Existing groups/workflows: keep the path in a local, build the scope from it, and add a data source
  on the same local as an existence check (a typo then fails at plan). Don't interpolate
  `data.stackguardian_workflow_group.x.id` — for a nested group it is only the leaf (live).
- Start narrow (`/wfgrps/<test-group>`), use `WARN`, read `PolicyEvalResults` on a few runs, then
  switch to `FAIL` and widen the scope. `["*"]` hits every team's workflows.
- There is no enable/disable flag: `skip = true` per rule, or `enforced_on = []`.

## 7. Error catalog

| Message | Cause | Fix |
|---|---|---|
| `PoliciesConfig[0].onPass: "" is not a valid choice.` | `on_pass` omitted | set both `on_fail`, `on_pass` |
| `Fail to convert policyConfig terraform type to go type` | invented enum (`TIRITH_FORMAT`, `BLOCK`, …) | use the documented values |
| `{"isPrivate": ["required"]}` / `auth required for isPrivate` / `only secrets are supported for GIT_OTHER` | git source config | §1 |
| `{"sourceConfigDestKind": ["Invalid for OPA_REGO"]}` | OPA with `INLINE` | git kind |
| `{"ResourceName": ["<x> cannot be used"]}` | reserved name, case-insensitive: any API path word (`orgs`, `wfgrps`, `stacks`, `wfs`, `wfruns`, `policies`, `secrets`, `integrations`, `templates`, `listall`, `logs`, `outputs`, `resume`, …) | rename |
| `409 Policy ID not unique` | a policy with that id (= slug `resource_name`) already exists | `terraform import` it, or rename |
| `{"policyTemplateId": ["required when useMarketplaceTemplate"]}` / `{"customSource": ["required when not useMarketplaceTemplate"]}` / `{"repo": ["required"]}` | incomplete `policy_vcs_config` | §1 |
| `Invalid Linux file path for working directory.` | `working_dir` with unusual characters | plain path |
| `Enter a valid "slug" …` on `PoliciesConfig[n].name` | rule name with spaces/dots | `[-a-zA-Z0-9_]` |
| workflow apply: `403 Workflow policy (<p>:<r>) requires approval …` | config rule with `APPROVAL_REQUIRED` | approvals are only granted on runs; use `WARN`/`FAIL` for create/update |
| `Tirith evaluation error: Failed to resolve reference: …` | a `${…}` reference in a config rule did not resolve | fix the reference (tirith.md §7) |
| `Provider produced inconsistent result after apply` | `additional_config`, `policy_type` ≠ GENERAL | §1 / GENERAL |
| workflow apply: `403 Workflow policy (<p>:<r>) failed …` | a config rule rejected the workflow | fix the workflow or the rule |
| run: `Encountered noncompliant configuration during policy evaluation` | a runtime rule with `on_fail = "FAIL"` | read `PolicyEvalResults` |
| run: `Tirith run errored during policy evaluation` | unusable provider (`sg_workflow`, `sg_stack`, `kubernetes`, missing), Infracost failure | fix the document |
| run: `'<id>' not found. Make sure that it is registered in Marketplace` | bad `policy_template_id` | real `/<org>/<name>:<n>` |
| run: `No match found for "<q>" in OPA results` | `opaQuery` names an undefined rule | package/rule path without `data.` |
