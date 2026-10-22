# Tirith (the policy document)

The platform runs **Tirith 1.0.5** in core (config rules); the terraform step template on `main`
pins **1.0.7** (message/context changes only — same semantics; which image is deployed may lag). Everything below
was read in that version's source, and the recipes were executed against it. The public GitHub
`main` of tirith is older/newer than 1.0.5 in places — don't trust other versions' docs blindly.

## 1. Document

```json
{
  "meta": { "version": "v1", "required_provider": "stackguardian/terraform_plan" },
  "evaluators": [
    { "id": "some_check", "description": "optional",
      "provider_args": { "operation_type": "attribute", "...": "..." },
      "condition": { "type": "Equals", "value": "x", "error_tolerance": 0 } }
  ],
  "eval_expression": "some_check"
}
```

- `meta` is required; an unknown or missing `required_provider` finds no input → **fail**.
- Keep exactly these three top-level keys. The step only recognises a document whose first key is
  `meta`, `evaluators` or `eval_expression`; the stored document's key order is not under your
  control, so any extra top-level key (`description`, `author`, …) risks silently disabling the rule.
- `error_tolerance` goes **inside** `condition` (default 0); on the evaluator it is ignored.
- `evaluators` is a flat list: no `operator` key, no nested evaluators. Boolean logic lives only in
  `eval_expression`. The older `schema_version: "V1.BETA"` / `all_of` / `any_of` / `none_of` shape
  in some platform docs is not read by any current engine.
- `meta.version` is echoed, not validated. Other `meta` keys (`name`, `severity`, `tags`) are
  ignored: a policy has no severity.
- No schema validation and no variables: `{{ var.x }}` placeholders are never filled → Tirith returns
  no `final_result` and the terraform plan step crashes, whatever `on_fail` says.
- Integers only (floats can break the policy create).

## 2. Providers and where they run

| `required_provider` | Input | Evaluated |
|---|---|---|
| `stackguardian/terraform_plan` | `terraform show -json` of the plan | runtime, after plan (not on drift runs, not on `plan-without-policy` runs) |
| `stackguardian/infracost` | the Infracost breakdown | runtime, after plan (Infracost must work; if it fails the rule gets `on_fail`) |
| `stackguardian/json` | the **workflow definition** | config time: workflow create/update and run build (§7). Also at run time in the **Ansible** step, against the playbook's variables/output — workflow key paths there hit severity 2 (use tolerance 2) |
| `stackguardian/sg_workflow`, `stackguardian/kubernetes`, `stackguardian/sg_stack`, missing | — | ❌ in the terraform step these fall through to "Tirith run errored" → `on_fail`: with `FAIL` they block **every** Terraform/OpenTofu run in scope. With a `key_path` that names a workflow/stack field, `sg_workflow` and `sg_stack` are also treated as config rules (§7) and always fail there: Tirith 1.0.5 has no `sg_stack` provider ("Could not find input value"), and `sg_workflow` reads only `workflow_attribute`, never `key_path`. No platform step feeds the `kubernetes` provider. Write config rules with `stackguardian/json` |

## 3. `terraform_plan` operation types

| `operation_type` | `provider_args` | Yields |
|---|---|---|
| `attribute` | `terraform_resource_type` (or `"*"`), `terraform_resource_attribute` (`acl`, `tags.Env`, `ingress.*.cidr_blocks`), optional `exclude_resource_types` (with `"*"`) | one value per matching resource from `change.after`; values unknown until apply are absent |
| `action` | `terraform_resource_type` (or `"*"`) | one value per action: `create`, `update`, `delete`, `no-op`, `read` (a replace yields `delete` + `create`). There is no `apply`/`destroy` |
| `count` | `terraform_resource_type` | integer (0 when absent — no tolerance needed). Counts every change of the type, including deletes and no-ops |
| `direct_dependencies` | `terraform_resource_type` | resource types in `depends_on` (root module) |
| `direct_references` | `terraform_resource_type` + exactly one of `references_to` / `referenced_by` (both = severity 99) | `referenced_by`: one boolean per planned resource of the type — is some `referenced_by` resource's config expression referring to it. `references_to`: one boolean — do all resources of the type refer to that type. See the public-access-block recipe (§8) for the limits |
| `terraform_version` | — | the plan's Terraform version string |
| `provider_config` | `terraform_provider_full_name` (`registry.terraform.io/hashicorp/aws`; OpenTofu plans say `registry.opentofu.org/hashicorp/aws`), `attribute` = `region` \| `version_constraint` | value from the **first** matching provider config; `region` only when it is a literal there (a variable or aliased providers are skipped/missed) |

