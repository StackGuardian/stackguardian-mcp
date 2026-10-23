# Examples

Every file pairs with `versions.tf` as a root module and passes `terraform validate` and
`tofu validate` (provider 1.12.3). All were also applied against a real org with names prefixed
and `enforced_on` pointed at an empty scope, re-planned with no changes (the OPA policy after the
documented untaint), and destroyed. Every
inline Tirith document was extracted from the Terraform plan and executed on Tirith 1.0.5 with
passing, failing and skip inputs.

| File | Rules | Where it runs |
|---|---|---|
| `no_public_s3.tf` | S3 ACL deny-list + public-access-block check; group + single-workflow scope | runtime (plan) |
| `required_tags.tf` | CostCenter key and Environment=production on EC2/RDS | runtime (plan) |
| `network_guardrails.tf` | no 0.0.0.0/0 ingress, EU regions via `provider_config`, instance-type allow-list | runtime (plan) |
| `approvals.tf` | approval on any delete/replace, approval when monthly cost > 500; org-wide `["*"]`, shared approvers | runtime (plan / Infracost) |
| `config_rules.tf` | managed state required (warn), approved connectors + private runners (fail), pinned Terraform version (warn) | config time (workflow create/update, run build) |
| `opa_and_marketplace.tf` | Rego from private GitHub with `opaQuery` (+ the untaint / `ignore_changes = all` handling), connector scope; marketplace checkov bundle warn-only | runtime |

The `terraform_version` rule in `config_rules.tf` was added later: it passes both validators and its
document was run on Tirith 1.0.5 with passing and failing workflow payloads, but it was not applied
live.

Replace the placeholder ids (`acme`, connector names, repo URLs, approver emails) with yours.
