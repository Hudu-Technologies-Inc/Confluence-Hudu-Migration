# Copilot Instructions for Confluence-Hudu-Migration

## Project Overview
- **Purpose:** Migrate Confluence pages, attachments, and metadata to Hudu, preserving structure, links, and company attribution.
- **Primary Script:** `Confluence-Migration.ps1` orchestrates the migration, loading helpers from `helpers/`.
- **Helpers:**
  - `helpers/init.ps1`: Handles credential gathering, validation, and environment setup.
  - `helpers/confluence.ps1`: Functions for interacting with Confluence API (spaces, pages, attachments).
  - `helpers/general.ps1`: Utility functions (logging, error handling, path management).
  - `helpers/articles-anywhere.ps1`: HTML parsing, link/image normalization, and content rewriting.

## Key Workflows
- **Run via PowerShell 7.5+** (dot-source recommended):
  ```powershell
  . .\Confluence-Migration.ps1
  ```
- **Credentials:** Prompted interactively for Hudu and Confluence API keys, domains, and usernames. Validation is enforced (24-char Hudu, 192-char Confluence tokens).
- **Logging:**
  - Main log: `logs/ConfluenceTransfer.log`
  - Summary: `logs/job-summary.json` (migration stats, errors, warnings)
  - Errored items: `logs/errored/`
- **Temp Data:**
  - Before/after HTML and metadata: `tmp/`

## Migration Flow
1. **Source Selection:** User chooses Confluence spaces to migrate (single/all).
2. **Destination Selection:** User chooses Hudu destination (single company, global KB, or per-article).
3. **Stubbing:** Article stubs created in Hudu for mapping.
4. **Attachments:** All attachments <100MB uploaded and mapped.
5. **Content Rewrite:** HTML bodies updated for Hudu compatibility.
6. **Relinking:** Internal Confluence links are mapped to new Hudu articles using metadata and `tmp/`/`logs/` JSON files.

## Patterns & Conventions
- **Interactive Prompts:** All major choices (spaces, companies, per-article attribution) are interactive.
- **Error Handling:** Errors and warnings are logged and summarized; large/failed items are saved for review.
- **Data Structures:** Uses PowerShell custom objects and arrays for tracking migration state and results.
- **External Dependency:** Requires the HuduAPI PowerShell module (auto-loaded or installed from Gallery).
- **No Automated Tests:** Manual verification is expected post-migration.

## Examples
- To migrate all spaces to a single company:
  - Select "All Spaces" and "Single Company" when prompted.
- To debug a failed migration:
  - Check `logs/job-summary.json` and `logs/errored/` for details.
- To correlate HTML changes:
  - Compare before/after files in `tmp/`.

## Integration Points
- **Confluence API:** REST calls for spaces, pages, attachments.
- **Hudu API:** Article, attachment, and company management.
- **No direct database or non-API integrations.**

---
For new features, follow the interactive, logging, and error-handling patterns established in the main script and helpers. Reference the README for user-facing workflow details.