`stackguardian/infracost`: `operation_type` `total_monthly_cost` / `total_hourly_cost`,
`resource_type = ["*"]` (or a list of types; module resources are never matched by a type
filter; only the first Infracost project is summed).

`stackguardian/json`: only `operation_type = "get_value"` with `key_path` (dots, numeric indexes,
`*` over lists/dicts). Not found → severity 2.

## 4. Conditions (exact, case-sensitive; unknown type = fail)

These 13 are the whole set. There is no `In`, `Exists`, `Matches`, `StartsWith` or
`NotRegexMatch`: use `ContainedIn`, `IsNotEmpty`, `RegexMatch "^x"`, or `!` in `eval_expression`.

| type | Passes when |
|---|---|
| `Equals` / `NotEquals` | equal / not equal (lists and dicts compared order-insensitively; no type coercion: `"true"` ≠ `true`) |
| `Contains` / `NotContains` | the **found** value contains yours: substring, list element, dict key (scalar value) or dict subset (dict value). A list value is one element, not a subset |
| `ContainedIn` / `NotContainedIn` | the found value is (not) in **your** list — allow-list / deny-list. A list-valued found value (e.g. `tags`, `ingress.*.cidr_blocks`) is one element, so `ContainedIn` is then always false; a string `value` means substring |
| `GreaterThan`, `GreaterThanEqualTo`, `LessThan`, `LessThanEqualTo` | Python comparison (strings compare lexicographically, booleans as 0/1; None / type mismatch = fail) |
| `IsEmpty` / `IsNotEmpty` | `None`, `""`, `[]`, `{}` count as empty; numbers and booleans are never "not empty" |
| `RegexMatch` | Python `re.search` on strings (lists/dicts are stringified); numbers, booleans and None fail |

## 5. Tolerance, skips and the verdict

Each missing-data case has a severity; `severity > error_tolerance` → that input **fails**,
otherwise it is **skipped**.

| Severity | Meaning |
|---|---|
| 0 | nothing to check: empty plan, or the resource is being deleted (`after = null`) — always skipped |
| 1 | resource type (or provider) not in the plan |
| 2 | attribute / key_path missing |
| 3 | config time only: the key_path's root is absent from the payload (forced skip) |
| 99 | malformed rule — always fails |

- A skipped evaluator is **removed** from `eval_expression` (`a && b` with `b` skipped → `a`). If
  everything is skipped the rule's result is empty, which counts as a **pass** (so `on_pass` applies —
  with `on_pass = "FAIL"` a fully skipped rule blocks).
- **1.0.5 bug:** within one evaluator the *last* non-passing resource wins, so a tolerated skip
  after a violation erases it (e.g. a violating ACL and a deleted ACL in the same plan, or
  `error_tolerance = 2` over resources where some lack the attribute). `action` and `count` are
  unaffected. Keep attribute rules type-specific with tolerance 1 where possible.

## 6. `eval_expression`

- Operators: `&&`, `||`, `!`, parentheses. Ids are substituted by word boundary, then all spaces are
  removed.
- `a and b` becomes an undefined symbol that is dropped → **silent pass**.
- An id that is a hyphen-prefix of another (`acl-ok`, `acl-ok-2`) makes the expression evaluate to
  `-1`, which the platform treats as a **pass**: the longer id's evaluator is silently ignored (at
  run time and at config time). Use snake_case ids, none a prefix of another. (Dashboard-made policies use
  `eval-id-1`, `eval-id-2`, … — fine as long as no id prefixes another.)
- Every id referenced must exist (undefined ids are dropped silently); unreferenced evaluators are
  ignored.

## 7. Config-time documents (`stackguardian/json`)

