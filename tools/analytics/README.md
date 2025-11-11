# Zoho Analytics Schema Export

This folder contains a PowerShell script to export your Zoho Analytics workspace schema (tables + columns, and views where supported) using the Analytics API v2.

## Prerequisites
- Zoho Analytics OAuth access token (region-specific)
- Workspace ID (found in your Analytics URL or Workspace Settings)
- Correct region domain:
  - US: `https://analyticsapi.zoho.com`
  - EU: `https://analyticsapi.zoho.eu`
  - IN: `https://analyticsapi.zoho.in`
\n+### US data center endpoints
- Analytics API base: `https://analyticsapi.zoho.com`
- Accounts (OAuth authorize/token): `https://accounts.zoho.com`
- Developer Console (client registration): `https://api-console.zoho.com`
\n+For other regions change the suffix (`.eu`, `.in`, `.jp`, `.au`, `.ca`, `.sa`). Keep the same path structure.

Scopes to grant when generating the token (minimum):
- `ZohoAnalytics.data.read`
- `ZohoAnalytics.metadata.read`

For a complete end-to-end setup (tokens, export, troubleshooting, Query Table SQL, dashboard steps), see:
- ORDER_PREP_GUIDE.md (this folder)

## Usage
You can pass parameters or set environment variables.

### Option A: Environment variables
```pwsh
$env:ZOHO_ANALYTICS_DOMAIN = 'https://analyticsapi.zoho.com'
$env:ZOHO_ANALYTICS_WORKSPACE = '<WORKSPACE_ID>'
$env:ZOHO_ANALYTICS_TOKEN = '<ACCESS_TOKEN>'
# Optional, if your tenant requires it:
$env:ZOHO_ANALYTICS_ORGID = '<ORG_ID>'

pwsh ./export-schema.ps1
```
Output: `DATA_SCHEMA.out.json` in this folder.

### Option B: Parameters
```pwsh
pwsh ./export-schema.ps1 -Domain 'https://analyticsapi.zoho.com' -WorkspaceId '<WORKSPACE_ID>' -AccessToken '<ACCESS_TOKEN>' [-OrgId '<ORG_ID>'] -OutFile 'schema.json'
```
\n+### Getting an access token (US region example)
1. Go to `https://api-console.zoho.com` and create a client (Self Client works for quick tests).
2. Generate an authorization code with scopes:
   - `ZohoAnalytics.data.read`
   - `ZohoAnalytics.metadata.read`
3. Exchange the code for an access token against Accounts (`https://accounts.zoho.com/oauth/v2/token`). You can use the helper script in this repo:
```pwsh
pwsh ../diagnostics/zoho_token_exchange.ps1 `
  -ClientId "1000.XXXX" `
  -ClientSecret "XXXX" `
  -Code "1000.AUTH_CODE" `
  -RedirectUri "https://your-app/callback" `
  -AccountsDomain com

# Result will print access_token; then:
$env:ZOHO_ANALYTICS_TOKEN = '<ACCESS_TOKEN>'
# If required by your tenant:
# $env:ZOHO_ANALYTICS_ORGID = '<ORG_ID>'
```
4. Run the export script (Option A or B) to generate `DATA_SCHEMA.out.json`.

Refresh tokens: If returned, store securely; do NOT commit to source control.

## What it does
- Calls:
  - `GET /api/v2/workspaces/{workspaceId}/tables`
  - `GET /api/v2/workspaces/{workspaceId}/tables/{tableId}/columns`
  - Best-effort for views:
    - `GET /api/v2/workspaces/{workspaceId}/views`
    - `GET /api/v2/workspaces/{workspaceId}/views/{viewId}/columns`
- Writes a JSON with table/view → columns (name, label, dataType, isFormula, description).

## Notes
- Do not commit access tokens to source control.
- If your region isn’t `.com`, change the domain accordingly.
- Response shapes can vary; script includes fallbacks.
- You can compare this output with your existing `DATA_SCHEMA.json` at repo root to keep documentation current.

## Troubleshooting
- 401/403: Check token validity and scopes; confirm domain matches your region.
- Empty list: Check WorkspaceId; ensure your token has access to the workspace.
- Views section empty: Your plan/permissions may restrict the endpoint; tables will still export.
