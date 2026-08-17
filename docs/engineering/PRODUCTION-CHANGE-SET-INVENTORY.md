# Production change set inventory

> **Who this is for:** the **GSA IT Engineering team**, to verify that every component
> below is present and correct in the target org after the change set is deployed.
>
> **Source change set:** `LDGCRM_Sprint_1_24`
>
> **Snapshotted:** **2026-08-17**, from Dev (`peodv8dvn`)
>
> **Total: 232 components across 24 metadata types.**

---

## About this snapshot

This is a **point-in-time record of what `LDGCRM_Sprint_1_24` contains.** It is not maintained against
the org. When a new version of the change set is cut, **regenerate this file** rather than
editing it - a partially-updated inventory is worse than an obviously dated one, because the
reader cannot tell which rows were refreshed:

```powershell
tools\metadata\Export-ChangeSetInventory.ps1 -ChangeSetName "LDGCRM_Sprint_1_24"
```

**Provenance, stated precisely because it bounds what this proves.** The contents were read
by retrieving the change set from **Dev (`peodv8dvn`)**, the org that *built* it.
It cannot be read from the receiving org: **an inbound change set is not retrievable**, and
Salesforce answers `INVALID_CROSS_REFERENCE_KEY: No package named 'LDGCRM_Sprint_1_24' found`. The
receiving org's inbound copy is the deployed form of this same outbound set and should match
component-for-component, but **that equivalence is an assumption this document does not
verify** - confirming it is the verification task itself.

Every count and description here was read from the retrieved XML, not from a Setup screen.

---

## Summary by metadata type

| Metadata type | Count |
| --- | ---: |
| CustomField | 128 |
| ListView | 14 |
| ReportType | 11 |
| Flow | 9 |
| FlexiPage | 8 |
| Layout | 8 |
| SharingOwnerRule | 8 |
| CustomObject | 6 |
| SharingCriteriaRule | 6 |
| CompactLayout | 5 |
| CustomTab | 4 |
| Profile | 4 |
| RecordType | 4 |
| PermissionSet | 3 |
| PermissionSetGroup | 3 |
| Group | 2 |
| PathAssistant | 2 |
| BusinessProcess | 1 |
| ContentAsset | 1 |
| CustomApplication | 1 |
| Dashboard | 1 |
| GlobalValueSet | 1 |
| Report | 1 |
| ValidationRule | 1 |
| **Total** | **232** |

---

## Custom fields (128)

Descriptions are the field's own Description, falling back to its inline help text.
`Attributes` records length, lookup target, external-ID/unique/required flags and roll-up
operation where set. **A `(formula)` type is not writable** - Salesforce rejects direct
writes, and the declared type alone does not reveal it.

### LDGCRM_Market_Segment__c (1)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID. **Stores the segment *name*** (`"Benefits"`, `"Defense"`, ...), not a `rec...` ID. |

### Account (2)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Market_Segment__c` | Market Segment | Lookup | -> `LDGCRM_Market_Segment__c` | Linked Market Segment |

### Activity (2)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Meeting_Type__c` | Meeting Type | Picklist |  | Category or purpose of the meeting. |

### OpportunityContactRole (3)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Date_Added__c` | Date Added | Date |  | Date contact was added to Salesforce |
| `LDGCRM_Date_Archived__c` | Date Archived | Date |  | Date contact was archived -- contact is no longer active in this role |
| `LDGCRM_External_ID__c` | External ID | Text | len 50 | External Airtable ID. **Not flagged `externalId`, and it cannot be** - Salesforce forbids External ID fields on this object. The object is loaded by insert + read-then-diff rather than upsert. |

### Contact (4)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Partner_Account__c` | Partner Account | Lookup | -> `LDGCRM_Partner_Account__c` | Partner Account the contact works for |
| `LDGCRM_Pronunciation__c` | Pronunciation | Text | len 50 | How to pronounce the contact's name |
| `LDGCRM_Subscription_Type__c` | Subscription Type | MultiselectPicklist |  | What kind of emails the contact should receive |

### LDGCRM_Impediment__c (5)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Blocked_Revenue__c` | Blocked Revenue | Summary | rollup: sum | Sum of blocked revenue from Opportunity Impediments. Roll-up Summary - Salesforce rejects direct writes. |
| `LDGCRM_Category__c` | Category | Picklist |  | Type of impediment |
| `LDGCRM_Description__c` | Description | LongTextArea | len 32768 | Overview of what the impediment is, along with any relevant links or documentation. |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Talking_Point__c` | Talking Point | LongTextArea | len 32768 | Ways to talk about the impediment to partners |

### LDGCRM_Opportunity_Impediment__c (5)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Blocked_Revenue__c` | Blocked Revenue | Currency |  | If the Severity is "Blocker", we consider it blocked revenue and use the Estimated Annual Revenue (Fully Ramped) from the Opportunity. **Populated by Flow - do not write directly.** |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External ID used for Airtable Migration |
| `LDGCRM_Impediment__c` | Impediment | MasterDetail | -> `LDGCRM_Impediment__c` | Related Impediment for this Opportunity Impediment Record |
| `LDGCRM_Opportunity__c` | Opportunity | MasterDetail | -> `Opportunity` | Related Opportunity for this Impediment |
| `LDGCRM_Severity__c` | Severity | Picklist | required | Is this impediment a "blocker"? |

