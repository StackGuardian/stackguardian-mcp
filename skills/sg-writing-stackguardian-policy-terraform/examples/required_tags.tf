# Runtime rule: EC2 instances and RDS databases must carry a CostCenter tag and Environment=production.
# One evaluator per resource type and tag; tolerance 1 so plans without that type pass.

resource "stackguardian_workflow_group" "prod" {
  id            = "prod"
  resource_name = "prod"
}

locals {
  tag_attr = { operation_type = "attribute", terraform_resource_attribute = "tags" } # "tags_all" also counts default_tags
}

resource "stackguardian_policy" "required_tags" {
  resource_name                = "required-tags"
  policy_type                  = "GENERAL"
  description                  = "Mandatory cost and environment tags"
  tags                         = ["finops"]
  enforced_on                  = ["/wfgrps/${stackguardian_workflow_group.prod.id}"]
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [{
    name    = "mandatory_tags"
    skip    = false
    on_fail = "FAIL"
    on_pass = "PASS"
    policy_vcs_config = {
      use_marketplace_template = false
      custom_source            = { source_config_kind = "SG_POLICY_FRAMEWORK", source_config_dest_kind = "INLINE" }
    }
    policy_input_data = {
      schema_type = "TIRITH_JSON"
      data = jsonencode({
        meta = { version = "v1", required_provider = "stackguardian/terraform_plan" }
        evaluators = [
          {
            id            = "ec2_cost_center"
            provider_args = merge(local.tag_attr, { terraform_resource_type = "aws_instance" })
            condition     = { type = "Contains", value = "CostCenter", error_tolerance = 1 } # tag key present
          },
          {
            id            = "ec2_environment"
            provider_args = merge(local.tag_attr, { terraform_resource_type = "aws_instance" })
            condition     = { type = "Contains", value = { Environment = "production" }, error_tolerance = 1 } # key = value
          },
          {
            id            = "rds_cost_center"
            provider_args = merge(local.tag_attr, { terraform_resource_type = "aws_db_instance" })
            condition     = { type = "Contains", value = "CostCenter", error_tolerance = 1 }
          },
          {
            id            = "rds_environment"
            provider_args = merge(local.tag_attr, { terraform_resource_type = "aws_db_instance" })
            condition     = { type = "Contains", value = { Environment = "production" }, error_tolerance = 1 }
          },
        ]
        eval_expression = "ec2_cost_center && ec2_environment && rds_cost_center && rds_environment"
      })
    }
  }]
}
