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
  name = var.domain_suffix
}

locals {
  project_name  = var.project_name != null ? var.project_name : basename(var.dream_project_dir)
  domain_prefix = var.domain_prefix != null ? var.domain_prefix : local.project_name
  domain_name   = "${local.domain_prefix}.${var.domain_suffix}"
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
    container_port   = 80
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
  cpu                      = 512
  memory                   = 1024
  task_role_arn            = aws_iam_role.ecs_cloudwatch_role.arn
  container_definitions    = jsonencode([
    {
      name        = "envoy"
      image       = "public.ecr.aws/bitnami/envoy:1.26.1"
      cpu         = 256
      memory      = 512
      essential   = true
      mountPoints = [
        {
          sourceVolume  = "config"
          containerPath = "/opt/bitnami/envoy/conf"
        },
      ]
      portMappings = [
        {
          containerPort = 80
          hostPort      = 80
          protocol      = "tcp"
        },
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          awslogs-group         = "${local.project_name}-container"
          awslogs-region        = data.aws_region.current.name
          awslogs-create-group  = true
          awslogs-stream-prefix = local.project_name
        }
      }
      dependsOn = [
        {
          containerName = "config"
          condition     = "COMPLETE"
        },
      ]
    },
    {
      name             = "config"
      image            = "bash:4.4"
      cpu              = 256
      memory           = 512
      essential        = false
      logConfiguration = {
        logDriver = "awslogs"
        options   = {
          awslogs-group         = "${local.project_name}-config"
          awslogs-region        = data.aws_region.current.name
          awslogs-create-group  = true
          awslogs-stream-prefix = local.project_name
        }
      }
      mountPoints = [
        {
          sourceVolume  = "config"
          containerPath = "/opt/bitnami/envoy/conf"
        },
      ]
      command = [
        "bash", "-c",
        "echo \"${file("${path.module}/envoy.tpl.yaml")}\" > /opt/bitnami/envoy/conf/envoy.yaml"
      ]
    },
  ])
  volume {
    name = "config"
  }
}

resource "aws_lb_target_group" "app" {
  name_prefix = substr(local.project_name, 0, 6)
  port        = 80
  protocol    = "HTTP"
  vpc_id      = data.aws_vpc.default.id
  target_type = "ip"
}

module "alb_certificate" {
  source             = "github.com/hereya/terraform-modules//alb-certificate/module?ref=v0.18.0"
  alb_arn            = var.alb_arn
  domain_name_prefix = local.domain_prefix
  route53_zone_name  = var.domain_suffix
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
  from_port                = 80
  to_port                  = 80
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

resource "aws_iam_role" "ecs_cloudwatch_role" {
  name               = "ECSCloudWatchRole"
  assume_role_policy = data.aws_iam_policy_document.ecs_assume_role.json
}

resource "aws_iam_policy" "allow_write_logs" {
  policy      = data.aws_iam_policy_document.allow_ecs_to_write_logs.json
  name        = "AllowECSTasksToWriteLogs"
  description = "Allow ECS to write logs to CloudWatch"
}

resource "aws_iam_role_policy_attachment" "allow_write_logs" {
  policy_arn = aws_iam_policy.allow_write_logs.arn
  role       = aws_iam_role.ecs_cloudwatch_role.name
}
data "aws_iam_policy_document" "allow_ecs_to_write_logs" {
  statement {
    effect  = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

output "DEPLOYED_IMAGE" {
  value = var.dream_env.DOCKER_IMAGES[0]
}