### LDGCRM_Application_Contact__c (7)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Application__c` | Application | Lookup | -> `LDGCRM_application__c` |  |
| `LDGCRM_contact__c` | Contact | Lookup | -> `Contact`; required | Contact. **Note the lower-case `c` in the API name** - a real typo, and load scripts must respect it. |
| `LDGCRM_Email__c` | Contact Email | Text (formula) |  | Email address of related Contact |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | Airtable External ID. **Composite key** `<contactExtId>\|<applicationExtId>`, not a single Airtable `rec...` ID. |
| `LDGCRM_P3_Partner_Portal_Team_Name__c` | Partner Portal Team Name | Text (formula) |  | Name from the partner portal that was copied over. The name can be modified, so trust the Team UUID. |
| `LDGCRM_P3_Team_UUID__c` | Partner Portal Team UUID | Text (formula) |  | References partner portal team id that is consistent across environments. |
| `LGDCRM_P3_Partner_Portal_Admin__c` | Partner Portal Admin | Checkbox |  | Is this user a Partner Portal Admin. **Note the transposed `LGDCRM_` prefix.** |

### LDGCRM_Partner_Account__c (14)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Account__c` | Account | MasterDetail | -> `Account` | Parent Account for this Partner Account. Accounts refer to official/federal accounts based upon established Federal, State, Local hierarchies. Allows for acc |
| `LDGCRM_Active_Accounts_Folder_URL__c` | Active Accounts Folder URL | Url |  | Add Google Drive link for this account here. |
| `LDGCRM_Agreement_Short_Name__c` | Agreement Short Name | Text | len 50 | Agency abbreviation followed by the program/application the opportunity is in reference to. |
| `LDGCRM_Current_Status_Summary__c` | Current Status Summary | LongTextArea | len 131072 | A high level summary of the current state of the partner agency. It should include a one liner on who we are talking to (name, role) and what they are saying/blocked on. |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Initial_Agreement_Date__c` | Initial Agreement Date | Date |  | The PoP Start date of the partner agency |
| `LDGCRM_Market_Segment__c` | Market Segment | Lookup | -> `LDGCRM_Market_Segment__c` | Market Segment based upon Account. **Set by Flow** - the migration must never write it. |
| `LDGCRM_Partner_Account_Complexity__c` | Partner Account Complexity | Picklist |  | 5 - Largest and/or most complicated agencies in Government 4 - Large account that has high visibility, complex stakeholders. 3 - Medium sized account, not high maintenance, key contributor 2 - Medium sized account, not h... |
| `LDGCRM_Partner_Account_Health__c` | Partner Account Health | Picklist |  | The account health of the partner agency determined by the account manager and partner success manager based on factors such as the renewal status, partner sentiment, incidents, or outstanding funding issues. |
| `LDGCRM_Partner_Account_Owner__c` | Owner | Lookup | -> `User` | The Account Manager or Partner Success Manager responsible for the partner agreement and the first point of contact internal stakeholders to Login.gov should contact with inquiries about the partner agency. |
| `LDGCRM_Partner_Account_Priority__c` | Partner Account Priority | Picklist |  | High - Accounts with high engagement ie. recurring meetings, Enterprise pricing, TMF funded agreement, Partner Advisory Group member, pilot participation, etc. Medium - Accounts with high engagement only during specific... |
| `LDGCRM_Partner_Summary_URL__c` | Partner Summary URL | Url |  | A link to the agency/partner summary documentation where notes and drafted communications to partner agencies are tracked. |
| `LDGCRM_Service_Type__c` | Service Type | Picklist |  | The highest assurance level integrated on a partner agreement |
| `LDGCRM_Status__c` | Status | Picklist |  | The status of the partner agency. This will indicate if the partner is on a signed agreement with applications with active usage, on a signed agreement but no applications with active usage, or is no longer an active agr... |

### Opportunity (31)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Alternative_Identity_Platforms__c` | Alternative Identity Platforms | MultiselectPicklist |  | Alternatives the lead is considering instead of Login.gov. |
| `LDGCRM_App_Description__c` | App Description | LongTextArea | len 32768 | A couple sentences explaining the use case of an application or multiple applications, including name and URL. |
| `LDGCRM_Cost_Estimate_URL__c` | Cost Estimate URL | Url |  | URL of the opportunity's cost estimate or folder of cost estimates. |
| `LDGCRM_Current_Status_Summary__c` | Current Status Summary | Html | len 32768 | Brief big-picture overview on who we are talking to and what they are saying/blocked on. Start entries with MM/DD/YY. |
| `LDGCRM_Days_Since_Last_Activity__c` | Days Since Last Activity | Number (formula) |  | Calculates the number of days since this Opportunity was last touched (any Call, Task, or Event logged against it), using Salesforce's native Last Activity Date. Returns 9999 if no activity has ever been logged. Used to... |
| `LDGCRM_Demographic_Served__c` | Demographic Served | MultiselectPicklist |  | Demographic of end users served by the application. |
| `LDGCRM_Est_Annual_Auth_Only_Users__c` | Est. Annual Auth-only Users | Number |  | Estimate of the number of auth-only users, who would not use IdV (fully ramped up). |
| `LDGCRM_Est_Annual_Idv_Users__c` | Est. Annual IdV Users | Number |  | Estimate of the number of annual IdV users, which would each cost $1 under the new pricing model (fully ramped up). |
| `LDGCRM_Est_Annual_Revenue_fully_ramped__c` | Est. Annual Revenue (Fully Ramped) | Currency (formula) |  | What we estimate the opportunity to be worth when usage is fully ramped up. (“Est. Annual IdV Users” x $1 + (“Est. Annual Auth-only Users” x “Est. Auth-only User Active Months” x $0.025.) |
| `LDGCRM_Est_Auth_Only_Avg_Active_Months__c` | Est. Auth-only Avg Active Months | Number |  | Estimate the number of months, on average, that auth-only users will be active. |
| `LDGCRM_Est_First_Year_Ramp__c` | Est. First Year Ramp % | Percent |  | Percentage of fully ramped revenue we should expect in the first year of the agreement. Defaults to 50%, but could be around 20% for a prolonged soft launch or 100% if it’s a hard cut over from an existing solution. |
| `LDGCRM_Est_First_Year_Revenue__c` | Est. First Year Revenue | Currency (formula) |  | What we can expect in the first year based on “Est. Annual Revenue (fully ramped)” x “First Year Ramp %” |
| `LDGCRM_Estimate_Rationale__c` | Estimate rationale | Html | len 32768 | Rough explanation of the math of how we got to the estimated annual auth-only and and IdV users, as well as First Year Ramp %. If it’s research and not partner provided, consider: |
| `LDGCRM_Estimate_Source__c` | Estimate source | Picklist |  |  |
| `LDGCRM_Estimated_Go_Live_Date__c` | Estimated Go-Live Date | Date |  | Estimated Go-Live Date for Application |
| `LDGCRM_Existing_Identity_Platforms__c` | Existing Identity Platforms | MultiselectPicklist |  | Which service providers the lead is currently using. |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Focus_Level__c` | Focus Level | Picklist |  | How the OM team is focusing on this at the moment. |
| `LDGCRM_Level_of_Priority__c` | Level of Priority | Picklist |  | Originally created for TTS OTCRM - Login.gov Opportunities |
| `LDGCRM_Likely_Service_Level_Needed__c` | Likely Service Level Needed | Picklist |  | Our best guess on the service level needed. |
| `LDGCRM_Market_Segment__c` | Market Segment | Lookup | -> `LDGCRM_Market_Segment__c` | Related Market Segment. **Set by Flow** - the migration must never write it. |
| `LDGCRM_Opportunity_Type__c` | Opportunity Type | Picklist |  | Please select the type of Opportunity. |
| `LDGCRM_Partner_Account__c` | Partner Account | Lookup | -> `LDGCRM_Partner_Account__c` | Lookup to the Partner Account |
| `LDGCRM_Recent_Conversations__c` | Recent Conversations | Html | len 32768 | Recap of the last communication to a lead (who, rough agenda, next steps). Start entries with MM/DD/YY. |
| `LDGCRM_Sandbox_URL__c` | Sandbox URL | Url |  | URL to the sandbox to see what activity is happening there. |
| `LDGCRM_Status__c` | Status | Picklist |  | The status of the opportunity as it moves through the pipeline. |
| `LDGCRM_Status_Summary_Indicator__c` | Status Summary Indicator | Checkbox (formula) |  | Is the Status Summary up-to-date? |
| `LDGCRM_Status_Summary_Modified_Datetime__c` | Status Summary Last Modified Datetime | DateTime |  | Denotes when the Status Summary Field was Last updated. **Set by Flow.** |
| `LDGCRM_Summary_URL__c` | Summary URL | Url |  | Link to opportunity summary / notes document |
| `LDGCRM_Technical_Checklist_URL__c` | Technical Checklist URL | Url |  | URL of the technical checklist filled out by the partner. |
| `LDGCRM_Technical_Readiness__c` | Technical Readiness | Picklist |  | How ready is this opportunity to move forward technically. |

### LDGCRM_application__c (54)

| API name | Label | Type | Attributes | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Account_Manager_Approved__c` | Account Manager Approved | Checkbox |  | AM has verified all launch details are accurate and we are ready for launch after the partner submits a move to production request. |
| `LDGCRM_Actual_Go_Live_Date__c` | Actual Go-Live Date | Date |  | Date the application went live in production. |
| `LDGCRM_Agreement_Finalization_Email_Sent__c` | Agreement Finalization Email Sent | Checkbox |  | Once the IAA/IGCA is finalized, reach out to the partner to communicate next steps to deployment. |
| `LDGCRM_Annual_Revenue_Amount__c` | Annual Revenue Amount | Currency (formula) |  | Annual Revenue Amount, which is based upon Opportunity Amount |
| `LDGCRM_Broker_App_Parent__c` | Broker App Parent | Lookup | -> `LDGCRM_application__c` | Reference to the parent application the brokered application is a part of.. Self-referential lookup - cannot resolve within its own upsert batch and needs a second pass. |
| `LDGCRM_Broker_Application__c` | Broker Application | Checkbox |  | Whether this application is a broker application serving many sub applications |
| `LDGCRM_Completed_Customer_Support_Survey__c` | Completed Customer Support Survey | Url |  | URL of completed Login.gov User Support Survey. |
| `LDGCRM_Completed_Fraud_Survey__c` | Completed Fraud Survey | Url |  | URL of completed Login.gov Partner Fraud Risk Survey. |
| `LDGCRM_Completed_Security_Survey_URL__c` | Completed Security Survey URL | Url |  | URL of completed Login.gov Partner Security Survey. |
| `LDGCRM_Current_Go_Live_Date__c` | Current Go-Live Date | Date |  | The most up-to-date go live date that accounts for any previous delays or pauses. |
| `LDGCRM_Customer_Support_Meeting__c` | Customer Support Meeting | Checkbox |  | Includes Customer Support Lead to discuss help desk info, workflows, contact center reporting. |
| `LDGCRM_Demographic_Served__c` | Demographic Served | MultiselectPicklist |  | Describes the end users of the application |
| `LDGCRM_Description__c` | Description | LongTextArea | len 32768 | What the application does |
| `LDGCRM_External_ID__c` | External ID | Text | len 50; external ID | External Airtable ID |
| `LDGCRM_Finalized_Application_Details__c` | Finalized Application Details | Checkbox |  | Application record has been reviewed and vital info and usage info is up to date. |
| `LDGCRM_Followup_Tech_Sync_Scheduled__c` | Coordinated Optional Follow-up Tech Sync | Checkbox |  | Scheduled follow up tech sync. |
| `LDGCRM_Fraud_Meeting_Held__c` | Fraud Meeting Held | Checkbox |  | Led by the Fraud Ops team to discuss risks and threat impacts. |
| `LDGCRM_IDV_Upgrade__c` | IdV Upgrade? | Checkbox |  | Checkbox indicating whether this application is a candidate for IdV upgrade |
| `LDGCRM_Launch_Activities_Completed__c` | Launch Activities Completed | Checkbox |  | Confirmed Login.gov representative participated in any agency required launch day activities. |
| `LDGCRM_Launch_Activities_Confirmed__c` | Confirmed Launch Activities | Checkbox |  | Confirmed if Agency expects Login.gov participation in any agency-led pre-launch or launch day activities. |
| `LDGCRM_Launch_Checklist_Completion__c` | Launch Checklist Completion % | Percent (formula) |  | Overall launch checklist competed |
| `LDGCRM_Launch_Checklist_URL__c` | Launch Checklist URL | Url |  | Link to the Launch Checklist URL with relevant details for the launch. |
| `LDGCRM_Launch_Coordinators_Kickoff_Call__c` | Launch Coordinators Kick-off Call | Checkbox |  | Internal call to coordinate on outstanding needs before the Launch Kick-off Meeting with the partner. |
| `LDGCRM_Launch_Deck_URL__c` | Launch Deck URL | Url |  | Link to the App Launch Deck with relevant details for the launch. |
| `LDGCRM_Launch_Kickoff_Meeting_Held__c` | Launch Kick-off Meeting Held | Checkbox |  | Introduce a partner agency to the Login.gov launch process for Level 3+ / IdV application launches. |
| `LDGCRM_Launch_Level__c` | Launch Level | Picklist |  | The Launch Level for a given application |
| `LDGCRM_Launch_Risk__c` | Launch Risk | Checkbox |  | Flags that an application is at risk because it's level 3+, checklist is less than 80% and its launch date is within 30 days. |
| `LDGCRM_Launch_Tested__c` | Launch Tested | Checkbox |  | Agency has tested and confirmed application functionality within the Login.gov Sandbox environment. |
| `LDGCRM_Level_1_Complete_Pct__c` | Level 1+ Complete % | Percent (formula) |  | Percentage indicating Level 1 Launch Checklist |
| `LDGCRM_Level_3_Complete_Pct__c` | Level 3+ Complete % | Percent (formula) |  |  |
| `LDGCRM_Level_4_Complete_Pct__c` | Level 4+ Complete % | Percent (formula) |  |  |
| `LDGCRM_Market_Segment__c` | Market Segment | Lookup | -> `LDGCRM_Market_Segment__c` | Market Segment based upon Partner Account -> Account. **Set by Flow** - the migration must never write it. |
| `LDGCRM_Marketing_Strategy__c` | Marketing/Comms Strategy | Checkbox |  | Confirm if agency expects Login.gov participation in pre-launch or launch day activities. |
| `LDGCRM_No_Customer_Support_Meeting__c` | Customer Support Meeting Unnecessary | Checkbox |  | A decision was made not to require this meeting. |
| `LDGCRM_No_Fraud_Meeting__c` | Fraud Meeting Deemed Unnecessary | Checkbox |  | Fraud ops team decided not to require this meeting. |
| `LDGCRM_No_Launch_Kickoff_Meeting__c` | Launch Kick-off Meeting Unnecessary | Checkbox |  | No Launch Kickoff meeting is necessary |
| `LDGCRM_No_Security_Meeting__c` | Security Meeting Deemed Unnecessary | Checkbox |  | Security team decided not to require this meeting. |
| `LDGCRM_No_UX_Meeting__c` | UX Meeting Deemed Unnecessary | Checkbox |  | A decision was made not to require this meeting. |
| `LDGCRM_Opportunity__c` | Opportunity | Lookup | -> `Opportunity` | Specific deal or revenue event with an account |
| `LDGCRM_Opportunity_Lead__c` | Opportunity Lead | Text (formula) |  | Returns first name, last name and email of the opportunity lead. |
| `LDGCRM_Opportunity_Stage__c` | Opportunity Stage | Text (formula) |  | Linked Opportunity Stage. |
| `LDGCRM_P3_Partner_Portal_Team_Name__c` | Partner Portal Team Name | Text | len 255 | Name from the partner portal that was copied over. The name can be modified, so trust the Team UUID. |
| `LDGCRM_P3_Team_UUID__c` | Partner Portal Team UUID | Text | len 255 | References partner portal team id that is consistent across environments. |
| `LDGCRM_Partner_Account__c` | Partner Account | Lookup | -> `LDGCRM_Partner_Account__c`; required | Link to the partner agreement the application falls under. |
| `LDGCRM_Production_Launch_Completed__c` | Launch to Production Completed by OE | Checkbox |  | Implement Launch To Production standard operating procedure. |
| `LDGCRM_Ramp_Up_Approach__c` | Ramp Up Approach | Picklist |  | What we expect from the application usage curve |
| `LDGCRM_Requested_CC_Reporting__c` | Requested Contact Center Reporting | Checkbox |  | Initiate process for adding new agency applications for Contact Center reporting. Takes 6-8 weeks. |
| `LDGCRM_Security_Meeting__c` | Security Meeting | Checkbox |  | Led by security team. Combine with Fraud Meeting for the time being. |
| `LDGCRM_Sent_Integration_Approval_Request__c` | Integration Request Approval Sent | Checkbox |  | OE has confirmed the service level for the integration request matches AirTable. |
| `LDGCRM_Service_Level__c` | Service Level | Picklist |  | Level of identity service provided |
| `LDGCRM_Status__c` | Status | Picklist |  | Status of the application lifecycle |
| `LDGCRM_Support_Information__c` | Support Information | LongTextArea | len 32768 | Contact or support/helpdesk information for this application |
| `LDGCRM_URL__c` | URL | Url |  | URL of the live application |
| `LDGCRM_UX_Meeting_Held__c` | UX Meeting | Checkbox |  | Led by a Solutions Architect to discuss user flow scenarios and proofing fallback. |

---

## Flows (9)

The `Status` column is the status **in the change set XML**, which is not a guarantee of
the status after deployment - see the verification notes.

| API name | Status | Object | Trigger | Description |
| --- | --- | --- | --- | --- |
| `LDGCRM_Application_Before_Save_Assign_Market_Segment` | Active | LDGCRM_application__c | RecordBeforeSave, CreateAndUpdate | Assigns Market Segment on Record Creation based upon Partner Account (Which is a required field) or On Update if Re-Parented |
| `LDGCRM_ApplicationContact_BeforeSave_NewRecordDuplicateCheck` | Active | LDGCRM_Application_Contact__c | RecordBeforeSave, Create | Checks to see if Contact has already been assigned to Application |
| `LDGCRM_Opportunity_Before_Save_Assign_Account_and_Market_Segment` | Active | Opportunity | RecordBeforeSave, CreateAndUpdate | Based Upon Account, set Market Segment |
| `LDGCRM_Opportunity_Impediment_Before_Save_New_Record_Duplicate_Check` | Active | LDGCRM_Opportunity_Impediment__c | RecordBeforeSave, Create | Checks to see if Opportunity Impediment already exists |
| `LDGCRM_Partner_Account_After_Save_Update_Re_Parent_Cascade` | Active | LDGCRM_Partner_Account__c | RecordAfterSave, Update | Cascade updates of Market Segment AND Account if the Partner Account is Re-Parented to a Different Account |
| `LDGCRM_Partner_Account_Before_Save_Create_Update_Market_Segment` | Active | LDGCRM_Partner_Account__c | RecordBeforeSave, Create | Runs only when a "New" Partner Account. Automatically assigns/sets Market Segment Based upon Selected Account |
| `LGDCRM_Opportunity_After_Save_Update_Opportunity_Impediments` | Active | Opportunity | RecordAfterSave, Update | Updates Opportunity Impediments Blocked Amount (If conditions apply) |
| `LGDCRM_Opportunity_Before_Save_Update_Current_Status_Summary_DateTime` | Active | Opportunity | RecordBeforeSave, Update | If the Current Status Summary field is updated, it updates the Current Status Summary DateTime Field to NOW() |
| `LGDCRM_Opportunity_Impediment_Before_Save_Update_Blocked_Revenue` | Active | LDGCRM_Opportunity_Impediment__c | RecordAfterSave, CreateAndUpdate | On creation/Update, calculates/recalculates the Blocked Amount |

---

## Sharing rules (14)

| Object | Kind | API name | Access | Shared from | Shared to | Criteria |
| --- | --- | --- | --- | --- | --- | --- |
| Account | Criteria | `LDGCRM_Account_Federal_Record_Type_R` | Read |  | LDGCRM_Viewers | RecordTypeId equals Federal |
| Account | Criteria | `LDGCRM_Account_Federal_Record_Type_R_W` | Edit |  | LDGCRM_Team_Members | RecordTypeId equals Federal |
| Contact | Criteria | `LDGCRM_Contact_Federal_GSA_R` | Read |  | LDGCRM_Viewers | RecordTypeId equals Federal AND RecordTypeId equals GSA |
| Contact | Criteria | `LDGCRM_Federal_and_GSA_R_W` | Edit |  | LDGCRM_Team_Members | RecordTypeId equals Federal AND RecordTypeId equals GSA |
| LDGCRM_application__c | Owner | `LDGCRM_Application_All_R` | Read | LDGCRM_Team_Members | LDGCRM_Viewers |  |
| LDGCRM_application__c | Owner | `LDGCRM_Application_All_R_W` | Edit | LDGCRM_Team_Members | LDGCRM_Team_Members |  |
| LDGCRM_Application_Contact__c | Owner | `LDGCRM_Application_Contact_All_R` | Read | LDGCRM_Team_Members | LDGCRM_Viewers |  |
| LDGCRM_Application_Contact__c | Owner | `LDGCRM_Application_Contact_All_R_W` | Edit | LDGCRM_Team_Members | LDGCRM_Team_Members |  |
| LDGCRM_Impediment__c | Owner | `LDGCRM_Impediment_All_R` | Read | LDGCRM_Team_Members | LDGCRM_Viewers |  |
| LDGCRM_Impediment__c | Owner | `LDGCRM_Impediment_All_R_W` | Edit | LDGCRM_Team_Members | LDGCRM_Team_Members |  |
| LDGCRM_Market_Segment__c | Owner | `LDGCRM_Market_Segment_All_R` | Read | LDGCRM_Team_Members | LDGCRM_Viewers |  |
| LDGCRM_Market_Segment__c | Owner | `LDGCRM_Market_Segment_All_R_W` | Edit | LDGCRM_Team_Members | LDGCRM_Team_Members |  |
| Opportunity | Criteria | `LDGCRM_Opportunity_Federal_R` | Read |  | LDGCRM_Viewers | RecordTypeId equals Login.gov |
| Opportunity | Criteria | `LDGCRM_Opportunity_Federal_R_W` | Edit |  | LDGCRM_Team_Members | RecordTypeId equals Login.gov |

## Permission sets (3)

| API name | Label | Description | Field permissions |
| --- | --- | --- | ---: |
| `LDGCRM_Partnership_Team_Member_CRE` | LDGCRM - Partnership Team Member - CRE | CRE access to Login.gov CRM Application | 325 |
| `LDGCRM_Partnership_Viewer_R` | LDGCRM - Partnership Viewer - R | Read Only (R) access to Login.gov CRM Application | 245 |
| `LDGCRM_Production_Support_CRED` | LDGCRM - Production Support - CRED | CRED access to Login.gov CRM Application | 324 |

## Report types (11)

| API name | Label | Base object |
| --- | --- | --- |
| `LDGCRM_Login_gov_Applications_with_Activities` | Login.gov Applications with Activities | LDGCRM_application__c |
| `LDGCRM_Login_gov_Applications_with_Application_Contacts` | Login.gov Applications with Application Contacts | LDGCRM_application__c |
| `LDGCRM_Login_gov_Applications_with_Partner_Portal_Issuer_Strings` | Login.gov Applications with Partner Portal Issuer Strings | LDGCRM_application__c |
| `LDGCRM_Login_gov_Market_Segments_with_Accounts` | Login.gov Market Segments with Accounts | LDGCRM_Market_Segment__c |
| `LDGCRM_Login_gov_Market_Segments_with_Accounts_with_Opportunities` | Login.gov Market Segments with Accounts with Opportunities | LDGCRM_Market_Segment__c |
| `LDGCRM_Login_gov_Market_Segments_with_Accounts_with_Partner_Accounts` | Login.gov Market Segments with Accounts with Partner Accounts | LDGCRM_Market_Segment__c |
| `LDGCRM_Login_gov_Market_Segments_with_Partner_Accounts_with_Applications` | Login.gov Market Segments with Partner Accounts with Applications | LDGCRM_Market_Segment__c |
| `LDGCRM_Login_gov_Opportunities_with_Activity` | Login.gov Opportunities with Activity | Opportunity |
| `LDGCRM_Login_gov_Opportunities_with_Impediments` | Login.gov Opportunities with Impediments | Opportunity |
| `LDGCRM_Market_Segments` | Login.gov Market Segments | LDGCRM_Market_Segment__c |
| `LGDCRM_Partner_Accounts` | Login.gov Partner Accounts | LDGCRM_Partner_Account__c |

## List views (14)

| Object | API name | Label |
| --- | --- | --- |
| Account | `AllAccounts` | All Accounts |
| Account | `LDGCRM_All_Login_Gov_Accounts` | All Login.gov Accounts |
| Contact | `AllContacts` | All Contacts |
| LDGCRM_application__c | `LDGCRM_Recently_Launched` | Recently Launched |
| LDGCRM_application__c | `LDGCRM_Upcoming_Launches` | Upcoming Launches |
| LDGCRM_application__c | `LGDCRM_All_Applications` | All Applications |
| LDGCRM_Impediment__c | `All` | All |
| LDGCRM_Impediment__c | `LDGCRRM_All_Impediments` | All Impediments |
| LDGCRM_Market_Segment__c | `All` | All Records |
| LDGCRM_Market_Segment__c | `LDGCRM_All_Market_Segments` | All Market Segments |
| LDGCRM_Partner_Account__c | `LDGCRM_All_Partner_Accounts` | All Partner Accounts |
| Opportunity | `All_Opportunities` | All Opportunities |
| Opportunity | `LDGCRM_All_Login_gov_Opportunities` | All Login.gov Opportunities |
| Opportunity | `LDGCRM_Top_Opportunities` | Top Login.gov Opportunities |

## Global value sets (1)

**`Demographic_Served`** - 25 values: Federal Employees; Government Employees (Military); General Population; Veterans; Non-USC; Gov't Employees (Contractors); Agency Staff; State & Local Employees; Grantees; Banking Organization; Employers; Educators; Agency Customers; Students; Grantors; Authorized Personnel; Tribal Nations; Retirees - Former Government Employees; Other Organizations; Law Enforcement; Annuitants; Young Adults; Former Federal Employees; Minors 13-18; Credit Unions

---

## Remaining components

### BusinessProcess (1)

| Component | Notes |
| --- | --- |
| `Opportunity.Login.gov` |  |

### CompactLayout (5)

| Component | Notes |
| --- | --- |
| `Account.Federal_Compact_Layout` |  |
| `Account.LDGCRM_Federal_Account_Compact_Layout` |  |
| `Contact.LDGCRM_Federal_Compact_Layout` |  |
| `LDGCRM_Market_Segment__c.Custom_Compact_Layout` |  |
| `Opportunity.LDGCRM_Opportunity_Compact_Layout` |  |

### ContentAsset (1)

| Component | Notes |
| --- | --- |
| `login2` |  |

### CustomApplication (1)

| Component | Notes |
| --- | --- |
| `LDGCRM_Login_Gov_CRM_App` |  |

### CustomObject (6)

| Component | Notes |
| --- | --- |
| `LDGCRM_application__c` | Required Lookup to Partner Account; optional Lookup to Opportunity. |
| `LDGCRM_Application_Contact__c` | Junction of Application and Contact via **two Lookups**, not Master-Detail - which is why it needs a duplicate-check Flow. |
| `LDGCRM_Impediment__c` |  |
| `LDGCRM_Market_Segment__c` | Five fixed segments, assigned down the hierarchy by Flow. |
| `LDGCRM_Opportunity_Impediment__c` | True junction with **two Master-Detail** relationships (Impediment and Opportunity), so both parents must exist first. |
| `LDGCRM_Partner_Account__c` | Master-Detail child of Account; represents the partner agreement. |

### CustomTab (4)

| Component | Notes |
| --- | --- |
| `LDGCRM_application__c` |  |
| `LDGCRM_Impediment__c` |  |
| `LDGCRM_Market_Segment__c` |  |
| `LDGCRM_Partner_Account__c` |  |

### Dashboard (1)

| Component | Notes |
| --- | --- |
| `LDGCRM_Login_Gov_Dashboards` |  |

### FlexiPage (8)

| Component | Notes |
| --- | --- |
| `LDGCRM_Application_Record_Page` |  |
| `LDGCRM_Federal_Account_Record_Page` |  |
| `LDGCRM_Federal_Contact_Record_Page` |  |
| `LDGCRM_Home_Page` |  |
| `LDGCRM_Impediment_Record_Page` |  |
| `LDGCRM_Market_Segment_Record_Page` |  |
| `LDGCRM_Opportunity_Page` |  |
| `LDGCRM_Partner_Account_Record_Page` |  |

### Group (2)

| Component | Notes |
| --- | --- |
| `LDGCRM_Team_Members` |  |
| `LDGCRM_Viewers` |  |

### Layout (8)

| Component | Notes |
| --- | --- |
| `Contact-LDGCRM Federal Contact Layout` |  |
| `LDGCRM_application__c-Application Layout` |  |
| `LDGCRM_Application_Contact__c-Application Contact Layout` |  |
| `LDGCRM_Impediment__c-Impediments Layout` |  |
| `LDGCRM_Market_Segment__c-Market Segment Layout` |  |
| `LDGCRM_Opportunity_Impediment__c-Opportunity Impediment Layout` |  |
| `LDGCRM_Partner_Account__c-Partner Account Layout` |  |
| `Opportunity-Login.gov CRM` |  |

### PathAssistant (2)

| Component | Notes |
| --- | --- |
| `LDGCRM_Application_Path` |  |
| `Login_gov_Opportunity_Path` |  |

### PermissionSetGroup (3)

| Component | Notes |
| --- | --- |
| `LDGCRM_G_Partnership_Team_Member_CRE` |  |
| `LDGCRM_G_Partnership_Viewer_R` |  |
| `LDGCRM_G_Production_Support_CRED` |  |

### Profile (4)

| Component | Notes |
| --- | --- |
| `GSA Standard Basic User` |  |
| `GSA Standard Platform User` |  |
| `GSA Standard Salesforce User` |  |
| `GSA System Administrator` |  |

### RecordType (4)

| Component | Notes |
| --- | --- |
| `Account.Federal` |  |
| `Contact.Federal` |  |
| `LDGCRM_application__c.LDGCRM_Application` | The object's only active record type. |
| `Opportunity.Login_gov` | Distinct from `TTS_OTCRM_Opportunity`, which this migration never writes. |

### Report (1)

| Component | Notes |
| --- | --- |
| `LDGCRM_Reports` |  |

### ValidationRule (1)

| Component | Notes |
| --- | --- |
| `Account.Level1_and_Level2_account_restrictions` |  |

---

## Verification notes

Five ways a component looks deployed when it is not, or the reverse. Each has cost time on
this project.

1. **A Flow can be Active in the change set and land as Draft in the target.** All of the
   flows above once landed in QA as Draft, and the migration still ran to completion - 8,740
   records, zero failures, every object count matching - because flow activation changes
   field *contents*, not row counts. **Verify status in the target org, not against this
   document:** `SELECT ApiName, IsActive FROM FlowDefinitionView WHERE ApiName LIKE
   'LDGCRM%'`, then **repeat it for `'LGDCRM%'`** - some flows use a transposed prefix, and
   a single `LIKE '%DGCRM%'` matches neither reliably.
2. **A change set cannot delete anything.** Components removed in the source org survive in
   the target and appear in no deployment report. They must be deleted by hand in Setup.
3. **A profile is merged, not replaced.** Permissions already in the target's profile stay,
   so \
4. **Record-type picklist narrowing is enforced on load and is invisible to `sf sobject
   describe`,** which reports field-level values only. Read
   `objects/<Object>/recordTypes/<RecordType>.recordType-meta.xml` instead - its `fullName`
   entries are URL-encoded (`,`->`%2C`, `/`->`%2F`, `&`->`%26`).
5. **A metadata deploy deactivates a picklist value rather than deleting it,** and
   `sf sobject describe` hides inactive values - so a field can look clean while the old
   value is still in the value set. The retrieved metadata file is the authority.
