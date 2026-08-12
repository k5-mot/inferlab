# frozen_string_literal: true

external_url ENV.fetch('GITLAB_EXTERNAL_URL')

gitlab_rails['gitlab_shell_ssh_port'] = ENV.fetch('GITLAB_SSH_HOST_PORT', '33422').to_i
gitlab_rails['gitlab_ssh_host'] = ENV.fetch('GITLAB_SSH_HOST')

nginx['listen_port'] = 80
nginx['listen_https'] = false

gitlab_rails['usage_ping_enabled'] = ENV.fetch('GITLAB_USAGE_PING_ENABLED', 'false') == 'true'

gitlab_rails['omniauth_enabled'] = true
gitlab_rails['omniauth_allow_single_sign_on'] = ['openid_connect']
gitlab_rails['omniauth_auto_link_user'] = ['openid_connect']
gitlab_rails['omniauth_block_auto_created_users'] = false
gitlab_rails['omniauth_sync_email_from_provider'] = 'openid_connect'
gitlab_rails['omniauth_sync_profile_from_provider'] = ['openid_connect']

gitlab_rails['omniauth_providers'] = [
  {
    name: 'openid_connect',
    label: 'Keycloak',
    args: {
      name: 'openid_connect',
      scope: %w[openid profile email],
      response_type: 'code',
      issuer: ENV.fetch('GITLAB_OIDC_ISSUER'),
      discovery: true,
      uid_field: 'preferred_username',
      pkce: true,
      client_auth_method: 'query',
      client_options: {
        identifier: ENV.fetch('GITLAB_OIDC_CLIENT_ID'),
        secret: ENV.fetch('GITLAB_OIDC_CLIENT_SECRET'),
        redirect_uri: ENV.fetch('GITLAB_OIDC_REDIRECT_URI')
      }
    }
  }
]
