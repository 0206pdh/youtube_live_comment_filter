data "aws_iam_policy_document" "github_assume_role" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [var.oidc_provider_arn]
    }

    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }

    # Restrict GitHub OIDC tokens to this repository. Branch-level conditions can
    # be tightened further later, but repository scoping is the minimum baseline.
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${var.github_repository}:*"
      ]
    }
  }
}

resource "aws_iam_role" "terraform" {
  name               = "${var.name}-terraform-role"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

resource "aws_iam_role" "deploy" {
  name               = "${var.name}-deploy-role"
  assume_role_policy = data.aws_iam_policy_document.github_assume_role.json
}

locals {
  terraform_statements = concat(
    [
      {
        Effect = "Allow"
        Action = [
          "ec2:*",
          "ecs:*",
          "elasticloadbalancing:*",
          "ecr:*",
          "logs:*",
          "iam:*",
          "ssm:*",
          "apigateway:*",
          "wafv2:*",
          "cloudwatch:*"
        ]
        Resource = "*"
      }
    ],
    var.terraform_state_bucket_arn != "" ? [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:ListBucket"
        ]
        Resource = [
          var.terraform_state_bucket_arn,
          "${var.terraform_state_bucket_arn}/*"
        ]
      }
    ] : [],
    var.terraform_lock_table_arn != "" ? [
      {
        Effect = "Allow"
        Action = [
          "dynamodb:GetItem",
          "dynamodb:PutItem",
          "dynamodb:DeleteItem",
          "dynamodb:DescribeTable"
        ]
        Resource = [var.terraform_lock_table_arn]
      }
    ] : []
  )

  deploy_statements = concat(
    [
      {
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken"
        ]
        Resource = "*"
      }
    ],
    length(var.ecr_repository_arns) > 0 ? [
      {
        Effect = "Allow"
        Action = [
          "ecr:BatchGetImage",
          "ecr:CompleteLayerUpload",
          "ecr:DescribeImages",
          "ecr:DescribeRepositories",
          "ecr:InitiateLayerUpload",
          "ecr:PutImage",
          "ecr:UploadLayerPart"
        ]
        Resource = var.ecr_repository_arns
      }
    ] : [],
    length(var.ecs_cluster_arns) > 0 || length(var.ecs_service_arns) > 0 ? [
      {
        Effect = "Allow"
        Action = [
          "ecs:DescribeServices",
          "ecs:DescribeTaskDefinition",
          "ecs:UpdateService"
        ]
        Resource = concat(var.ecs_cluster_arns, var.ecs_service_arns)
      }
    ] : [],
    length(var.ssm_parameter_arns) > 0 ? [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter",
          "ssm:GetParameters"
        ]
        Resource = var.ssm_parameter_arns
      }
    ] : []
  )
}

# Terraform needs broad infrastructure permissions because it creates and
# updates foundational resources. These can be narrowed later once the exact
# steady-state resource set and bootstrap flow are locked down.
resource "aws_iam_role_policy" "terraform" {
  name = "${var.name}-terraform-policy"
  role = aws_iam_role.terraform.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.terraform_statements
  })
}

# The deploy role is intentionally narrower: it only needs to push images and
# restart/update the ECS service that is already managed by Terraform.
resource "aws_iam_role_policy" "deploy" {
  name = "${var.name}-deploy-policy"
  role = aws_iam_role.deploy.id

  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.deploy_statements
  })
}
