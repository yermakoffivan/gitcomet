[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)]
  [string]$TenantId,

  [Parameter(Mandatory = $true)]
  [string]$ClientId,

  [Parameter(Mandatory = $true)]
  [string]$SellerId,

  [Parameter(Mandatory = $true)]
  [string]$ProductId
)

$ErrorActionPreference = "Stop"
Set-StrictMode -Version Latest

function Stop-WithDiagnostic {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Message,

    [Parameter(Mandatory = $true)]
    [int]$ExitCode
  )

  [Console]::Error.WriteLine("ERROR (exit $ExitCode): $Message")
  exit $ExitCode
}

function Get-CorrelationId {
  param(
    [Parameter(Mandatory = $true)]
    [System.Net.Http.HttpResponseMessage]$Response
  )

  foreach ($headerName in @("X-Correlation-ID", "client-request-id", "x-ms-request-id")) {
    if ($Response.Headers.Contains($headerName)) {
      return ($Response.Headers.GetValues($headerName) -join ", ")
    }
  }

  return $null
}

function Get-SafeOAuthError {
  param(
    [AllowEmptyString()]
    [string]$ResponseBody,

    [Parameter(Mandatory = $true)]
    [string]$ClientSecret
  )

  if ([string]::IsNullOrWhiteSpace($ResponseBody)) {
    return "Microsoft Entra ID returned no error details."
  }

  try {
    $errorResponse = $ResponseBody | ConvertFrom-Json
    $parts = @()
    if ($errorResponse.PSObject.Properties.Name -contains "error") {
      $parts += [string]$errorResponse.error
    }
    if ($errorResponse.PSObject.Properties.Name -contains "error_description") {
      $parts += [string]$errorResponse.error_description
    }

    if ($parts.Count -eq 0) {
      return "Microsoft Entra ID returned an unrecognized error response."
    }

    $details = $parts -join ": "
    if (![string]::IsNullOrEmpty($ClientSecret)) {
      $details = $details.Replace($ClientSecret, "[REDACTED]")
    }
    return $details
  }
  catch {
    return "Microsoft Entra ID returned an unrecognized error response."
  }
}

$TenantId = $TenantId.Trim()
$ClientId = $ClientId.Trim()
$SellerId = $SellerId.Trim()
$ProductId = $ProductId.Trim()

$parsedTenantId = [guid]::Empty
if (![guid]::TryParse($TenantId, [ref]$parsedTenantId) -or $parsedTenantId -eq [guid]::Empty) {
  Stop-WithDiagnostic -Message "TenantId must be a non-empty GUID copied from the Partner Center Microsoft Entra application." -ExitCode 1
}

$parsedClientId = [guid]::Empty
if (![guid]::TryParse($ClientId, [ref]$parsedClientId) -or $parsedClientId -eq [guid]::Empty) {
  Stop-WithDiagnostic -Message "ClientId must be a non-empty GUID copied from the same Partner Center Microsoft Entra application." -ExitCode 1
}

if ($SellerId -notmatch '^\d+$') {
  Stop-WithDiagnostic -Message "SellerId must contain only digits and must be copied from Partner Center account settings." -ExitCode 1
}

if ($ProductId -notmatch '^[A-Za-z0-9][A-Za-z0-9.-]{0,127}$') {
  Stop-WithDiagnostic -Message "ProductId must be a non-empty Partner Center product ID containing only letters, digits, periods, or hyphens." -ExitCode 1
}

$secureClientSecret = Read-Host "MICROSOFT_STORE_CLIENT_SECRET" -AsSecureString
if ($secureClientSecret.Length -eq 0) {
  Stop-WithDiagnostic -Message "Client secret cannot be empty." -ExitCode 1
}

$secretPointer = [IntPtr]::Zero
$clientSecret = $null
$accessToken = $null
$httpClient = $null

