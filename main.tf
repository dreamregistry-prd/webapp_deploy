terraform {
  backend "s3" {}

  required_providers {
    random = {
      source  = "registry.terraform.io/hashicorp/random"
      version = "~>3.5"
    }
    aws = {
      source  = "registry.terraform.io/hashicorp/aws"
      version = "~>4.0"
    }
  }
}

provider "random" {}
provider "aws" {}

data "aws_ecs_cluster" "fargate" {
  cluster_name = var.ecs_cluster_name
}

data "aws_vpc" "default" {
  default = true
}

data "aws_subnets" "private" {
  filter {
    name   = "vpc-id"
    values = [data.aws_vpc.default.id]
  }
  tags = {
    Tier = "private"
  }
}

data "aws_lb" "lb" {
  arn = var.alb_arn
}

data "aws_lb_listener" "https" {
  load_balancer_arn = data.aws_lb.lb.arn
  port              = 443
}

data "aws_route53_zone" "root" {
  name         = var.domain_suffix
  private_zone = var.is_private_domain
}

locals {
  project_name  = var.project_name != null ? var.project_name : basename(var.dream_project_dir)
  domain_prefix = var.domain_prefix != null ? var.domain_prefix : local.project_name
  domain_name   = "${local.domain_prefix}.${var.domain_suffix}"
  raw_env       = [
    for k, v in var.dream_env : {
      name  = k
      value = try(tostring(v), null)
    }
  ]
  raw_secrets = [
    for k, v in var.dream_env : {
      name      = k
      //noinspection HILUnresolvedReference
      valueFrom = try(v.arn, null)
    }
  ]
  env = concat(
    [
      for e in local.raw_env : e if e.value != null
    ],
    [
      {
        name  = "OIDC_CLIENT_ID"
        value = local.oidc_env.OIDC_CLIENT_ID
      },
      {
        name  = "OIDC_ISSUER_URL"
        value = local.oidc_env.OIDC_ISSUER_URL
      },
      {
        name  = "OIDC_DISCOVERY_URL"
        value = local.oidc_env.OIDC_DISCOVERY_URL
      },
      {
        name  = "OIDC_LOGOUT_URL"
        value = local.oidc_env.OIDC_LOGOUT_URL
      },
      {
        name  = "OIDC_LOGOUT_REDIRECT_URL"
        value = local.oidc_env.OIDC_LOGOUT_REDIRECT_URL
      },
      {
        name  = "OIDC_CALLBACK_URL"
        value = local.oidc_env.OIDC_CALLBACK_URL
      }
    ],
    [
      {
        name  = "PORT"
        value = "9000"
      }
    ]
  )
  secrets = concat(
    [
      for e in local.raw_secrets : e if e.valueFrom != null
    ],
    [
      {
        name      = "OIDC_CLIENT_SECRET"
        //noinspection HILUnresolvedReference
        valueFrom = local.oidc_module.OIDC_CLIENT_SECRET.arn
      }
    ]
  )
}

resource "aws_ecs_service" "app" {
  name            = local.project_name
  cluster         = data.aws_ecs_cluster.fargate.id
  task_definition = aws_ecs_task_definition.app.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets         = data.aws_subnets.private.ids
    security_groups = [aws_security_group.web.id]
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.app.arn
    container_name   = "envoy"
    container_port   = 8080
  }
}

resource "random_pet" "task_definition_name" {
  prefix = local.project_name
}

data "aws_region" "current" {}

