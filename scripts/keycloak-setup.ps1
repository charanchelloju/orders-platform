# Keycloak realm bootstrap
# Creates the "orders" realm + client + users + roles via Keycloak's
# Admin REST API. Idempotent - re-run safely.
#
# Requires: AWS CLI logged in (to read admin password from Secrets Manager)
# Usage:    .\scripts\keycloak-setup.ps1

$ErrorActionPreference = "Stop"

# Use localhost via kubectl port-forward to avoid Keycloak's HTTPS-on-external check.
# Run this before invoking the script:
#   kubectl port-forward -n keycloak svc/keycloak 8080:80
$KC_BASE = "http://localhost:8080/auth"
$REALM   = "orders"

$secretJson = aws secretsmanager get-secret-value --secret-id orders-platform/keycloak/admin --region ap-south-1 --query SecretString --output text
$creds = $secretJson | ConvertFrom-Json
$ADMIN_USER = $creds.'admin-user'
$ADMIN_PASSWORD = $creds.'admin-password'

Write-Host "Logging in as admin user..."
$tokenResp = Invoke-RestMethod -Uri "$KC_BASE/realms/master/protocol/openid-connect/token" -Method POST -ContentType "application/x-www-form-urlencoded" -Body @{ grant_type = "password"; client_id = "admin-cli"; username = $ADMIN_USER; password = $ADMIN_PASSWORD }
$ADMIN_TOKEN = $tokenResp.access_token
$H = @{ Authorization = "Bearer $ADMIN_TOKEN" }
Write-Host "[ok] Got admin token"

function Invoke-KcApi($Method, $Path, $Body = $null) {
    $url = "$KC_BASE/admin$Path"
    $params = @{ Uri = $url; Method = $Method; Headers = $H }
    if ($Body) {
        $params.ContentType = "application/json"
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    return Invoke-RestMethod @params
}

# 1. Realm
try {
    Invoke-KcApi GET "/realms/$REALM" | Out-Null
    Write-Host "[ok] Realm '$REALM' already exists"
} catch {
    Invoke-KcApi POST "/realms" @{ realm = $REALM; enabled = $true }
    Write-Host "[ok] Created realm '$REALM'"
}

# 2. Roles
foreach ($role in @("USER", "ORDERS_WRITE", "ORDERS_READ")) {
    try {
        Invoke-KcApi GET "/realms/$REALM/roles/$role" | Out-Null
        Write-Host "[ok] Role '$role' already exists"
    } catch {
        Invoke-KcApi POST "/realms/$REALM/roles" @{ name = $role }
        Write-Host "[ok] Created role '$role'"
    }
}

# 3. Client
$existing = Invoke-KcApi GET "/realms/$REALM/clients?clientId=orders-app"
if ($existing.Count -gt 0) {
    Write-Host "[ok] Client 'orders-app' already exists"
} else {
    Invoke-KcApi POST "/realms/$REALM/clients" @{
        clientId                  = "orders-app"
        enabled                   = $true
        publicClient              = $true
        directAccessGrantsEnabled = $true
        standardFlowEnabled       = $true
        protocol                  = "openid-connect"
        redirectUris              = @("*")
    }
    Write-Host "[ok] Created client 'orders-app'"
}

# 4. Users + role assignments
$users = @(
    @{ username = "alice"; password = "alice"; email = "alice@example.com"; roles = @("USER", "ORDERS_WRITE", "ORDERS_READ") }
    @{ username = "bob";   password = "bob";   email = "bob@example.com";   roles = @("USER", "ORDERS_READ") }
)

foreach ($u in $users) {
    $found = Invoke-KcApi GET "/realms/$REALM/users?username=$($u.username)"
    if ($found.Count -gt 0) {
        $userId = $found[0].id
        Write-Host "[ok] User '$($u.username)' already exists"
    } else {
        Invoke-KcApi POST "/realms/$REALM/users" @{ username = $u.username; email = $u.email; emailVerified = $true; enabled = $true }
        $userId = (Invoke-KcApi GET "/realms/$REALM/users?username=$($u.username)")[0].id
        Write-Host "[ok] Created user '$($u.username)' (id $userId)"
    }

    Invoke-KcApi PUT "/realms/$REALM/users/$userId/reset-password" @{ type = "password"; value = $u.password; temporary = $false }

    $roleObjs = @()
    foreach ($r in $u.roles) {
        $roleObjs += Invoke-KcApi GET "/realms/$REALM/roles/$r"
    }
    Invoke-KcApi POST "/realms/$REALM/users/$userId/role-mappings/realm" $roleObjs
    Write-Host "[ok] Assigned roles to $($u.username)"
}

Write-Host ""
Write-Host "Setup complete"
Write-Host "Realm:    $REALM"
Write-Host "Client:   orders-app"
Write-Host "Users:    alice (USER, ORDERS_WRITE, ORDERS_READ)"
Write-Host "          bob   (USER, ORDERS_READ)"
Write-Host ""
Write-Host "Get a token for alice:"
Write-Host "  POST $KC_BASE/realms/$REALM/protocol/openid-connect/token"
Write-Host "  grant_type=password client_id=orders-app username=alice password=alice"
