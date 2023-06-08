variable "auth0_custom_domain" {
  type        = string
  description = "Auth0 custom domain"
}

variable "ecs_cluster_name" {
  type        = string
  description = "The name of the ECS cluster to deploy the app to"
}

variable "alb_arn" {
  type        = string
  description = "The ARN of the ALB to expose the app on"
}

variable "domain_prefix" {
  description = "domain prefix to use for the service"
  type        = string
  default     = null
}

variable "public_domain_suffix" {
  description = "public domain suffix to use for certificate validation"
  type        = string
  default     = null
}

variable "is_private_domain" {
  description = "whether the domain is to be defined in a private hosted zone or not"
  type        = bool
  default     = false
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