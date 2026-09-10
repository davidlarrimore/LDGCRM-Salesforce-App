# tools/partnership_portal_integration/

Readers for the Partner Portal (P3) integration: they authenticate as the
External Client App `LDGCRM_P3_Client_app_Localdev` over the OAuth 2.0
**client-credentials** flow and write rows to a UTF-8 CSV in `logs/tools/`.

| Script | Query text lives | Use it when |
| --- | --- | --- |
| [`Invoke-LdgcrmNamedQuery.ps1`](Invoke-LdgcrmNamedQuery.ps1) | **in the org**, as `ApiNamedQuery` metadata | The contract is fixed and reviewable server-side |
| [`Invoke-LdgcrmSalesforceQuery.ps1`](Invoke-LdgcrmSalesforceQuery.ps1) | **in the caller**, composed locally | Ad-hoc reads, or any object at all |
| [`Common.PortalIntegration.ps1`](Common.PortalIntegration.ps1) | — | Shared: token, registry guard, flattening, CSV |

Both take the same app, the same integration user and the same permission set,
so **neither is more privileged than the other** — only where the SOQL text
lives differs.

## ⚠️ Calling a Named Query needs `View Setup and Configuration`

Salesforce's REST API guide lists it under *User Permissions Needed* — "To
execute a Named Query API: **View Setup and Configuration**". Enabling it also
adds `ViewRoles`. `LDGCRM_Partnership_Portal_API_R` carries both, so the named
query works in Dev: 1,089 records, the same as an administrator gets.

**A caller without them gets `400 INVALID_FIELD`** complaining about a column on
`ApiNamedQuery`. That is a setup entity, Salesforce resolves the query name by
reading it **as the caller**, and it reports an entity the caller cannot see as
one that does not exist. Read access on the queried object governs which **rows**
come back, not who may **call** — so the other script keeps working while this
one fails, on the identical token.

Expect that in any org the permission set has not reached yet. It travels in a
**change set**, never a CLI deploy. The grant also widens the integration past
what its object table describes — `scripts/docs/integration-user.md` section 3
carries that caveat.

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
2. **`400 INVALID_FIELD` has two unrelated causes and one message.** An empty
   `ApiNamedQuery` table produces it, and so does a caller without
   `View Setup and Configuration`. Either way the error describes a *schema*
   fault that is not there. Zero rows on a queryable table means empty, never
   absent.
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
