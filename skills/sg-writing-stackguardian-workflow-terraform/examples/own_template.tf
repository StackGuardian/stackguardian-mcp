# Your own reusable template (container + published revision) and two workflows built from it:
# one inheriting everything, one overriding and suppressing template values.
#
# provider 1.12.3: workflow_from_template works with templates owned by YOUR org only. For a
# template owned by another org (every StackGuardian marketplace template) apply fails with
# "Could not read template revision ... 401 Unauthorized" — copy it into your org like this.

variable "org" {
  type        = string
  description = "Org slug that owns the template (same as STACKGUARDIAN_ORG_NAME)."
  default     = "acme"
}

data "stackguardian_connector" "github" {
  id = "github_com"
}

locals {
  vpc_source = {
    source_config_dest_kind = "GITHUB_COM"
    config = {
      repo       = "https://github.com/acme/tf-vpc"
      ref        = "v1.4.0"
      is_private = true
      auth       = "/integrations/${data.stackguardian_connector.github.id}" # required for every kind but GIT_OTHER, even public repos
    }
  }
}

resource "stackguardian_workflow_template" "vpc" {
  template_name      = "vpc-module" # becomes the template id
  source_config_kind = "TERRAFORM"  # immutable
  is_public          = "0"          # template level: "1" = listed for other orgs
  description        = "Standard VPC"
  runtime_source     = local.vpc_source
}

resource "stackguardian_workflow_template_revision" "vpc_v1" {
  template_id        = stackguardian_workflow_template.vpc.id
  source_config_kind = "TERRAFORM"
  alias              = "v1"
  notes              = "Initial release"
  is_public          = "1" # revision level: "1" = published (frozen afterwards), "0" = draft
  user_job_cpu       = 512 # required on revisions
  user_job_memory    = 1024
  runtime_source     = local.vpc_source # NOT inherited from the template — always repeat it
  tags               = ["network"]
  environment_variables = [
    { kind = "PLAIN_TEXT", config = { var_name = "TF_LOG", text_value = "INFO" } },
  ]

  terraform_config = {
    terraform_version       = "1.5.7"
    managed_terraform_state = true
    approval_pre_apply      = true
  }

  input_schemas = [{
    type = "FORM_JSONSCHEMA"
    encoded_data = base64encode(jsonencode({
      type     = "object"
      required = ["cidr"]
      properties = {
        cidr   = { type = "string", default = "10.0.0.0/16" }
        az_cnt = { type = "number", default = 2 }
      }
    }))
  }]
}

resource "stackguardian_workflow_group" "dev" {
  id            = "dev"
  resource_name = "dev"
}

resource "stackguardian_workflow_from_template" "vpc_dev" {
  id                = "vpc-dev"
  resource_name     = "VPC (dev)"
  workflow_group_id = stackguardian_workflow_group.dev.id
  wf_type           = "TERRAFORM"

  vcs_config = {
    iac_vcs_config = {
      # Always org-qualified, also for your own org: "vpc-module:1" alone is a 404.
      iac_template_id = "/${var.org}/${stackguardian_workflow_template_revision.vpc_v1.id}"
    }
    # iac_input_data omitted -> the schema defaults (cidr, az_cnt) are sent.
  }
  # To upgrade later, publish vpc_v2 and point iac_template_id at it: attributes you declared
  # keep your values, everything you left out adopts the new revision.
}

resource "stackguardian_workflow_group" "prod" {
  id            = "prod"
  resource_name = "prod"
}

resource "stackguardian_workflow_from_template" "vpc_prod" {
  id                = "vpc-prod"
  resource_name     = "VPC (prod)"
  workflow_group_id = stackguardian_workflow_group.prod.id
  wf_type           = "TERRAFORM"

  vcs_config = {
    iac_vcs_config = {
      iac_template_id = "/${var.org}/${stackguardian_workflow_template_revision.vpc_v1.id}"
    }
    iac_input_data = { # replaces the template inputs entirely: list every input you need
      schema_type = "FORM_JSONSCHEMA"
      data        = jsonencode({ cidr = "10.20.0.0/16", az_cnt = 3 })
    }
  }

  deployment_platform_config = [{
    kind   = "AWS_RBAC"
    config = { integration_id = "/integrations/aws-prod" }
  }]

  tags                  = [] # suppress the template's tags (top-level [] works)
  environment_variables = [] # suppress the template's env vars
  terraform_config = {       # merged key by key with the template's terraform_config
    terraform_version       = "1.5.7"
    managed_terraform_state = true
    approval_pre_apply      = true
    # Template hooks/steps inside terraform_config cannot be removed from here:
    # pre_plan_hooks = [] is ignored by the server and taints the resource.
  }
  approvers                    = ["netops@acme.com"]
  number_of_approvals_required = 1
}
