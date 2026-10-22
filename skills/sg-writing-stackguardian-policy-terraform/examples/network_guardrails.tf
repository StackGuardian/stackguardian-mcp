# Runtime rules: no world-open ingress (IPv4/IPv6), literal EU provider regions only (Terraform and
# OpenTofu registries), approved instance types.

resource "stackguardian_workflow_group" "apps" {
  id            = "apps"
  resource_name = "apps"
}

resource "stackguardian_policy" "network_guardrails" {
  resource_name                = "network-guardrails"
  policy_type                  = "GENERAL"
  description                  = "Ingress, region and instance-type guardrails"
  tags                         = ["security"]
  enforced_on                  = ["/wfgrps/${stackguardian_workflow_group.apps.id}"]
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [{
    name    = "network_guardrails"
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
            id            = "no_open_ipv4_ingress"
            provider_args = { operation_type = "attribute", terraform_resource_type = "aws_vpc_security_group_ingress_rule", terraform_resource_attribute = "cidr_ipv4" }
            # tolerance 1: a cidr unknown at plan time fails (tolerance 2 would let skips erase violations)
            condition = { type = "NotEquals", value = "0.0.0.0/0", error_tolerance = 1 }
          },
          {
            id            = "no_open_ipv6_ingress"
            provider_args = { operation_type = "attribute", terraform_resource_type = "aws_vpc_security_group_ingress_rule", terraform_resource_attribute = "cidr_ipv6" }
            condition     = { type = "NotEquals", value = "::/0", error_tolerance = 1 }
          },
          {
            id            = "eu_region_terraform"
            provider_args = { operation_type = "provider_config", terraform_provider_full_name = "registry.terraform.io/hashicorp/aws", attribute = "region" }
            # only a literal region in the first matching provider block resolves; tolerance 2 skips the rest
            condition = { type = "ContainedIn", value = ["eu-central-1", "eu-west-1"], error_tolerance = 2 }
          },
          {
            id            = "eu_region_opentofu"
            provider_args = { operation_type = "provider_config", terraform_provider_full_name = "registry.opentofu.org/hashicorp/aws", attribute = "region" }
            condition     = { type = "ContainedIn", value = ["eu-central-1", "eu-west-1"], error_tolerance = 2 }
          },
          {
            id            = "approved_instance_type"
            provider_args = { operation_type = "attribute", terraform_resource_type = "aws_instance", terraform_resource_attribute = "instance_type" }
            condition     = { type = "ContainedIn", value = ["t3.micro", "t3.small", "m6i.large"], error_tolerance = 1 }
          },
        ]
        eval_expression = "no_open_ipv4_ingress && no_open_ipv6_ingress && eu_region_terraform && eu_region_opentofu && approved_instance_type"
      })
    }
  }]
}
