# tools/partnership_portal_integration/

Readers for the Partner Portal (P3) integration: they authenticate as the
External Client App `LDGCRM_P3_Client_app_Localdev` over the OAuth 2.0
**client-credentials** flow and write rows to a UTF-8 CSV in `logs/tools/`.

| Script | Query text lives | Works today? |
| --- | --- | --- |
| [`Invoke-LdgcrmSalesforceQuery.ps1`](Invoke-LdgcrmSalesforceQuery.ps1) | **in the caller**, composed locally | ✅ Yes — use this one |
| [`Invoke-LdgcrmNamedQuery.ps1`](Invoke-LdgcrmNamedQuery.ps1) | **in the org**, as `ApiNamedQuery` metadata | ❌ Blocked on a permission decision |
| [`Common.PortalIntegration.ps1`](Common.PortalIntegration.ps1) | — | Shared: token, registry guard, flattening, CSV |

## ⚠️ The named-query script does not work as the integration user yet

Measured 2026-09-09. Same URL, same API version, same moment — only the caller
differs:

| Caller | `GET /services/data/v67.0/named/query/ldgcrmPartnerPortalAdminQuery` |
| --- | --- |
| An administrator | **1,089 records** |
| `ldgcrm_p3_integration`, via client credentials | **400 `INVALID_FIELD`** |

Read access on the queried object is necessary and **not sufficient** — the
integration user holds exactly that through `LDGCRM_Partnership_Portal_API_R`
and reads those same rows fine through the other script.

What the run-as user needs instead is **not established**, and granting
`Orgwide - Named Query - Admin` to an API-only user is a decision rather than an
assumption. Until it is settled, use `Invoke-LdgcrmSalesforceQuery.ps1`.
`scripts/docs/integration-user.md` section 3 owns that question.

Both scripts take the same app, the same integration user and the same
permission set, so **neither is more privileged than the other** — only where
the SOQL text lives differs.

## Credentials

Three values in the repo-root `.env`:

```
SALESFORCE_INSTANCE_URL
SALESFORCE_CONSUMER_KEY
SALESFORCE_CONSUMER_SECRET
```

A consumer key one character short returns `invalid_client_id` and nothing else
— that has already happened here, with an 84-character key against the app's
real 85.

## ⚠️ Dev and QA only, and it is enforced before the token request

`SALESFORCE_INSTANCE_URL` must match an `InstanceUrl` in
`Get-LdgcrmEnvironmentTable` exactly. Production is deliberately absent from
that registry, so pointing either script at `gsa-peo` fails before a token is
requested at all.

These rows are **applicant PII**. The transcript records counts only; the
records themselves go to the CSV and nowhere else, so a log never becomes a
second uncontrolled copy. `logs/` is gitignored — keep it that way.

## ⚠️ The Named Query API reads as missing in three separate ways

It is present in Dev and it works. Each of these looked like the opposite:

1. **The endpoint is absent from the resource map.** `GET /services/data/v67.0/`
   lists 57 resources and no named-query entry, while
   `/services/data/v67.0/named/query/<ApiName>` answers correctly. Verified
   2026-09-09: 1,089 rows from `ldgcrmPartnerPortalAdminQuery`. Four plausible
   alternative paths all return an `errorCode` object.
2. **An empty `ApiNamedQuery` table answers `400 INVALID_FIELD`, not `404`.**
   Its label field is `MasterLabel`; it has no `DeveloperName`. So the error
   describes the *schema*, not the provisioning. Zero rows on a queryable table
   means empty, never absent.
3. **The Setup page is invisible without a permission set.** Administering named
   queries needs **Orgwide - Named Query - Admin** on the *admin's own* user;
   System Administrator is not enough. Callers do not need it.

`scripts/docs/integration-user.md` section 3 carries the detail, along with the
manifest `<version>` trap — `ApiNamedQuery` does not exist below API 65.0, and a
retrieve against a lower version fails while reporting success.

## Adding a script here

Keep every `.ps1` **pure ASCII**. `powershell.exe` decodes a BOM-less `.ps1` as
the system ANSI codepage, so a typographic dash or arrow in a comment can stop
the file parsing. Write `-` and `->`.