try {
  $secretPointer = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secureClientSecret)
  $clientSecret = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($secretPointer)
  $secureClientSecret.Dispose()

  $httpClient = [System.Net.Http.HttpClient]::new()
  $httpClient.Timeout = [TimeSpan]::FromSeconds(60)

  Write-Host "Requesting a Microsoft Store API token from Microsoft Entra ID..."

  $tokenUri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
  $tokenFields = [System.Collections.Generic.Dictionary[string, string]]::new()
  $tokenFields.Add("grant_type", "client_credentials")
  $tokenFields.Add("client_id", $ClientId)
  $tokenFields.Add("client_secret", $clientSecret)
  $tokenFields.Add("scope", "https://api.store.microsoft.com/.default")

  $tokenContent = [System.Net.Http.FormUrlEncodedContent]::new($tokenFields)
  try {
    $tokenResponse = $httpClient.PostAsync($tokenUri, $tokenContent).GetAwaiter().GetResult()
  }
  catch {
    Stop-WithDiagnostic -Message "Could not contact Microsoft Entra ID: $($_.Exception.Message)" -ExitCode 2
  }
  finally {
    $tokenContent.Dispose()
    $tokenFields.Clear()
  }

  try {
    $tokenResponseBody = $tokenResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
    if (!$tokenResponse.IsSuccessStatusCode) {
      $statusCode = [int]$tokenResponse.StatusCode
      $details = Get-SafeOAuthError -ResponseBody $tokenResponseBody -ClientSecret $clientSecret
      Stop-WithDiagnostic -Message "Token request failed with HTTP $statusCode. Check the tenant ID, client ID, client secret value, and secret expiration. $details" -ExitCode 2
    }

    try {
      $tokenResult = $tokenResponseBody | ConvertFrom-Json
    }
    catch {
      Stop-WithDiagnostic -Message "Microsoft Entra ID returned a successful response that did not contain valid JSON." -ExitCode 2
    }

    if (!($tokenResult.PSObject.Properties.Name -contains "access_token") -or [string]::IsNullOrWhiteSpace([string]$tokenResult.access_token)) {
      Stop-WithDiagnostic -Message "Microsoft Entra ID returned a successful response without an access token." -ExitCode 2
    }

    $accessToken = [string]$tokenResult.access_token
    $tokenResponseBody = $null
    $tokenResult = $null
  }
  finally {
    $tokenResponse.Dispose()
  }

  Write-Host "Token issued successfully. Checking read-only access to the Partner Center product..."

  $encodedProductId = [Uri]::EscapeDataString($ProductId)
  $storeUri = "https://api.store.microsoft.com/submission/v1/product/$encodedProductId/metadata"
  $storeRequest = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $storeUri)
  $storeRequest.Headers.Authorization = [System.Net.Http.Headers.AuthenticationHeaderValue]::new("Bearer", $accessToken)
  $storeRequest.Headers.Add("X-Seller-Account-Id", $SellerId)

  try {
    try {
      $storeResponse = $httpClient.SendAsync($storeRequest).GetAwaiter().GetResult()
    }
    catch {
      Stop-WithDiagnostic -Message "Could not contact the Microsoft Store submission API: $($_.Exception.Message)" -ExitCode 3
    }

    try {
      if (!$storeResponse.IsSuccessStatusCode) {
        $statusCode = [int]$storeResponse.StatusCode
        $correlationId = Get-CorrelationId -Response $storeResponse
        $correlationSuffix = if ($null -ne $correlationId) { " Correlation ID: $correlationId." } else { "" }

        $diagnostic = switch ($statusCode) {
          401 { "The token was rejected. Verify that the Entra application is associated with this Partner Center account and that SellerId belongs to the same account." }
          403 { "The Entra application is authenticated but lacks Partner Center access to this product. Assign an appropriate role or read permission for the product." }
          404 { "The product was not found. Verify ProductId and confirm that the Entra application can access that product." }
          default { "The Microsoft Store API rejected the read-only metadata request." }
        }

        Stop-WithDiagnostic -Message "Store access check failed with HTTP $statusCode. $diagnostic$correlationSuffix" -ExitCode 3
      }

      $correlationId = Get-CorrelationId -Response $storeResponse
    }
    finally {
      $storeResponse.Dispose()
    }
  }
  finally {
    $storeRequest.Dispose()
  }

  Write-Host "Microsoft Store credentials are valid: token issuance, seller authorization, and read-only product access all succeeded."
  if ($null -ne $correlationId) {
    Write-Host "Microsoft correlation ID: $correlationId"
  }
}
finally {
  if ($null -ne $httpClient) {
    $httpClient.Dispose()
  }
  if ($secretPointer -ne [IntPtr]::Zero) {
    [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($secretPointer)
  }

  $clientSecret = $null
  $accessToken = $null
}
