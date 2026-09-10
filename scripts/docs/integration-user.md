# Setting up the P3 integration user

> **Who this is for:** whoever stands up the Partner Portal (P3) API integration in
> a new org, or repairs it after a sandbox refresh. It is the **user-side** setup:
> the licenses, the permission sets and the order they go on in — on the
> integration's user, and on the admin's own user.
>
> None of this arrives with a change set. A change set carries the permission set
> **definition** and nothing else — not the user, not the license, not the
> assignment. Every org needs the work done in it separately, either by the
> script below or by hand.

The integration user is what the Partner Portal authenticates as when it reads the
CRM over the API. It is paired with the External Client App
`LDGCRM_P3_Client_app_Localdev` (see the comment block in
[`sfdx/manifest/package.xml`](../../sfdx/manifest/package.xml)), which holds the
OAuth side of the same integration.

## Sections 1 and 2 are scripted

[`../Set-LdgcrmIntegrationUser.ps1`](../Set-LdgcrmIntegrationUser.ps1) does the
user, the license and the permission set, in the right order, in any of the four
environments. It **reports by default and writes only with `-Apply`**:

```powershell
scripts\Set-LdgcrmIntegrationUser.ps1 -Environment QA           # what state is QA in?
scripts\Set-LdgcrmIntegrationUser.ps1 -Environment QA -Apply    # do it
```

Every step is idempotent, so a re-run after a partial failure finishes the job
rather than duplicating it, and it verifies by re-querying the org rather than
trusting what the writes reported. Production needs a typed confirmation token.

**Read the rest of this document anyway.** The script automates the steps; it
does not automate the judgement — why the order matters, why the profile must
stay minimal, and what a change set will and will not bring with it. The manual
route below is also the only route in an org the `sf` CLI is not authorized for,
which the script will tell you about with the exact `sf org login web` command.

**The usernames are listed in the script, not derived**, because Dev's does not
follow the pattern the other three do:

| Environment | Org alias | Integration username |
| --- | --- | --- |
| Dev | `peodv8dvn` | `ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn` |
| QA | `peodv15dvn` | `ldgcrm_p3_integration@gsa.gov.peo.peodv15dvn` |
| UAT | `peofl1uatp` | `ldgcrm_p3_integration@gsa.gov.peo.peofl1uatp` |
| Prod | `gsa-peo` | `ldgcrm_p3_integration@gsa.gov.peo` |

Dev carries a **`peo1`** that no rule predicts. These users are created one org
at a time, so each username is a choice someone made rather than something a
pattern reproduces. Deriving them would have created a second Dev user under the
name the pattern predicts.

---

**In Dev (`peodv8dvn`) this is already done.** Measured 2026-09-09:

| | |
| --- | --- |
| Username | `ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn` |
| Profile | **Minimum Access - API Only Integrations** |
| Permission set license | **Salesforce API Integration** |
| Permission set | **LDGCRM_Partnership_Portal_API_R** ("LDGCRM - Partnership Portal API - R") |
| User type | `Standard`, active |

---

## 1. ⚠️ The license goes on FIRST, and the order is not a preference

Assign the **Salesforce API Integration** permission set license **before** the
permission set. Not because it is tidier — because the permission set cannot be
assigned without it.

`LDGCRM_Partnership_Portal_API_R` grants four user permissions:

```xml
<userPermissions><enabled>true</enabled><name>ApiEnabled</name></userPermissions>
<userPermissions><enabled>true</enabled><name>ApiUserOnly</name></userPermissions>
<userPermissions><enabled>true</enabled><name>ViewRoles</name></userPermissions>
<userPermissions><enabled>true</enabled><name>ViewSetup</name></userPermissions>
```

The last two are what let the integration call a Named Query — section 3.

**`ApiUserOnly` is the one that is gated.** It is the permission that makes a user
API-only, and Salesforce will only grant it to a user who already holds the
Salesforce API Integration license. Assign the permission set first and the
assignment is rejected — the permission set looks broken, when what is missing is
a license on the user.

