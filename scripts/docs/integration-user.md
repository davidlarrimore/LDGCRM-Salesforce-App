# Setting up the P3 integration user

> **Who this is for:** whoever stands up the Partner Portal (P3) API integration in
> a new org, or repairs it after a sandbox refresh. It is the **user-side** setup:
> the license, the permission set and the order they go on in.
>
> None of this arrives with a change set. A change set carries the permission set
> **definition** and nothing else — not the user, not the license, not the
> assignment. Everything below is done by hand in every org.

The integration user is what the Partner Portal authenticates as when it reads the
CRM over the API. It is paired with the External Client App
`LDGCRM_P3_Client_app_Localdev` (see the comment block in
[`sfdx/manifest/package.xml`](../../sfdx/manifest/package.xml)), which holds the
OAuth side of the same integration.

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

`LDGCRM_Partnership_Portal_API_R` grants two user permissions:

```xml
<userPermissions><enabled>true</enabled><name>ApiEnabled</name></userPermissions>
<userPermissions><enabled>true</enabled><name>ApiUserOnly</name></userPermissions>
```

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

## 3. What the permission set actually grants

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

## 4. ⚠️ `LDGCRM_Issuer_String__c` is granted, and production does not have it

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

## 5. What a change set can and cannot carry

| Thing | In a change set? |
| --- | --- |
| The permission set **definition** | ✅ Yes — component type **Permission Set** |
| The **user** record | ❌ No. Create it by hand in each org |
| The **permission set license** assignment | ❌ No. It is a user assignment, not metadata |
| The **permission set** assignment to the user | ❌ No. Same reason |
| `LDGCRM_Issuer_String__c` | ⚠️ Must be in the same change set — production does not have it. Section 4 |

So a green change set deployment means the permission set arrived. It does not
mean the integration works, and nothing about the deployment will say so.

**A sandbox refresh wipes the user side of this entirely** — the user, the license
assignment and the permission set assignment all go. The permission set definition
survives, because it comes from production. After any refresh, expect to redo
sections 1 and 2 and nothing else.

---

## 6. Verifying it

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