resource "aws_ecs_task_definition" "app" {
  family                   = random_pet.task_definition_name.id
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 1024
  memory                   = 2048
  execution_role_arn       = aws_iam_role.task_execution.arn
  container_definitions    = jsonencode([
    {
      name         = "envoy"
      image        = "public.ecr.aws/hereya/bff-envoy:522c902"
      cpu          = 256
      memory       = 512
      essential    = true
      portMappings = [
        {
          containerPort = 8080
          hostPort      = 8080
          protocol      = "tcp"
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          "awslogs-group" : "${local.project_name}-app"
          "awslogs-region" : data.aws_region.current.name
          "awslogs-create-group" : "true"
          "awslogs-stream-prefix" : local.project_name
        }
      }
    },
    {
      name         = "app"
      image        = var.dream_env.DOCKER_IMAGES[0]
      cpu          = 512
      memory       = 1024
      essential    = true
      portMappings = [
        {
          containerPort = 3000
          hostPort      = 3000
          protocol      = "tcp"
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          "awslogs-group" : "${local.project_name}-main"
          "awslogs-region" : data.aws_region.current.name
          "awslogs-create-group" : "true"
          "awslogs-stream-prefix" : local.project_name
        }
      },
      environment = [
        {
          name  = "PORT"
          value = "3000"
        },
        {
          name  = "AUTH_ENDPOINT"
          value = "http://127.0.0.1:9000/auth/authenticate"
        }
      ]
    },
    {
      name         = "oidc"
      image        = "public.ecr.aws/hereya/oidc-sidecar:fb22c23"
      cpu          = 256
      memory       = 512
      essential    = true
      portMappings = [
        {
          containerPort = 9000
          hostPort      = 9000
          protocol      = "tcp"
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          "awslogs-group" : "${local.project_name}-oidc"
          "awslogs-region" : data.aws_region.current.name
          "awslogs-create-group" : "true"
          "awslogs-stream-prefix" : local.project_name
        }
      }
      environment = local.env
      secrets     = local.secrets
    }
  ])
}

resource "aws_lb_target_group" "app" {
  name_prefix = substr(local.project_name, 0, 6)
  port        = 8080
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
  health_check {
    interval          = 10
    path              = "/health"
    healthy_threshold = 2
  }
  lifecycle {
    create_before_destroy = true
  }
}

module "alb_certificate" {
  source               = "github.com/hereya/terraform-modules//alb-certificate/module?ref=v0.29.0"
  alb_arn              = var.alb_arn
  domain_name_prefix   = local.domain_prefix
  route53_zone_name    = var.domain_suffix
  public_domain_suffix = var.public_domain_suffix
  attach_to_alb        = true
  alb_listener_arn     = data.aws_lb_listener.https.arn
  is_private_domain    = var.is_private_domain
}

resource "aws_lb_listener_rule" "host_based_weighted_routing" {
  listener_arn = data.aws_lb_listener.https.arn

  action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.app.arn
  }

  condition {
    host_header {
      values = [local.domain_name]
    }
  }
}

resource "aws_security_group" "web" {
  name = "web"
}

resource "aws_security_group_rule" "allow_http" {
  security_group_id        = aws_security_group.web.id
  type                     = "ingress"
  from_port                = 8080
  to_port                  = 8080
  protocol                 = "tcp"
  source_security_group_id = tolist(data.aws_lb.lb.security_groups)[0]
}

resource "aws_security_group_rule" "allow_all_out" {
  security_group_id = aws_security_group.web.id
  type              = "egress"
  from_port         = 0
  to_port           = 0
  protocol          = "-1"
  cidr_blocks       = ["0.0.0.0/0"]
}

data "aws_iam_policy_document" "ecs_assume_role" {
  statement {
    effect = "Allow"

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }

    actions = ["sts:AssumeRole"]
  }
}

resource random_pet "task_execution_iam_suffix" {
  length = 1
}

resource "aws_iam_role" "task_execution" {
  name               = "DReAMPoCECSTaskExecutionRole${random_pet.task_execution_iam_suffix.id}"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_policy" "task_execution" {
  policy      = data.aws_iam_policy_document.task_execution.json
  name        = "DReAMPoCECSTaskExecutionPolicy${random_pet.task_execution_iam_suffix.id}"
  description = "Grants required permissions to ECS tasks"
}

resource "aws_iam_role_policy_attachment" "task_execution" {
  policy_arn = aws_iam_policy.task_execution.arn
  role       = aws_iam_role.task_execution.name
}

data "aws_iam_policy_document" "task_execution" {
  statement {
    effect  = "Allow"
    actions = [
      "ecr:GetAuthorizationToken",
      "ecr:BatchCheckLayerAvailability",
      "ecr:GetDownloadUrlForLayer",
      "ecr:BatchGetImage",
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "ssm:GetParameters"
    ]
    resources = ["*"]
  }
}