The reverse order fails at nothing. Assign the license, then the permission set.

### The license is scarce, and it is shared with two other apps

Measured in Dev on 2026-09-09:

| | |
| --- | --- |
| Salesforce API Integration — total seats | **5** |
| Used | **1** (this user) |

Five seats for the whole org, and this org also hosts FCIC and TTS OTCRM. **Do
not burn one on a throwaway.** If seats are exhausted the assignment fails on
capacity, which reads nothing like a licensing problem.

### Doing it

*Setup → Users → `<the user>` → **Permission Set License Assignments** → Edit
Assignments* → tick **Salesforce API Integration** → Save.

Then, on the same user page:

*Setup → Users → `<the user>` → **Permission Set Assignments** → Edit Assignments*
→ add **LDGCRM - Partnership Portal API - R** → Save.

`https://gsa-peo--peodv8dvn.sandbox.lightning.force.com` for Dev.

---

## 2. The profile is `Minimum Access - API Only Integrations`

This is a stock Salesforce profile that ships with the API integration license. It
grants close to nothing on its own, which is the point: **every permission this
user has comes from the permission set**, so the permission set is a complete and
auditable statement of what the integration can reach.

Do not substitute a `GSA Standard *` profile. Those carry a broad baseline that
would silently widen the integration's reach beyond what the permission set says,
and the permission set would stop being the answer to "what can the portal see?".

---

## 3. ⚠️ Administering Named Queries needs a permission set on YOUR OWN user

Everything else in this document goes on the integration user. This one does not.

To reach *Setup → Integrations → Named Query API* and create or edit a Named
Query, **the human admin doing the work** needs the stock permission set below on
their own account. Being a System Administrator is not enough.

| | |
| --- | --- |
| Label | **Orgwide - Named Query - Admin** |
| API name | `Orgwide_Named_Query_Admin` |
| Assigned to | the admin building the query, **not** `ldgcrm_p3_integration` |

*Setup → Users → `<you>` → **Permission Set Assignments** → Edit Assignments* →
add **Orgwide - Named Query - Admin** → Save.

Confirmed in Dev on 2026-09-09, where it is the only permission set in the org
whose label mentions Named Query. The second query answers the one that matters,
which is whether it is on *your* account:

```powershell
sf data query --target-org peodv8dvn --query "SELECT Name, Label FROM PermissionSet WHERE Label LIKE '%Named Query%'"

# Substitute your own username.
sf data query --target-org peodv8dvn --query "SELECT PermissionSet.Label FROM PermissionSetAssignment WHERE Assignee.Username = '<you>' AND PermissionSet.Name = 'Orgwide_Named_Query_Admin'"
```

### API Catalog activation is a manual per-org step, and it is NOT what gates the call

Activating a Named Query in the **API Catalog** (*Setup → Integrations*) is a
separate manual act, done once per org. Worth doing, and worth writing down,
because **the component cannot carry it**:
[`ldgcrmPartnerPortalAdminQuery.apiNamedQuery-meta.xml`](../../sfdx/force-app/main/default/apiNamedQueries/ldgcrmPartnerPortalAdminQuery.apiNamedQuery-meta.xml)
holds four elements — `apiVersion`, `body2`, `description`, `masterLabel` — and
no status, active or published element of any kind. So a retrieve cannot record
the activation, a change set cannot deliver it, a `sf project deploy` cannot
either, and a sandbox refresh has nothing to restore it from. It joins sections
1, 2 and 3 on the list of things every org has to have done in it separately.

**Activation is not what lets a caller run one.** Salesforce's developer blog says
so directly: activation is for **agent action use**, and *"this activation does
not have to be performed in order for the Named Query API to be used as a REST
API."* An administrator read 1,089 rows from `ldgcrmPartnerPortalAdminQuery`
while it was still unactivated.

### ⚠️ CALLING a Named Query needs `View Setup and Configuration`

The REST API guide's *Named Query API* page states it under User Permissions
Needed:

> To execute a Named Query API: **View Setup and Configuration**

