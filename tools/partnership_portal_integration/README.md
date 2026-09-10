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

## The named queries

One query per scenario. All six return the **same ten columns**, so the portal
gets one row shape whichever it calls. Counts measured in Dev on 2026-09-09
against team `3029c972-...`, which has 10 contacts of whom 4 are admins.

| API name | Parameter | Rows |
| --- | --- | --- |
| `ldgcrmApplicationContactsPartnerAdminByTeamUuid` | `teamuuid` | **4** — the portal's main lookup |
| `ldgcrmApplicationContactsPartnerAdminOnly` | none | 1,089 admins, every team |
| `ldgcrmApplicationContactsAll` | none | 2,807, everyone |
| `ldgcrmApplicationContactsByTeamUuid` | `teamuuid` | 10 — a team's whole roster |
| `ldgcrmApplicationContactsByEmail` | `email` | 5 — one row per Application |
| `ldgcrmApplicationContactsModifiedSince` | `modifiedsince` | changed at or after an instant |

**The two team queries are not interchangeable**: 4 admins against a 10-person
roster. The admin flag in `...PartnerAdminByTeamUuid` is hardcoded `TRUE` rather
than parameterised, so the portal's main lookup cannot accidentally return
non-admins.

Those two numbers are also what makes the pair testable. If the admin query ever
returns 10 its admin filter is dead; if it returns 1,089 its team filter is.

**Why not one query with optional filters.** Every declared parameter is
mandatory, and SOQL will not let a bind sit on the left of a comparison, so
"ignore this parameter" is not expressible. The only wildcard is `LIKE`, and
**`LIKE` never matches null**: `LDGCRM_P3_Team_UUID__c LIKE '%'` returns 841 of
the 1,089 admins, because 248 have no team. A single flexible query would have
dropped 23% of the baseline in silence. Every query above uses `=`.

## ⚠️ The `ApiNamedQuery` component schema

None of this is in Salesforce's documentation. It took five failed deploys.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<ApiNamedQuery xmlns="http://soap.sforce.com/2006/04/metadata">
    <apiVersion>67.0</apiVersion>
    <body2>SELECT ... WHERE Field__c = :teamuuid ...</body2>
    <description>...</description>
    <masterLabel>...</masterLabel>
    <apiNamedQueryParameters>
        <description>...</description>
        <parameterLabel>Team UUID</parameterLabel>
        <parameterName>teamuuid</parameterName>
    </apiNamedQueryParameters>
</ApiNamedQuery>
```

- **The element is `apiNamedQueryParameters`.** `parameters`, `parameter`,
  `namedQueryParameters`, `queryParameters`, `inputParameters`, `inputs` and
  `apiNamedQueryParameter` are all rejected as *"invalid at this location"* —
  which is the schema-sequence error, so it reads like an ordering problem when
  the element simply does not exist. Moving it around does not help.
- **The three sub-elements are `description`, `parameterLabel` and
  `parameterName`.** No type element: the type comes from the field being
  compared. `ApiNamedQueryParameter` has no other writable field.
- **`parameterName` must be lowercase**, and so must the `:bind` in the body.
  Salesforce rejects `teamUuid` outright and lowercases binds in its own error
  messages, so a camelCase name and its bind silently stop referring to the same
  thing. Keep them one lowercase word.
- **Omitting the parameter block entirely** gives
  `[SOQL references undefined parameters: [teamuuid]]`, which is the clearest
  error of the five and the one that proves the block is required.

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

## ⚠️ This feature fails quietly in four separate ways

It is present in Dev and it works. Each of these looked like the opposite:

1. **The endpoint is absent from the resource map.** `GET /services/data/v67.0/`
   lists 57 resources and no named-query entry, while
   `/services/data/v67.0/named/query/<ApiName>` answers correctly. Verified
   2026-09-09: 1,089 rows from `ldgcrmApplicationContactsPartnerAdminOnly`.
   Four plausible alternative paths all return an `errorCode` object.
2. **`400 INVALID_FIELD` has two unrelated causes and one message.** An empty
   `ApiNamedQuery` table produces it, and so does a caller without
   `View Setup and Configuration`. Either way the error describes a *schema*
   fault that is not there. Zero rows on a queryable table means empty, never
   absent.
3. **The Setup page is invisible without a permission set.** Administering named
   queries needs **Orgwide - Named Query - Admin** on the *admin's own* user;
   System Administrator is not enough. Callers do not need it.
4. **A URI parameter the query does not declare is SILENTLY IGNORED.** Not
   rejected, not warned about. Measured 2026-09-09: five parameters were sent at
   a query that declared none, and the call returned all 1,089 rows and printed
   the parameters as though they had applied. **An ignored filter returns MORE
   rows, and more rows never looks like failure**, so no count check downstream
   would catch it. `Get-NamedQueryDeclaredParameter` reads the query's own body
   before every call and refuses on a mismatch in either direction.

`scripts/docs/integration-user.md` section 3 carries the detail, along with the
manifest `<version>` trap — `ApiNamedQuery` does not exist below API 65.0, and a
retrieve against a lower version fails while reporting success.

## Adding a script here

Keep every `.ps1` **pure ASCII**. `powershell.exe` decodes a BOM-less `.ps1` as
the system ANSI codepage, so a typographic dash or arrow in a comment can stop
the file parsing. Write `-` and `->`.
