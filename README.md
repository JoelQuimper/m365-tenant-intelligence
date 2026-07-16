# M365 Tenant Intelligence Platform

## Vision

Build a Microsoft Fabric-based SaaS platform that provides a unified, historical, and intelligent view of a school board's Microsoft 365 environment.

The goal is to generate actionable insights and recommendations around:

- Adoption
- Licensing
- Governance
- Security
- Collaboration
- Compliance
- Cost optimization

Positioning: a Copilot-like operational intelligence layer for Microsoft 365 tenants.

> ⚠️ **WARNING**  
> This project is not supported and is for demonstration purposes only. It is only at its early stages and is not yet feature-complete. It is not intended for use in production environments. It is provided "as-is" without any warranties or guarantees. Use at your own risk.

## Getting Started
To get started with the M365 Tenant Intelligence Platform, follow these steps:

1. Install [Azure CLI](https://learn.microsoft.com/en-us/cli/azure/install-azure-cli).

2. Clone the repository:

```bash
git clone https://github.com/JoelQuimper/m365-tenant-intelligence.git
cd m365-tenant-intelligence
```

3. Configure your environment variables:
   - Copy `Set-DeveloperContext.template.ps1` to `Set-DeveloperContext.ps1`
   - Update the values with your Azure subscription and Key Vault details
   - **Note:** `Set-DeveloperContext.ps1` is excluded from version control for security

```powershell
Copy-Item Set-DeveloperContext.template.ps1 Set-DeveloperContext.ps1
```

4. Edit `Set-DeveloperContext.ps1` with your Azure environment details (subscription IDs, storage account names, etc.)

5. Run the script to set environment variables in your PowerShell session:

```powershell
.\Set-DeveloperContext.ps1
```

## Problem Statement

Organizations must navigate multiple portals to understand tenant health, risk, and optimization opportunities.

Data is fragmented across sources such as:

- Microsoft Entra ID
- Microsoft Graph
- Teams / SharePoint / Exchange admin centers
- Microsoft Purview
- Microsoft 365 Usage Analytics
- Audit logs
- Power Platform admin center

Customers typically lack:

- A single pane of glass
- Multi-year historical visibility
- Cross-service correlation
- Prioritized recommendations
- Executive-ready reporting

## Core Objectives

1. Centralize tenant intelligence into a unified data model.
2. Have the ability to preserve a configurable amount of time for operational and activity history.
3. Generate actionable insights, not only static reporting.
4. Enable natural-language exploration and recommendations.

## Key Questions The Platform Must Answer

- Is my tenant healthy?
- Are licenses being used efficiently?
- What are the top governance and security risks?
- What should be cleaned up next?
- Where can we save money?
- How is adoption changing over time?

## High-Level Architecture

```
┌──────────────────────┐
│  Microsoft Graph API │
└──────────┬───────────┘
           │ 
Extracted via permission
added to the Automation 
Account Managed identity.
No Graph PowerShell module 
needed. A custom module is 
used to handle Graph API 
calls and retries.
           │ 
           ↓
┌──────────────────────┐
│  Azure Automation    │
│  • PS get data       │
│  • Flatten JSONs     │
└──────────┬───────────┘
           │
Added using AZ CLI.  
           │ 
           ↓
┌──────────────────────┐
│  Azure Storage       │
│  • users.json        │
│  • licenses.json     │
│  • ...               │
└──────────┬───────────┘
           │ 
Table Shortcut Transformation
           │ 
           ↓
┌──────────────────────┐
│ Microsoft Fabric LH  │
│  • Tables            │
└──────────┬───────────┘
           │ 
DirectLake Semantic Model
           │ 
           ↓
┌──────────────────────┐
│ Reporting & Insights │
└──────────────────────┘
```
### Source Systems

#### Microsoft Graph

- Users
- Groups
- Teams
- SharePoint sites and drives
- Guests
- Devices
- Licenses

#### Microsoft 365 Usage Reports

- Teams usage
- SharePoint usage
- OneDrive usage
- Exchange usage
- Copilot usage

#### Audit Sources (latter stages)

- Unified Audit Log
- Entra sign-in logs
- Directory audit logs
- Teams / SharePoint / Exchange activity events

#### Other Future Sources

- Microsoft Defender
- Intune
- Viva Insights
- Power Platform
- Dynamics 365

## Fabric Data Architecture

### Bronze/Silver Layer (Raw and Normalized)

- Ingest raw data from Azure Automation to Azure Blob Storage.
- Store source data as-is, organized by source type.  Flatten the structure to avoid nested JSONs.
- Use Shortcut Transformations (initially announced in preview, now expanding in Fabric). It automatically turns the files referenced by a shortcut into managed Delta tables. See [Shortcut Transformations](https://learn.microsoft.com/en-us/fabric/onelake/shortcuts/transformations).

### Gold Layer (Business-Ready)

- KPIs and semantic datasets for decision-making.
- Example outputs: License Optimization, Governance Score, Adoption Score, Team Usage Trends.