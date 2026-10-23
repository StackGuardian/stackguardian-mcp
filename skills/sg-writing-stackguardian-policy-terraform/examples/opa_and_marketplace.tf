# Rego from a private GitHub repo, scoped to every workflow deploying through one connector,
# plus a StackGuardian marketplace policy template org-wide as warn-only.

data "stackguardian_connector" "github" {
  id = "github_com"
}

resource "stackguardian_policy" "opa_guardrails" {
  resource_name                = "opa-guardrails"
  policy_type                  = "GENERAL"
  description                  = "Rego guardrails for production AWS"
  tags                         = ["opa"]
  enforced_on                  = ["/integrations/aws-prod-oidc"] # workflows whose deployment_platform_config uses it
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [{
    name    = "rego_allow"
    skip    = false
    on_fail = "FAIL"
    on_pass = "PASS"
    policy_vcs_config = {
      use_marketplace_template = false
      custom_source = {
        source_config_kind      = "OPA_REGO"
        source_config_dest_kind = "GITHUB_COM" # OPA is never INLINE
        config = {
          repo        = "https://github.com/acme/opa-policies"
          ref         = "main"
          working_dir = "terraform" # directory loaded with `opa eval --data`
          is_private  = true
          auth        = "/integrations/${data.stackguardian_connector.github.id}"
        }
        # package terraform.guardrails + `default allow = false` + allow rules
        # (OPA 0.55: Rego v0 with `import future.keywords.if`; `import rego.v1` does not parse)
        additional_config = jsonencode({ opaQuery = "terraform.guardrails.allow" }) # no "data." prefix
      }
    }
  }]

  # The provider cannot read additional_config back: the first apply reports
  # "Provider produced inconsistent result" although the policy is stored correctly.
  # Then: terraform untaint stackguardian_policy.opa_guardrails
  # ignore_changes = all (NOT [policies_config]): any update would re-send the rules from state
  # without opaQuery and silently disable the Rego check. Change this policy with -replace.
  lifecycle {
    ignore_changes = all
  }
}

resource "stackguardian_policy" "aws_best_practices" {
  resource_name                = "aws-best-practices"
  policy_type                  = "GENERAL"
  description                  = "StackGuardian AWS best practices (checkov), report only"
  tags                         = ["aws"]
  enforced_on                  = ["*"]
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [{
    name    = "aws_best_practices_all"
    skip    = false
    on_fail = "WARN"
    on_pass = "PASS"
    policy_vcs_config = {
      use_marketplace_template = true
      policy_template_id       = "/stackguardian/aws-best-practices-all:2" # numeric revision; not validated until a run
    }
  }]
}
