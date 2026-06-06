terraform {
  required_version = ">= 1.6.0"

  cloud {
    organization = "YOUR_TERRAFORM_CLOUD_ORG"

    workspaces {
      name = "adiryx-aws-landing-zone"
    }
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

resource "aws_organizations_organization" "adiryx" {
  feature_set = "ALL"

  aws_service_access_principals = [
    "cloudtrail.amazonaws.com",
    "config.amazonaws.com",
    "guardduty.amazonaws.com",
    "securityhub.amazonaws.com",
    "sso.amazonaws.com",
    "account.amazonaws.com"
  ]

  enabled_policy_types = [
    "SERVICE_CONTROL_POLICY"
  ]
}

#################################################
# ROOT
#################################################

data "aws_organizations_organization" "current" {
  depends_on = [aws_organizations_organization.adiryx]
}

locals {
  root_id = data.aws_organizations_organization.current.roots[0].id
}

#################################################
# TOP-LEVEL OUs
#################################################

resource "aws_organizations_organizational_unit" "security" {
  name      = "Security"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "infrastructure" {
  name      = "Infrastructure"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "workloads" {
  name      = "Workloads"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "sandbox" {
  name      = "Sandbox"
  parent_id = local.root_id
}

resource "aws_organizations_organizational_unit" "suspended" {
  name      = "Suspended"
  parent_id = local.root_id
}

#################################################
# CHILD OUs UNDER WORKLOADS
#################################################

resource "aws_organizations_organizational_unit" "production" {
  name      = "Production"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_organizational_unit" "non_production" {
  name      = "Non-Production"
  parent_id = aws_organizations_organizational_unit.workloads.id
}

#################################################
# AWS ACCOUNTS
#################################################

resource "aws_organizations_account" "log_archive" {
  name      = "adiryx-log-archive"
  email     = "aws-log-archive@adiryx.com"
  parent_id = aws_organizations_organizational_unit.security.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "security_tooling" {
  name      = "adiryx-security-tooling"
  email     = "aws-security-tooling@adiryx.com"
  parent_id = aws_organizations_organizational_unit.security.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "network" {
  name      = "adiryx-network"
  email     = "aws-network@adiryx.com"
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "identity" {
  name      = "adiryx-identity"
  email     = "aws-identity@adiryx.com"
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "shared_services" {
  name      = "adiryx-shared-services"
  email     = "aws-shared-services@adiryx.com"
  parent_id = aws_organizations_organizational_unit.infrastructure.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "prod" {
  name      = "adiryx-prod"
  email     = "aws-prod@adiryx.com"
  parent_id = aws_organizations_organizational_unit.production.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "dev" {
  name      = "adiryx-dev"
  email     = "aws-dev@adiryx.com"
  parent_id = aws_organizations_organizational_unit.non_production.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "test" {
  name      = "adiryx-test"
  email     = "aws-test@adiryx.com"
  parent_id = aws_organizations_organizational_unit.non_production.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "uat" {
  name      = "adiryx-uat"
  email     = "aws-uat@adiryx.com"
  parent_id = aws_organizations_organizational_unit.non_production.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "soc_platform" {
  name      = "adiryx-soc-platform"
  email     = "aws-soc-platform@adiryx.com"
  parent_id = aws_organizations_organizational_unit.non_production.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

resource "aws_organizations_account" "sandbox" {
  name      = "adiryx-sandbox"
  email     = "aws-sandbox@adiryx.com"
  parent_id = aws_organizations_organizational_unit.sandbox.id

  iam_user_access_to_billing = "DENY"
  close_on_deletion          = false
}

#################################################
# BASIC SCP - DENY LEAVING ORGANIZATION
#################################################

resource "aws_organizations_policy" "deny_leave_org" {
  name        = "DenyLeaveOrganization"
  description = "Prevents member accounts from leaving the AWS Organization."
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DenyLeaveOrganization"
        Effect = "Deny"
        Action = [
          "organizations:LeaveOrganization"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org_security" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organizational_unit.security.id
}

resource "aws_organizations_policy_attachment" "deny_leave_org_infrastructure" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organizational_unit.infrastructure.id
}

resource "aws_organizations_policy_attachment" "deny_leave_org_workloads" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organizational_unit.workloads.id
}

resource "aws_organizations_policy_attachment" "deny_leave_org_sandbox" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = aws_organizations_organizational_unit.sandbox.id
}

#################################################
# OUTPUTS
#################################################

output "aws_organization_id" {
  value = data.aws_organizations_organization.current.id
}

output "adiryx_ou_structure" {
  value = {
    security        = aws_organizations_organizational_unit.security.id
    infrastructure = aws_organizations_organizational_unit.infrastructure.id
    workloads      = aws_organizations_organizational_unit.workloads.id
    production     = aws_organizations_organizational_unit.production.id
    non_production = aws_organizations_organizational_unit.non_production.id
    sandbox        = aws_organizations_organizational_unit.sandbox.id
    suspended      = aws_organizations_organizational_unit.suspended.id
  }
}