The rule is evaluated only if its `key_path` contains a workflow field name (the heuristic list:
`ResourceName, Description, Tags, IsActive, WfStepsConfig, WfType, TerraformConfig, TerraformAction,
EnvironmentVariables, DeploymentPlatformConfig, VCSConfig, UserSchedules, UserJobCPU, UserJobMemory,
VCSTriggers, MiniSteps, Approvers, NumberOfApprovalsRequired, RunnerConstraints, ContextTags, …`).

| Moment | Document |
|---|---|
| workflow create | the request: `ResourceName, Description, Tags, WfType, VCSConfig, TerraformConfig, EnvironmentVariables, DeploymentPlatformConfig, RunnerConstraints, MiniSteps, Approvers (strings), UserSchedules, ContextTags, …` |
| workflow update | stored workflow merged with the patch |
| run build | workflow + `TerraformAction = { action = apply\|plan\|destroy\|plan-destroy\|refresh }`; `Approvers` becomes a list of objects (`Approvers.*.email`) |

Verified key paths: `TerraformConfig.managedTerraformState`, `TerraformConfig.terraformVersion`,
`TerraformConfig.approvalPreApply`, `TerraformConfig.driftCheck`, `WfType`, `Tags`,
`ContextTags.<key>`, `DeploymentPlatformConfig.*.config.integrationId`, `RunnerConstraints.type`,
`VCSConfig.iacVCSConfig.iacTemplateId`, `VCSConfig.iacInputData.data.<var>`,
`EnvironmentVariables.*.config.varName`, `TerraformAction.action` (run only).

Choose the tolerance per rule: `2` skips workflows that lack the sub-key — which also skips a
TERRAFORM workflow that merely omitted a setting whose server default is the unsafe value. When
"missing" should count as a violation, use tolerance 1 and exempt the workflow types that
legitimately lack the key in `eval_expression` (the managed-state recipe below). The forced skip
(severity 3) only applies when the key's **root** (`TerraformConfig`) is absent from the payload.
At config time `WARN` is recorded as `warned` in the workflow's
`PolicyEvalResults.configPoliciesEvaluated` (visible in the dashboard, not to the API/Terraform caller); `APPROVAL_REQUIRED` is a 403 on create/update and an approval
gate before the first step at run time.

**Stacks** (from code): a `json` rule whose `key_path` names a stack field (`WorkflowsConfig`,
`Actions`, `TemplateGroupId`, `TemplatesConfig`, `Operations`, `WorkflowRelationsMap`, …) is also
evaluated at stack create and stack run. Fields both lists share (`ResourceName`, `Description`,
`Tags`, `IsActive`, `EnvironmentVariables`, `DeploymentPlatformConfig`, `UserSchedules`,
`MiniSteps`, `ContextTags`) make the rule judge workflows **and** stacks in scope.

**References** (resolved by the platform before Tirith runs; from code, not executed here):

| Syntax | Value |
|---|---|
| `${curr_workflow.attrs.<path>}` / `${curr_stack.attrs.<path>}` | a field of the workflow / stack being judged (in a `key_path` it limits the rule to workflows / stacks) |
| `${workflow::<group>.<workflow>.attrs.<path>}` | a field of another workflow (nested group: `parent/child` before the dot) |
| `${workflow::<group>.<stack>.<workflow>.attrs.<path>}` | a workflow inside a stack |
| `${stack::<group>.<stack>.attrs.<path>}` | a field of a stack |

- Allowed in `key_path` (with `get_value`; the resolved string becomes the *value* checked) and in
  a string `condition.value`. Innermost `${…}` resolves first, so references nest.
- An unresolvable reference, a missing workflow, or a falsy/non-string value raises `Tirith
  evaluation error: Failed to resolve reference: …` → the rule **blocks** every workflow in scope.
  Prefer plain key paths unless you need another resource's state.
- In HCL escape the dollar: `"$${curr_workflow.attrs.ContextTags.env}"`. A bare `"${…}"` is a
  Terraform interpolation and fails at plan.

## 8. Verified recipes

All executed on Tirith 1.0.5 with passing and failing inputs (`examples/`; the public-access-block
and Terraform-version recipes against hand-built plan / workflow JSON only):