`ApiNamedQuery` is a setup entity. Salesforce resolves the query name by
querying it **as the caller**, and reports an entity the caller cannot see as a
column that does not exist — so a caller without this permission gets
`400 INVALID_FIELD` describing a schema fault that is not there. Read access on
the object the query SELECTs from governs which **rows** come back, not who may
**call**.

**Enabling it grants two permissions, not one.** Salesforce adds `ViewRoles`
("View Roles and Role Hierarchy") alongside `ViewSetup`; both came back in the
retrieve. Section 1 lists all four the permission set now carries.

In Dev, `ldgcrm_p3_integration` calls the named query successfully — 1,089
records, matching what an administrator gets from the same endpoint. Any other
org needs the permission set to arrive **in a change set**, per CLAUDE.md, never
a CLI deploy.

### ⚠️ That grant widens the integration beyond what section 2 promises

`ViewSetup` and `ViewRoles` are not object access, so **section 4's table is no
longer the whole answer to "what can the portal see?"**. The user can read Setup
— the org's configuration metadata, including FCIC's and TTS OTCRM's — and the
role hierarchy.

It is Salesforce's documented requirement, not a workaround, and there is no
narrower grant to choose. **Flag it whenever the integration's scope is
reviewed.** It is still far less than `Orgwide - Named Query - Admin`.

If configuration exposure is ever judged unacceptable, the fallback is
`Invoke-LdgcrmSalesforceQuery.ps1`, which reads the same rows on the same token
and needs neither permission.

### Do not conclude a permission is undocumented from the blog alone

Salesforce's developer blog and every community write-up say only that "the user
that executes the API request must have read access to the entity being queried."
That is true and it is not the whole requirement. The `User Permissions Needed`
table lives on the **reference** page, and the two together are the answer —
which is why this looked undocumented for a day. **Check the reference page's
permissions table before concluding a permission does not exist.**

**It is a permission set ASSIGNMENT, so it does not travel and does not survive.**
A change set cannot carry it, and a sandbox refresh drops it along with
everything else in sections 1 and 2. Expect to reassign it by hand.

### Why this looks like the feature being missing

Without it the Setup page is simply absent, which is indistinguishable from the
Named Query API not being enabled in the org at all. Check this permission set
before concluding anything about the feature.

**The API side looked like the same absence, and was not.** With no Named Query
defined, `SELECT Id FROM ApiNamedQuery` returns zero rows and the endpoint
answers `400 INVALID_FIELD` rather than a `404`. That was read on 2026-09-09 as
the feature being unprovisioned. It was not — the feature was on the whole time
and the table was **empty**.

The `400` says only that `ApiNamedQuery` has no `DeveloperName` column. Its label
field is `MasterLabel`. So the error describes the **schema**, not the
provisioning, and the query below works today with no org change of any kind:

```powershell
sf data query --use-tooling-api --target-org peodv8dvn --query "SELECT Id, MasterLabel FROM ApiNamedQuery"
```

**That same `400` has a second, unrelated cause, and it is the one that bites
now.** Salesforce resolves a Named Query's name by querying `ApiNamedQuery` **as
whoever called**, so when the caller cannot see that entity the failure surfaces
as the identical complaint about a column. The message therefore describes
neither the provisioning nor the query — it describes nothing that is wrong.
Both the empty-table case above and the permission case in the table earlier
produce it, which is why the error is worth nothing on its own and the
admin-versus-caller comparison is worth everything.

**Zero rows on a queryable table means empty, never absent.** A table that was not
provisioned would fail to resolve at all.

### The one that exists, and how to retrieve it

| | |
| --- | --- |
| API name | `ldgcrmPartnerPortalAdminQuery` |
| Label | Login.gov Partner Portal Admin Query |
| Selects | Partner Portal admins from `LDGCRM_Application_Contact__c` |
| Lives at | `sfdx/force-app/main/default/apiNamedQueries/` |

It is in `manifest/package.xml`, so a normal sync keeps it — **but only because
that manifest's `<version>` was raised to 67.0 in the same change.**

