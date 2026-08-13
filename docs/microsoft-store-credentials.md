# Testing Microsoft Store Credentials Locally

The Microsoft Store release workflow requires one repository variable and four repository secrets:

| Local parameter or prompt | GitHub setting | Source |
| --- | --- | --- |
| `TenantId` | Secret `MICROSOFT_STORE_TENANT_ID` | Tenant ID shown for the Microsoft Entra application in Partner Center |
| `ClientId` | Secret `MICROSOFT_STORE_CLIENT_ID` | Client ID shown for that same Entra application |
| Secure prompt | Secret `MICROSOFT_STORE_CLIENT_SECRET` | The **value** of an unexpired client secret, not its secret ID |
| `SellerId` | Secret `MICROSOFT_STORE_SELLER_ID` | Seller ID under Partner Center account settings |
| `ProductId` | Variable `MICROSOFT_STORE_PRODUCT_ID` | Partner Center ID on the product overview page |

GitHub does not allow repository secret values to be read back. To reproduce the workflow credentials locally, supply copies of the same values:

```powershell
pwsh ./scripts/windows/test-microsoft-store-credentials.ps1 `
  -TenantId "<MICROSOFT_STORE_TENANT_ID>" `
  -ClientId "<MICROSOFT_STORE_CLIENT_ID>" `
  -SellerId "<MICROSOFT_STORE_SELLER_ID>" `
  -ProductId "<MICROSOFT_STORE_PRODUCT_ID>"
```

The script securely prompts for `MICROSOFT_STORE_CLIENT_SECRET`. It does not accept the secret as a command-line argument, persist it, print it, install `msstore`, or modify a Store submission.

## What the Check Proves

The script performs two network requests:

1. It requests a client-credentials token for `https://api.store.microsoft.com/.default` from the configured Microsoft Entra tenant.
2. It uses that token and seller ID to read the specified product's current draft metadata from the Microsoft Store submission API.

A successful result verifies the credential values together, including access to the configured Partner Center product. Package URLs, release notes, and submission payloads are not checked because they are unrelated to an authentication `401`.

Failure exit codes are:

- `1`: a required ID is missing or malformed.
- `2`: token issuance failed; check the tenant ID, client ID, client secret value, and secret expiration.
- `3`: the Store API rejected the read-only request or could not be reached.

For Store failures, `401` usually means the Entra application is not associated with the seller account, the seller ID is from a different account, or the token is rejected. `403` means the application lacks the required Partner Center product permission. `404` means the product ID is wrong or unavailable to that application.

Before using the credentials, associate the Entra application with the Partner Center account and grant it a suitable role or product permission. Microsoft documents these prerequisites in the [Microsoft Store submission API for MSI or EXE apps](https://learn.microsoft.com/en-us/windows/apps/publish/store-submission-api) and [Partner Center Entra application management](https://learn.microsoft.com/en-us/windows/apps/publish/partner-center/manage-azure-ad-applications-in-partner-center).
