//noinspection HILUnresolvedReference
locals {
  oidc_module = var.use_cognito ? module.cognito_app.0 : module.auth0_oidc.0
  oidc_env    = {
    OIDC_CLIENT_ID           = local.oidc_module.OIDC_CLIENT_ID
    OIDC_ISSUER_URL          = local.oidc_module.OIDC_ISSUER_URL
    OIDC_DISCOVERY_URL       = local.oidc_module.OIDC_DISCOVERY_URL
    OIDC_LOGOUT_URL          = local.oidc_module.OIDC_LOGOUT_URL
    OIDC_LOGOUT_REDIRECT_URL = local.oidc_module.OIDC_LOGOUT_REDIRECT_URL
    OIDC_CALLBACK_URL        = local.oidc_module.OIDC_CALLBACK_URL
  }
  custom_scopes = [
    for scope in concat([], [
      for k, v in var.dream_env : split(" ", v) if startswith(k, "OIDC_SCOPES_")
    ]...) : scope if scope != ""
  ]
}


module "auth0_oidc" {
  count               = var.use_cognito ? 0 : 1
  source              = "github.com/hereya/terraform-modules//auth0-oidc/module?ref=v0.31.0"
  auth0_custom_domain = var.auth0_custom_domain
  root_url            = "https://${local.domain_name}"
  app_name_prefix     = local.project_name
}

module "cognito_app" {
  count                    = var.use_cognito ? 1 : 0
  source                   = "github.com/hereya/terraform-modules//cognito-app/module?ref=v0.31.0"
  cognito_user_pool_domain = var.cognito_user_pool_domain
  cognito_user_pool_id     = var.cognito_user_pool_id
  app_base_url             = "https://${local.domain_name}"
  custom_scopes            = local.custom_scopes
}