**⚠️ `ApiNamedQuery` does not exist below API version 65.0, and the retrieve lies
about it.** Retrieving the type against a manifest still saying `64.0` fails with
`Entity type 'ApiNamedQuery' is not available in this api version` while the run
reports `"status": "Succeeded"` and `"success": true`. The failure appears only in
the per-component `files` array, as `state: "Failed"`.

**The CLI's `--api-version` flag does not fix this.** It was tried at 67.0, 66.0
and 65.0 and failed identically every time, because the server checks the version
written into the **manifest**, which the flag does not change. The fix is the
manifest's own `<version>`:

```xml
<types>
    <members>ldgcrmPartnerPortalAdminQuery</members>
    <name>ApiNamedQuery</name>
</types>
<version>67.0</version>
```

So if that version is ever lowered, this component silently stops being retrieved
and the run still reports success. Check the component result, not the status.

---

## 4. What the permission set actually grants

Read-only throughout — the `_R` suffix follows the same convention as the other
three (`_CRE`, `_CRED`). Every object is `allowRead` with create, edit and delete
all false.

| Object | Read | View All Records |
| --- | --- | --- |
| Account | ✅ | ✅ **yes** |
| Contact | ✅ | ✅ **yes** |
| Opportunity | ✅ | no |
| `LDGCRM_application__c` | ✅ | no |
| `LDGCRM_Partner_Account__c` | ✅ | no |
| `LDGCRM_Application_Contact__c` | ✅ | no |
| `LDGCRM_Impediment__c` | ✅ | no |
| `LDGCRM_Opportunity_Impediment__c` | ✅ | no |
| `LDGCRM_Market_Segment__c` | ✅ | ✅ yes |
| `LDGCRM_Issuer_String__c` | ✅ | no |

**Account and Contact carry View All Records and View All Fields.** In this org
that is org-wide, which means the integration reads FCIC and TTS OTCRM Accounts
and Contacts too, not only the `Federal` and `GSA` record types this app owns.
That is a deliberate consequence of the grant, not an accident of sharing — flag
it if the portal's data scope is ever reviewed.

**`recordTypeVisibilities` does not narrow this.** The permission set lists
`Account.Federal`, `Contact.Federal`, `Opportunity.Login_gov` and
`LDGCRM_application__c.LDGCRM_Application`, and omits `Contact.GSA` — which exists
and is active in the org. That omission has **no effect on reads**: record type
visibility governs which types are selectable when creating or editing a record,
and this permission set grants neither. Do not "fix" it by adding `Contact.GSA`
expecting a visibility change; there is none to make.

---

## 5. ⚠️ `LDGCRM_Issuer_String__c` is granted, and production does not have it

The permission set grants read on `LDGCRM_Issuer_String__c`. That object was
created in **Dev on 2026-09-08 by Rahul Kamarouthu** — the go-live date, after the
production change set was built. Its Id prefix gives the same story: `01Ico…`,
against `01ISJ…` for the six objects that migrated together.

It is now retrieved into this repo and listed in `manifest/package.xml`, so
`Sync-Metadata.ps1` keeps it current. The object itself is small:

| | |
| --- | --- |
| Custom fields | **1** — `LDGCRM_Application__c` |
| That field | **Master-Detail** to `LDGCRM_application__c`, reparentable |
| Sharing | `ControlledByParent` |
| External ID field | **none** |
| Apex triggers | none |
| Records in Dev | **0** |

**A change set carrying the permission set must carry this object too**, or the
target org has to already have it. Production does not. Deploy the permission set
alone and it fails on the missing object reference.

### It replaces a field that production still has

`LDGCRM_application__c.LDGCRM_PP_Issuer_Strings__c` was a **Text(40), unique**
field holding one issuer string per Application, maintained by OEs from ZenDesk
move-to-production requests. The new object holds the same thing as a
**one-to-many child**, which is exactly the constraint that unique text field
imposed.

