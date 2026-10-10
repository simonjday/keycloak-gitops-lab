# Decodes the access token from a Keycloak token-endpoint response (e.g. client credentials).
def b64url: gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d;
.access_token
| split(".")[1] | b64url | fromjson
| { iss, aud, azp, sub, preferred_username,
    demo_api_roles: (.resource_access["demo-api"].roles // []),
    expires: (.exp | todate) }