| Goal | Evaluator |
|---|---|
| No public S3 ACL | `attribute`, `aws_s3_bucket_acl`, `acl`, `NotContainedIn ["public-read","public-read-write","authenticated-read"]`, tol 1 |
| Public access block on | `attribute`, `aws_s3_bucket_public_access_block`, `block_public_acls`, `Equals true`, tol 1 |
| Tag key present | `attribute`, `<type>`, `tags`, `Contains "CostCenter"`, tol 1 |
| Tag key = value | `attribute`, `<type>`, `tags`, `Contains { Environment = "production" }`, tol 1 |
| No world-open ingress | `attribute`, `aws_vpc_security_group_ingress_rule`, `cidr_ipv4` `NotEquals "0.0.0.0/0"` and `cidr_ipv6` `NotEquals "::/0"`, tol 1 (tol 2 lets the skip-erasure bug hide violations; a cidr unknown at plan then fails — safe side). Legacy inline rules: `aws_security_group`, `ingress.*.cidr_blocks`, `NotContains`. Not `aws_security_group_rule` `cidr_blocks`: it matches egress rules too, so the usual allow-all egress fails |
| Every bucket has a public access block | `direct_references`, `aws_s3_bucket`, `referenced_by = "aws_s3_bucket_public_access_block"`, `Equals true`, tol 1. Only for single (no `count`/`for_each`) buckets: the plan address `aws_s3_bucket.b[0]` never matches the config reference `aws_s3_bucket.b`, so those always fail. Deleting a bucket fails too (1.0.5 skips `["destroy"]`, but plans say `delete`). Roll out with `on_fail = "WARN"` |
| Pinned Terraform version | `json`: `is_custom` (`WfType`, `Equals "CUSTOM"`, tol 2) `\|\|` `tf_version_ok` (`TerraformConfig.terraformVersion`, `RegexMatch "^1\\.(5\|9)\\."` as written in HCL, tol 1) — a TERRAFORM/OPENTOFU workflow without a version fails |
| EU regions only | `provider_config`, `region`, `ContainedIn [...]`, tol 2 — two evaluators, `registry.terraform.io/hashicorp/aws` and `registry.opentofu.org/hashicorp/aws`, joined with `&&` |
| Allowed instance types | `attribute`, `aws_instance`, `instance_type`, `ContainedIn [...]`, tol 1 |
| Max N buckets | `count`, `aws_s3_bucket`, `LessThanEqualTo N` (deletes and no-ops count too) |
| Approval on any delete/replace | `action`, `"*"`, `NotContainedIn ["delete"]`, tol 1, `on_fail = "APPROVAL_REQUIRED"` |
| Approval on any change | `action`, `"*"`, `ContainedIn ["no-op","read"]`, `on_fail = "APPROVAL_REQUIRED"` |
| Monthly cost ≤ 500 | `infracost`, `total_monthly_cost`, `resource_type = ["*"]`, `LessThanEqualTo 500` |
| Managed state required | `json`: `is_custom` (`WfType`, `Equals "CUSTOM"`, tol 2) `\|\|` `uses_managed_state` (`TerraformConfig.managedTerraformState`, `Equals true`, tol 1) — a TERRAFORM workflow that omits the key (server default: unmanaged) fails, CUSTOM passes |
| Approved connectors only | `json`, `DeploymentPlatformConfig.*.config.integrationId`, `ContainedIn [...]`, tol 2 (workflows with no connector pass; add `DeploymentPlatformConfig` `IsNotEmpty` if every workflow must have one) |
| Private runners only | `json`, `RunnerConstraints.type`, `Equals "private"`, tol 1 — a workflow that omits the runner (server default: shared) fails |
| Approval before destroy runs | `json`, `TerraformAction.action`, `NotContainedIn ["destroy","plan-destroy"]`, **tol 2** (CUSTOM runs carry no action), `on_fail = "APPROVAL_REQUIRED"` (skipped at create/update, gates step 0 at run) |

Test a document locally before shipping it (PyPI has no installable py-tirith files; install the
tag the platform pins):

```bash
pip install "git+https://github.com/StackGuardian/tirith.git@1.0.5"
terraform show -json tfplan > plan.json            # a real plan of the workflow's IaC
tirith -policy-path policy.json -input-path plan.json --json
```

For config rules, pass a JSON file shaped like the workflow payload in §7 as `-input-path` (the
CLI does not apply the platform's severity-3 forced skip or its "no result = allow" mapping).
