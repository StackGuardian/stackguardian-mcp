# Examples

Each file is a self-contained root module when combined with `versions.tf` (validate them one at a
time: several files declare the same data source names). All pass `terraform validate` (1.14) and
`tofu validate` (1.9) against provider 1.12.3 exactly; `~> 1.12.3` also accepts later 1.12.x
patches, which these notes were not checked against. The ones marked
**applied** were also applied against a real org (group/template names prefixed, connectors and
runners swapped for existing ones, schedules disabled), re-planned with no changes, and destroyed.

| File | Scenario | Verified |
|---|---|---|
| `git_terraform.tf` | Private GitHub repo via connector, AWS OIDC, managed state, 2-of-3 approval, `${secret::}` env var, nightly drift, hook, error/drift email, private runner, nested group | applied |
| `git_vcs_triggers.tf` | GitLab push → apply with approval, PR → plan, file filters | validate only (registers a real webhook) |
| `automation_opentofu.tf` | OpenTofu 1.11.x, weekday schedule, completion webhook with a secret HMAC key, error email, chaining to a CUSTOM workflow | applied |
| `custom_steps.tf` | CUSTOM: Ansible (`ansible:18`), Helm (`kubernetes:13`) with step approval, CloudFormation change set (`cloudformation:2`) | applied |
| `own_template.tf` | Own template + revision with input schema; one workflow inheriting everything, one overriding/suppressing | applied (+ upgrade to a 2nd revision). Its revision is published, so `terraform destroy` needs a `deprecation` with a past `effective_date` applied first (`references/sources-and-templates.md` §3) |
| `outputs_and_references.tf` | `${workflow::…outputs…}` run-time reference; plan-time `stackguardian_workflow_outputs` | applied (data source verified to fail before the first run) |

Replace the placeholder ids (`acme`, `aws-prod-oidc`, `prod-runners`, repo URLs) with yours.
Connector and runner-group data sources fail at plan when the id does not exist — that is on
purpose.
