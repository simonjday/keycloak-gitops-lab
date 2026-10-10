# Decodes the ID token from a kubelogin ExecCredential and prints the claims the API server maps.
def b64url: gsub("-"; "+") | gsub("_"; "/") | . + ("=" * ((4 - (length % 4)) % 4)) | @base64d;
.status.token
| split(".")[1] | b64url | fromjson
| { iss, aud, preferred_username, groups,
    issued: (.iat | todate), expires: (.exp | todate) }
