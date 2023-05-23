variable "cognito_user_pool_id" {
  type        = string
  description = "The name of the user pool to create the app client in"
}

variable "cognito_user_pool_domain" {
  type        = string
  description = "The fully-qualified domain name of the user pool"
}

variable "ecs_cluster_name" {
  type        = string
  description = "The name of the ECS cluster to deploy the app to"
}

variable "alb_arn" {
  type        = string
  description = "The ARN of the ALB to expose the app on"
}

variable "alb_https_listener_arn" {
  type        = string
  description = "The ARN of the HTTPS listener on the ALB"
}

variable "domain_prefix" {
  description = "domain prefix to use for the service"
  type        = string
  default     = null
}

variable "domain_suffix" {
  description = "domain suffix to use for the service"
  type        = string
}

variable "dream_env" {
  description = "dream app environment variables to set"
  type        = any
  default     = {}
}

variable "dream_secrets" {
  description = "dream app secrets to set"
  type        = set(string)
  default     = []
}

variable "dream_project_dir" {
  description = "root directory of the project sources"
  type        = string
}

variable "project_name" {
  description = "name of the project"
  type        = string
  default     = null
}