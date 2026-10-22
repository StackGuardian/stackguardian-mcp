# Config-time rules (stackguardian/json): evaluated against the WORKFLOW DEFINITION when a workflow
# in scope is created or updated (terraform apply of stackguardian_workflow_* gets a 403 on FAIL)
# and again when each run is built.

resource "stackguardian_workflow_group" "platform" {
  id            = "platform"
  resource_name = "platform"
}

locals {
  inline = {
    use_marketplace_template = false
    custom_source            = { source_config_kind = "SG_POLICY_FRAMEWORK", source_config_dest_kind = "INLINE" }
  }
}

resource "stackguardian_policy" "workflow_standards" {
  resource_name                = "workflow-standards"
  policy_type                  = "GENERAL"
  description                  = "Managed state, approved connectors, private runners, pinned Terraform version"
  tags                         = ["platform"]
  enforced_on                  = ["/wfgrps/${stackguardian_workflow_group.platform.id}"]
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [
    {
      name              = "managed_state"
      skip              = false
      on_fail           = "WARN" # roll out as a warning first
      on_pass           = "PASS"
      policy_vcs_config = local.inline
      policy_input_data = {
        schema_type = "TIRITH_JSON"
        data = jsonencode({
          meta = { version = "v1", required_provider = "stackguardian/json" }
          evaluators = [
            {
              id            = "is_custom"
              provider_args = { operation_type = "get_value", key_path = "WfType" }
              condition     = { type = "Equals", value = "CUSTOM", error_tolerance = 2 }
            },
            {
              id            = "uses_managed_state"
              provider_args = { operation_type = "get_value", key_path = "TerraformConfig.managedTerraformState" }
              # tolerance 1: a TERRAFORM/OPENTOFU workflow that omits the key (server default = unmanaged) fails too
              condition = { type = "Equals", value = true, error_tolerance = 1 }
            },
          ]
          eval_expression = "is_custom || uses_managed_state" # CUSTOM workflows have no Terraform state
        })
      }
    },
    {
      name              = "approved_connectors"
      skip              = false
      on_fail           = "FAIL"
      on_pass           = "PASS"
      policy_vcs_config = local.inline
      policy_input_data = {
        schema_type = "TIRITH_JSON"
        data = jsonencode({
          meta = { version = "v1", required_provider = "stackguardian/json" }
          evaluators = [
            {
              id            = "known_connector"
              provider_args = { operation_type = "get_value", key_path = "DeploymentPlatformConfig.*.config.integrationId" }
              condition     = { type = "ContainedIn", value = ["/integrations/aws-prod-oidc", "/integrations/aws-shared-rbac"], error_tolerance = 2 }
            },
            {
              id            = "private_runner"
              provider_args = { operation_type = "get_value", key_path = "RunnerConstraints.type" }
              # tolerance 1: an omitted runner type (server default = shared) fails too
              condition = { type = "Equals", value = "private", error_tolerance = 1 }
            },
          ]
          eval_expression = "known_connector && private_runner"
        })
      }
    },
    {
      name              = "terraform_version"
      skip              = false
      on_fail           = "WARN"
      on_pass           = "PASS"
      policy_vcs_config = local.inline
      policy_input_data = {
        schema_type = "TIRITH_JSON"
        data = jsonencode({
          meta = { version = "v1", required_provider = "stackguardian/json" }
          evaluators = [
            {
              id            = "is_custom"
              provider_args = { operation_type = "get_value", key_path = "WfType" }
              condition     = { type = "Equals", value = "CUSTOM", error_tolerance = 2 }
            },
            {
              id            = "tf_version_ok"
              provider_args = { operation_type = "get_value", key_path = "TerraformConfig.terraformVersion" }
              # HCL "\\." is a literal dot in the regex; tolerance 1: a workflow without a version fails
              condition = { type = "RegexMatch", value = "^1\\.(5|9)\\.", error_tolerance = 1 }
            },
          ]
          eval_expression = "is_custom || tf_version_ok"
        })
      }
    },
  ]
}