The field was **deleted from Dev on 2026-09-09**, and is no longer in this repo.

| | Holds | State |
| --- | --- | --- |
| `LDGCRM_PP_Issuer_Strings__c` (field) | one string per Application | **gone from Dev, still in production** |
| `LDGCRM_Issuer_String__c` (object) | many per Application | Dev only, **0 records** |

**The cutover is half done, in both directions.** Production still has the field
and not the object; Dev has the object and not the field. No data has moved into
the object — it is empty, and it is the one the integration user is granted read
on. So a portal pointed at Dev reads nothing, and the same portal pointed at
production has no object to read at all.

**Deleting the field from Dev does not keep it deleted.** It was deleted once
before, on 2026-08-14, and the sandbox refresh brought it back, because a refresh
copies production and a change set cannot carry a deletion. Expect it to return
on the next refresh, and expect to delete it by hand again, until production drops
it via a destructive Metadata API change carried by GSA IT Engineering.

The report type `LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings`
is named for issuer strings but joins **only** `LDGCRM_application__c`. It reported
the field, which no longer exists in Dev, and it does not join the new object.

---

## 6. What a change set can and cannot carry

| Thing | In a change set? |
| --- | --- |
| The permission set **definition** | ✅ Yes — component type **Permission Set** |
| The **user** record | ❌ No. Create it by hand in each org |
| The **permission set license** assignment | ❌ No. It is a user assignment, not metadata |
| The **permission set** assignment to the user | ❌ No. Same reason |
| The **Orgwide - Named Query - Admin** assignment on the admin | ❌ No. Section 3 |
| The Named Query's **API Catalog activation** | ❌ No. The component has no element for it. Section 3 |
| `LDGCRM_Issuer_String__c` | ⚠️ Must be in the same change set — production does not have it. Section 5 |

So a green change set deployment means the permission set arrived. It does not
mean the integration works, and nothing about the deployment will say so.

**A sandbox refresh wipes the user side of this entirely** — the user, the license
assignment and the permission set assignments all go, on the integration user and
on the admin alike. The permission set definitions survive, because they come from
production. After any refresh, expect to redo sections 1, 2 and 3, and nothing
else.

---

## 7. Verifying it

Run these rather than inferring from Setup pages. All three should return exactly
one row.

```powershell
# From inside sfdx/. Substitute the target org's alias and username.

# The license. Missing this is why a permission set assignment gets rejected.
sf data query --target-org peodv8dvn -q "SELECT PermissionSetLicense.MasterLabel, PermissionSetLicense.Status FROM PermissionSetLicenseAssign WHERE Assignee.Username = 'ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn'"

# The permission set. Filter out the profile's own row, which is always present.
sf data query --target-org peodv8dvn -q "SELECT PermissionSet.Name FROM PermissionSetAssignment WHERE Assignee.Username = 'ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn' AND PermissionSet.IsOwnedByProfile = false"

# The profile, and that the user is active.
sf data query --target-org peodv8dvn -q "SELECT Username, IsActive, UserType, Profile.Name FROM User WHERE Username = 'ldgcrm_p3_integration@gsa.gov.peo1.peodv8dvn'"
```

### ⚠️ A `PermissionSetAssignment` query always returns a row you did not ask for

Every user carries a **profile-owned permission set** — a real
`PermissionSetAssignment` whose `PermissionSet.Name` is the profile's Id with an
`X` in front (`X00e3d000000MPe0AAG`). It is not something anyone assigned and it
is not the integration's permission set.

An unfiltered query therefore returns **two** rows here and reads as if the setup
is already complete when only the profile is in place. `AND
PermissionSet.IsOwnedByProfile = false` is the filter that makes the answer
trustworthy — without it, the query cannot tell a configured user from an
unconfigured one.

### Seats remaining, before setting up another integration user

```powershell
sf data query --target-org peodv8dvn -q "SELECT MasterLabel, TotalLicenses, UsedLicenses, Status FROM PermissionSetLicense WHERE DeveloperName = 'SalesforceAPIIntegrationPsl'"
```
