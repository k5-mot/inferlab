import os


def env(name, default=""):
    """環境変数を取得し、未設定時は既定値を返す。

    Args:
        name: 取得する環境変数名。
        default: 環境変数が未設定または空文字の場合に返す値。

    Returns:
        環境変数の値、または既定値。
    """
    return os.environ.get(name) or default


PUBLIC_HOST = env("PUBLIC_HOST", "127.0.0.1")
PULP_HTTP_HOST_PORT = env("PULP_HTTP_HOST_PORT", "33000")
PULP_PUBLIC_ORIGIN = f"http://{PUBLIC_HOST}:{PULP_HTTP_HOST_PORT}"
PULP_KEYCLOAK_REALM = env("PULP_KEYCLOAK_REALM", env("STACK_NAME", "inferlab"))
PULP_KEYCLOAK_BASE_URL = env("PULP_KEYCLOAK_BASE_URL", f"http://{PUBLIC_HOST}:30001")

SECRET_KEY = env("PULP_SECRET_KEY", "sk-pulp-secret-key-change-me")
CONTENT_ORIGIN = PULP_PUBLIC_ORIGIN
ALLOWED_HOSTS = ["*"]
CSRF_TRUSTED_ORIGINS = [PULP_PUBLIC_ORIGIN]

DATABASES = {
    "default": {
        "HOST": "pulp-postgres",
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "pulp",
        "USER": "pulp",
        "PASSWORD": env("PULP_POSTGRES_PASSWORD", "pulp_password"),
        "PORT": "5432",
        "CONN_MAX_AGE": 0,
        "OPTIONS": {"sslmode": "prefer"},
    }
}

CACHE_ENABLED = True
REDIS_HOST = "pulp-redis"
REDIS_PORT = 6379
REDIS_PASSWORD = env("PULP_REDIS_PASSWORD", "pulp_redis_password")

TOKEN_SERVER = f"{PULP_PUBLIC_ORIGIN}/token/"
TOKEN_AUTH_DISABLED = False
TOKEN_SIGNATURE_ALGORITHM = "ES256"
PUBLIC_KEY_PATH = "/etc/pulp/certs/container_auth_public_key.pem"
PRIVATE_KEY_PATH = "/etc/pulp/certs/container_auth_private_key.pem"

ANSIBLE_API_HOSTNAME = PULP_PUBLIC_ORIGIN
ANSIBLE_CONTENT_HOSTNAME = f"{PULP_PUBLIC_ORIGIN}/pulp/content"

ALLOWED_IMPORT_PATHS = ["/tmp"]
ALLOWED_EXPORT_PATHS = ["/tmp"]
ANALYTICS = False
STATIC_ROOT = "/var/lib/operator/static/"

INSTALLED_APPS = [
    "social_django",
    "dynaconf_merge",
]

AUTHENTICATION_BACKENDS = [
    "social_core.backends.keycloak.KeycloakOAuth2",
    "pulpcore.backends.ObjectRolePermissionBackend",
    "dynaconf_merge",
]

TEMPLATES = [
    {
        "OPTIONS": {
            "context_processors": [
                "social_django.context_processors.backends",
                "social_django.context_processors.login_redirect",
                "dynaconf_merge",
            ],
        },
        "dynaconf_merge": True,
    }
]

SOCIAL_AUTH_KEYCLOAK_KEY = env("PULP_OIDC_CLIENT_ID", "pulp")
SOCIAL_AUTH_KEYCLOAK_SECRET = env("PULP_OIDC_CLIENT_SECRET", "sk-pulp-oidc-client-secret-key")
SOCIAL_AUTH_KEYCLOAK_PUBLIC_KEY = env("PULP_KEYCLOAK_PUBLIC_KEY")
SOCIAL_AUTH_KEYCLOAK_AUTHORIZATION_URL = (
    f"{PULP_KEYCLOAK_BASE_URL}/realms/{PULP_KEYCLOAK_REALM}/protocol/openid-connect/auth/"
)
SOCIAL_AUTH_KEYCLOAK_ACCESS_TOKEN_URL = (
    f"{PULP_KEYCLOAK_BASE_URL}/realms/{PULP_KEYCLOAK_REALM}/protocol/openid-connect/token/"
)
SOCIAL_AUTH_PIPELINE = (
    "social_core.pipeline.social_auth.social_details",
    "social_core.pipeline.social_auth.social_uid",
    "social_core.pipeline.social_auth.social_user",
    "social_core.pipeline.user.get_username",
    "social_core.pipeline.social_auth.associate_by_email",
    "social_core.pipeline.user.create_user",
    "social_core.pipeline.social_auth.associate_user",
    "social_core.pipeline.social_auth.load_extra_data",
    "social_core.pipeline.user.user_details",
)

LOGIN_URL = "/login/keycloak/"
LOGIN_REDIRECT_URL = "/pulp/api/v3/"
