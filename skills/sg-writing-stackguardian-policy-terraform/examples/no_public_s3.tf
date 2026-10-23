# Runtime rule: deny public canned ACLs on aws_s3_bucket_acl and require block_public_acls on declared
# aws_s3_bucket_public_access_block resources. Not covered: buckets without a public access block
# (a direct_references recipe exists, with limits: references/tirith.md §8), ACL grants via
# access_control_policy, bucket policies.
# Scope: a workflow group (incl. nested groups) plus one extra workflow elsewhere.

resource "stackguardian_workflow_group" "payments" {
  id            = "payments"
  resource_name = "payments"
}

locals {
  inline_tirith = {
    use_marketplace_template = false
    custom_source            = { source_config_kind = "SG_POLICY_FRAMEWORK", source_config_dest_kind = "INLINE" }
  }
}

resource "stackguardian_policy" "no_public_s3" {
  resource_name = "no-public-s3"
  policy_type   = "GENERAL"
  description   = "Deny public canned S3 ACLs; public access blocks must block public ACLs"
  tags          = ["security", "s3"]
  enforced_on = [
    "/wfgrps/${stackguardian_workflow_group.payments.id}", # group + everything below it
    "/wfgrps/platform/wfs/shared-dns",                     # one workflow: /wfgrps/<group>/wfs/<workflow>
  ]
  approvers                    = []
  number_of_approvals_required = 0

  policies_config = [{
    name              = "s3_not_public"
    skip              = false
    on_fail           = "FAIL"
    on_pass           = "PASS"
    policy_vcs_config = local.inline_tirith
    policy_input_data = {
      schema_type = "TIRITH_JSON"
      data = jsonencode({
        meta = { version = "v1", required_provider = "stackguardian/terraform_plan" }
        evaluators = [
          {
            id          = "acl_not_public"
            description = "aws_s3_bucket_acl.acl must not grant public access"
            provider_args = {
              operation_type               = "attribute"
              terraform_resource_type      = "aws_s3_bucket_acl"
              terraform_resource_attribute = "acl"
            }
            # tolerance 1: plans without aws_s3_bucket_acl are skipped, not failed
            condition = { type = "NotContainedIn", value = ["public-read", "public-read-write", "authenticated-read"], error_tolerance = 1 }
          },
          {
            id          = "public_access_blocked"
            description = "public access blocks must block public ACLs"
            provider_args = {
              operation_type               = "attribute"
              terraform_resource_type      = "aws_s3_bucket_public_access_block"
              terraform_resource_attribute = "block_public_acls"
            }
            condition = { type = "Equals", value = true, error_tolerance = 1 }
          },
        ]
        eval_expression = "acl_not_public && public_access_blocked" # a skipped evaluator drops out of the expression
      })
    }
  }]
}
