# Two approval gates in one policy, org-wide: plans that delete anything, and plans whose
# estimated monthly cost exceeds $500. Approvers are policy-level and shared by both rules.
# Runtime approvals pause before apply; plan-only runs never pause.

locals {
  inline = {
    use_marketplace_template = false
    custom_source            = { source_config_kind = "SG_POLICY_FRAMEWORK", source_config_dest_kind = "INLINE" }
  }
}

resource "stackguardian_policy" "change_approvals" {
  resource_name = "change-approvals" # slug: runtime approvals match approvers on this name
  policy_type   = "GENERAL"
  description   = "Human approval for deletions and expensive plans"
  tags          = ["governance"]
  enforced_on   = ["*"] # whole organization — on its own, never combined

  approvers                    = ["finops@acme.com", "cto@acme.com"] # lowercase emails or SSO groups
  number_of_approvals_required = 1                                   # 0 would mean ALL of them

  policies_config = [
    {
      name              = "approve_deletes"
      skip              = false
      on_fail           = "APPROVAL_REQUIRED"
      on_pass           = "PASS"
      policy_vcs_config = local.inline
      policy_input_data = {
        schema_type = "TIRITH_JSON"
        data = jsonencode({
          meta = { version = "v1", required_provider = "stackguardian/terraform_plan" }
          evaluators = [{
            id            = "no_deletes"
            provider_args = { operation_type = "action", terraform_resource_type = "*" }
            # plan actions are create/update/delete/no-op/read; a replace yields delete + create
            condition = { type = "NotContainedIn", value = ["delete"], error_tolerance = 1 }
          }]
          eval_expression = "no_deletes"
        })
      }
    },
    {
      name              = "approve_cost_over_500"
      skip              = false
      on_fail           = "APPROVAL_REQUIRED"
      on_pass           = "PASS"
      policy_vcs_config = local.inline
      policy_input_data = {
        schema_type = "TIRITH_JSON"
        data = jsonencode({
          meta = { version = "v1", required_provider = "stackguardian/infracost" }
          evaluators = [{
            id            = "monthly_cost_ok"
            provider_args = { operation_type = "total_monthly_cost", resource_type = ["*"] }
            condition     = { type = "LessThanEqualTo", value = 500 } # integers only
          }]
          eval_expression = "monthly_cost_ok"
        })
      }
    },
  ]
}
