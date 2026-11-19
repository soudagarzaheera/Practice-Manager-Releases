# Database Schema Documentation: Task Manager & Practice Management

This document provides the architectural reference and schema specifications for the PostgreSQL database running on Supabase.

---

## 1. Entity-Relationship (ER) Diagram

```text
+-----------------------------------------------------------------------------------+
|                                  organizations                                    |
+-----------------------------------------------------------------------------------+
       |                  |                |               |              |
       | (1:N)            | (1:N)          | (1:N)         | (1:N)        | (1:N)
       v                  v                v               v              v
+--------------+   +-------------+   +-----------+   +------------+ +-------------+
|   profiles   |   |   clients   |   | locations |   |  holidays  | | audit_logs  |
+--------------+   +-------------+   +-----------+   +------------+ +-------------+
  |    |  |  ^        |  |  ^           |                 ^
  |    |  |  | (mgr)  |  |  | (rel_ptr) |                 |
  |    |  |  +--------+  |  +-----------+                 |
  |    |  |              |                                |
  |    |  | (1:N)        | (1:N)                          |
  |    |  +--------------+---------+                      |
  |    |                 |         |                      |
  |    |                 v         v                      |
  |    |           +----------+ +------------------------+|
  |    |           |   jobs   | |  statutory_compliances ||
  |    |           +----------+ +------------------------+|
  |    |             |  |  |  ^                           |
  |    |       +-----+  |  |  +---------------------------+
  |    |       | (1:N)  |  |
  |    |       v        |  +-----------------------+
  |    | +-----------+  | (1:N)                    |
  |    | |   tasks   |  |                          |
  |    | +-----------+  v                          v
  |    |   | (1:N) +--------------------+  +-----------------+
  |    +---+------>| timesheet_entries  |  | budget_requests |
  |        |       +--------------------+  +-----------------+
  |        |                 ^
  |        +-----------------+
  |
  | (1:N)
  +-------------------------------------------------------------+
  |                     |                    |                  |
  v                     v                    v                  v
+--------------------+ +------------------+ +---------------+ +--------------+
| attendance_punches | |  expense_claims  | |    leaves     | | review_notes |
+--------------------+ +------------------+ +---------------+ +--------------+
                                | (1:N)
                                v
                       +----------------------+
                       | expense_claim_lines  |
                       +----------------------+
```

---

## 2. Table Specifications

### 1. `organizations`
* **Purpose**: Root multi-tenant entity ensuring total logical isolation across firms.
* **Primary Key**: `id (UUID)`
* **Columns**:
  * `id UUID PRIMARY KEY DEFAULT gen_random_uuid()`
  * `name TEXT NOT NULL`
  * `code TEXT UNIQUE`
  * `created_at TIMESTAMPTZ NOT NULL DEFAULT now()`
  * `updated_at TIMESTAMPTZ NOT NULL DEFAULT now()`

---

### 2. `profiles`
* **Purpose**: Employee and partner profiles, hierarchy structure, cost and bill rates, active status.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `auth_user_id` &rarr; `auth.users(id) ON DELETE SET NULL`
  * `(organization_id, reports_to)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `UNIQUE (organization_id, employee_code) WHERE deleted_at IS NULL` (`uq_profiles_org_employee_code_live`, since `039`; was a full unique constraint)
  * `UNIQUE (organization_id, id)`
* **Deleted employees** *(`039_employee_soft_delete.sql`)*: `deleted_at`, `deleted_by`. Active = `is_active`; Inactive (reactivatable) = `NOT is_active AND deleted_at IS NULL`; Deleted = `deleted_at IS NOT NULL` (always inactive). Deleting is only through `delete_employee(profile)` (Partner, same org; blockers: active direct reports, open tasks, pending timesheet, last active partner, self). It keeps the row and all history, unlinks `auth_user_id`, deletes that `auth.users` row only if no profile still links to it, and writes `audit_logs`. A deleted employee's code and email can be reused. API users cannot change or reactivate a deleted profile (`trg_guard_profile_delete_state`), and a direct `DELETE` from the API becomes `delete_employee` (`trg_redirect_profile_delete`); service-role deletes are real deletes.
  * `role IN ('trainee', 'associate', 'senior_associate', 'senior_executive', 'assistant_manager', 'manager', 'partner', 'accounts', 'admin')` - `role` is the employee's **designation**; `accounts` / `admin` are legacy (see §18)
  * `cost_per_hour >= 0`, `bill_rate_per_hour >= 0`

---

### 3. `clients`
* **Purpose**: Client business entities, statutory identifiers (PAN, GSTIN), and relationship partners.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, relationship_partner_id)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `UNIQUE (organization_id, client_code)`
  * `UNIQUE (organization_id, id)`
  * `entity_type IN ('Individual','Proprietor','Partnership','LLP','Private Ltd','Public Ltd','Trust','HUF','Society')`

---

### 4. `locations`
* **Purpose**: Geofenced physical work sites (head office and client factory/branch premises).
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, client_id)` &rarr; `clients(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `UNIQUE (organization_id, id)`
  * `latitude BETWEEN -90 AND 90`, `longitude BETWEEN -180 AND 180`
  * `radius_meters BETWEEN 25 AND 5000`
* **Organization-wide** *(since `037_org_wide_sites.sql`)*: sites belong to the organization, not to a company. `company_id` is nullable and legacy (kept on pre-037 rows, NULL on new ones; not used for access). RLS: members see the organization's active sites; rank >= 60 also sees inactive sites and adds/edits/toggles them. Any active employee may punch at any active site of their own organization (`validate_attendance_site_punch`: own punch, active profile in the same org, active site in the same org, inside radius). The employee's company for attendance reporting still comes from `profiles.company_id`.

---

### 5. `jobs`
* **Purpose**: Engagements and job codes, budgeted hours, internal/statutory deadlines, confidential fee data, overhead flags.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, client_id)` &rarr; `clients(organization_id, id) ON DELETE RESTRICT`
  * `(organization_id, opened_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
  * `(organization_id, responsible_partner_id)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL (responsible_partner_id)` *(042)*
* **Responsible Partner** *(`042_job_responsible_partner.sql`)*: `responsible_partner_id` is the Partner responsible for this job code, separate from the client's owner `clients.relationship_partner_id` (never written by job changes). See §20.
* **Recurrence** *(`048_recurring_jobs.sql`)*: `frequency`, `period_start` / `period_end`, statutory and internal due-date rules, `previous_job_id`, `recurrence_stopped_at`. See §26.
* **Schedule** *(`054_job_schedules.sql`)*: `schedule_id` → `job_schedules`, `schedule_date` (the internal due date this job was raised for). Replaces the 048 rules, whose columns are kept as history only. See §27.
* **Constraints**:
  * ~~`UNIQUE (organization_id, job_code)`~~ replaced in `048`: one-time jobs `uq_jobs_org_code_one_time (organization_id, job_code) WHERE period_start IS NULL`; recurring jobs `uq_jobs_org_code_period (organization_id, upper(btrim(job_code)), period_start)`; `trg_jobs_recurrence` refuses a code shared by a one-time and a recurring job (23505)
  * `UNIQUE (organization_id, id)`
  * `status IN ('open', 'in_progress', 'under_review', 'closed')`
  * `budget_hours >= 0`, `fee_amount IS NULL OR fee_amount >= 0`

---

### 6. `job_assignments`
* **Purpose**: M:N team member assignments to job codes.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, job_id)` &rarr; `jobs(organization_id, id) ON DELETE CASCADE`
  * `(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE CASCADE`
* **Constraints**:
  * `UNIQUE (job_id, profile_id)`

---

### 7. `tasks`
* **Purpose**: Work items, checklists, and deliverables allocated under job codes.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, job_id)` &rarr; `jobs(organization_id, id) ON DELETE CASCADE`
  * `(organization_id, assigned_to)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `UNIQUE (organization_id, id)`
  * `status IN ('todo', 'in_progress', 'blocked_on_client', 'submitted_for_review', 'changes_requested', 'completed')`
  * `estimated_hours >= 0`

---

### 8. `timesheet_entries`
* **Purpose**: Granular daily time bookings, approval workflow, and query notes.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
  * `(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
  * `(organization_id, job_id)` &rarr; `jobs(organization_id, id) ON DELETE RESTRICT`
  * `(organization_id, task_id)` &rarr; `tasks(organization_id, id) ON DELETE SET NULL`
  * `(organization_id, approved_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
  * `(organization_id, decided_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL` *(added in `005_approval_history.sql`)*
* **Constraints**:
  * `day_index BETWEEN 0 AND 6`
  * `hours > 0 AND hours <= 24`
  * `status IN ('draft', 'pending', 'approved', 'queried')`
* **Task link** *(wired up in `040_timesheet_task_completion.sql`, which replaces `018`)*: `task_id` is optional and set from the Timesheet's "Task (Optional)" dropdown. A BEFORE trigger rejects a `task_id` whose task is not on the entry's `job_id`. When an entry moves to `approved`, an AFTER trigger sets only that task to `completed`, and only if the entry is the assignee's own, the task is `todo` or `in_progress`, the job is not closed, none of the assignee's entries on it is unapproved, and their approved hours reach `estimated_hours`. Undoing the approval reopens a task the trigger completed (`tasks.auto_completed_at`). Deleting a task nulls only `task_id` (`ON DELETE SET NULL (task_id)`).
* **Approval history columns** *(added in `005_approval_history.sql`)*: `decided_by UUID`, `decided_at TIMESTAMPTZ` - set by `decideLine()` alongside `status`, cleared by `undoLine()`. Mirrors `budget_requests.decided_by/decided_at` and `expense_claims.approved_by/approved_at`, which already existed and are reused as-is.

---

### 9. `nil_timesheets`
* **Purpose**: Explicit recording of weeks completely accounted for by leave or firm holidays without hours.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
* **Constraints**:
  * `UNIQUE (profile_id, week_start_date)`

---

### 10. `attendance_punches`
* **Purpose**: Immutable raw geolocation clock-in/out records and distance to recognized geofences.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
  * `(organization_id, location_id)` &rarr; `locations(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `punch_type IN ('in', 'out')`
* `accuracy_meters NUMERIC(8,2)` *(added in `006_punch_accuracy.sql`)*: `position.coords.accuracy` at punch time. `NULL` when no location fix was obtained at all. Used by `geofenceCheck()` in `index.html` to apply a bounded accuracy tolerance instead of a zero-tolerance `distance <= radius` comparison.
* **Other Place** *(added in `038_other_place_attendance.sql`)*: `location_type` (`'site'` | `'other'`, default `'site'`), `location_note` (optional description, <= 200), `resolved_address` (reverse-geocoded, <= 500), `company_id` (employee's company at punch time, server-set from `profiles.company_id`; FK `(organization_id, company_id)` &rarr; `companies`; pre-038 rows backfilled from the profile). An `'other'` punch has `location_id IS NULL`, `place_label = 'Other Place'`, no distance, `is_within_geofence = false` (not fence-checked), and requires GPS coordinates and accuracy. `trg_validate_attendance_site_punch` enforces: own punch, active employee of the org, valid coordinates, one `in` then one `out` per day; site punches additionally the active same-org site and its radius.
* **Access (RLS)**: read own punches, or rank >= 50 for people visible to them (`auth_profile_visible`); insert own only; no update/delete through the API.
* **Partner overrides** *(`050_attendance_overrides.sql`)*: punches are never changed by an override; see section 27.

---

### 11. `budget_requests`
* **Purpose**: Formal variance requests to increase a job's allotted budget hours.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `(organization_id, job_id)` &rarr; `jobs(organization_id, id) ON DELETE CASCADE`
  * `(organization_id, requested_by)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
  * `(organization_id, decided_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `to_hours > from_hours`, `from_hours >= 0`
  * `length(trim(reason)) >= 10`
  * `status IN ('pending', 'approved', 'rejected')`
* **Hard limit** *(from `023_job_budget_hard_limit.sql`)*: `trg_timesheet_job_budget_limit` (BEFORE INSERT / UPDATE OF hours, job_id on `timesheet_entries`) rejects an entry when the job's booked hours (all entries, any status) plus the new hours exceed `budget_hours` + approved additional hours. Overhead jobs are exempt; status-only updates never trip it.
* **Budget semantics** *(from `022_budget_hours_never_overwritten.sql`)*: `jobs.budget_hours` is the original Budgeted Hours, set when the job is raised and never changed by an approval. Each request records the hours available before (`from_hours`) and after (`to_hours`); the additional hours are `to_hours − from_hours`. Hours available = `budget_hours` + the sum over approved requests, exposed to every role via `job_approved_extra_hours()` (per-job aggregate only, caller's organization).

---

### 12. `expense_claims` & `expense_claim_lines`
* **Purpose**: Monthly employee reimbursement claim header and granular line items.
* **Primary Key**: `id (UUID)`
* **Foreign Keys**:
  * `expense_claims(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
  * `expense_claims(organization_id, approved_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
  * `expense_claims(organization_id, paid_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
  * `expense_claim_lines(claim_id)` &rarr; `expense_claims(id) ON DELETE CASCADE`
  * `expense_claim_lines(job_id)` &rarr; `jobs(id) ON DELETE RESTRICT`
* **Constraints**:
  * `UNIQUE (profile_id, claim_month)` on `expense_claims`
  * `status IN ('draft', 'submitted', 'approved', 'rejected', 'paid')`
  * `category IN ('conveyance', 'travel', 'lodging', 'meals', 'printing', 'courier', 'govt_fee', 'other')`
  * `amount > 0`

---

### 13. `leaves` & `holidays`
* **Purpose**: Employee leave tracking (one row per calendar day) and firm holiday calendar.
* **Foreign Keys**:
  * `leaves(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE RESTRICT`
  * `leaves(organization_id, approved_by)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`
* **Constraints**:
  * `UNIQUE (profile_id, leave_date)` on `leaves` - a profile can have at most one leave row per calendar date, across every request.
  * `duration_part IN ('full', 'half')`
  * `leave_type IN ('CL', 'EL', 'SL', 'ML', 'PL', 'LWP')`
  * `UNIQUE (organization_id, holiday_date)` on `holidays`
* **Leave Management module columns** *(added in `007_leave_management.sql`)*: `request_id UUID NOT NULL DEFAULT gen_random_uuid()` groups the day-rows of one multi-day application - a "leave request" is `WHERE request_id = X`, decided with one bulk `UPDATE` across its rows (the same pattern `timesheet_entries` already uses for a job code's rows within a week). `rejection_reason TEXT` holds the approver's reason, distinct from the requester's own `reason`.

### 13a. `leave_types` *(added in `007_leave_management.sql`)*
* **Purpose**: Per-organization configurable leave type catalogue - label, default annual allocation, paid/unpaid, active - so the frontend never hardcodes a leave type or its day count.
* **Foreign Keys**: `organization_id` &rarr; `organizations(id) ON DELETE CASCADE`
* **Constraints**: `UNIQUE (organization_id, code)`; `code IN ('CL','EL','SL','ML','PL','LWP')` - deliberately the same closed set as `leaves.leave_type`, not opened to arbitrary values (see the migration's header comment). Seeded with standard defaults for every existing organization; editable by a partner from the Leave screen. `019_combined_casual_sick_leave.sql` adds `CSL` ("Casual/Sick Leave", 12 days) to both CHECK constraints (`leave_types.code`, `leaves.leave_type`) and, for one organization, adds the CSL row and deactivates CL/SL (rows kept, not deleted). Historical `leaves` rows keep their CL/SL code; the client reads them as CSL while the organization has an active CSL type. `021_partner_defined_leave_codes.sql` replaces both fixed code lists: `leave_types.code` must match `^[A-Z][A-Z0-9]{1,9}$` (partners add their own types from the Leave policy card), and `leaves.leave_type` is a foreign key `(organization_id, leave_type) → leave_types(organization_id, code) ON DELETE RESTRICT`, with no default.

### 13b. `employee_leave_balances` *(added in `007_leave_management.sql`)*
* **Purpose**: Optional per-employee, per-year override of a leave type's allocated days (e.g. a mid-year joiner's pro-rated allowance). Sparse - an employee with no row here simply uses `leave_types.annual_days`. "Used" and "Pending" are never stored; both are always summed live from `leaves`.
* **Foreign Keys**:
  * `(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE CASCADE`
  * `(organization_id, leave_type_code)` &rarr; `leave_types(organization_id, code) ON DELETE CASCADE`
* **Constraints**: `UNIQUE (profile_id, leave_type_code, leave_year)`

---

### 14. `statutory_compliances`
* **Purpose**: Reserved for client-level statutory deadlines (e.g. GSTR-3B, Advance Tax, TDS). Empty: the app only reads it, and nothing writes to it or raises job codes from it. The Statutory calendar lists job codes from `jobs.statutory_due_date` and hand-added dates from `statutory_dates` (`completed_at` marks one done, `041`).
* **Foreign Keys**:
  * `(organization_id, client_id)` &rarr; `clients(organization_id, id) ON DELETE CASCADE`
  * `(organization_id, job_id)` &rarr; `jobs(organization_id, id) ON DELETE SET NULL`

---

### 15. `review_notes` & `audit_logs`
* **Purpose**: In-app feedback drawer notes and immutable audit trail records for compliance actions.
* **Foreign Keys**:
  * `review_notes(organization_id, profile_id)` &rarr; `profiles(organization_id, id) ON DELETE CASCADE`
  * `audit_logs(organization_id, actor_profile_id)` &rarr; `profiles(organization_id, id) ON DELETE SET NULL`

---

### 16. `notification_settings` & `email_notifications` *(added in `026_email_notifications.sql`)*
* **Purpose**: Application notification emails (task assigned, leave / budgeted-hours / timesheet requests and decisions, due-soon / due-today / overdue reminders, partner daily summary, job closed, employee invited / deactivated / reactivated), decided in the database and sent by the `send-notifications` Edge Function through Resend. The frontend only performs the business action; it never sends email.
* **`notification_settings`** (one optional row per organization; defaults apply when absent): `timezone` (default `Asia/Kolkata`, used for "today" / overdue / summary time), `reminder_time` (09:00), `daily_summary_time` (19:00), `due_soon_days` (2), `overdue_repeat_days` (3), `overdue_max_reminders` (10), `is_enabled`. Readable by the organization, writable by partners.
* **`email_notifications`**: one row per email message. `dedupe_key` is `UNIQUE`, so the same event can only be queued once (e.g. `task_assigned:<task>:<assignee>:<txid>`, `leave_approved:<request_id>`, `task_overdue:<task>:<assignee>:<due_date>:<bucket>`, `partner_daily_summary:<partner>:<local date>`). Recipients are stored as profile ids (`to_profile_ids`, `cc_profile_ids`) and resolved to addresses only at send time, within the row's organization. `status` ∈ `pending, processing, retry, sent, failed, skipped, expired, dry_run`; `attempts`, `next_attempt_at`, `expires_at`, `provider_message_id`, `error_message`, `sent_at` record delivery. No secrets are stored. RLS enabled with no client policies and no grants to `anon`/`authenticated` - service role only.
* **Triggers** (all AFTER, all wrapped in `EXCEPTION WHEN OTHERS` → `WARNING`, so an email problem never rolls back the business write): `trg_notif_task_assigned` (tasks, insert / `assigned_to` changed), `trg_notif_leaves_insert` / `trg_notif_leaves_update` (statement-level, grouped by `request_id`), `trg_notif_timesheets_update` (statement-level: owner draft/queried→pending = submitted; approver pending→approved/queried = decided), `trg_notif_budget_requests`, `trg_notif_job_closed` (only on the transition into `closed`), `trg_notif_employee_status` (`is_active` flipped). The acting user is never emailed about their own action.
* **Recipient rules** (To / CC split from `027_notification_cc_rules.sql`): task assigned → To assignee, CC the assigner (even though they acted), the assignee's supervisor, and the job opener when manager+ and in the same company; leave requested → To the direct supervisor (manager/senior/partner, else the company's partners), CC the partners of the **same `company_id`**; budget requested → To the supervisor when manager+ (else the company's partners), CC same-company partners (+ same-company manager+ job opener); timesheet submitted → To supervisor + same-company partners. CC never repeats a To address. Nothing crosses `organization_id`; partner fan-out never crosses `company_id`.
* **Schedules** (`pg_cron`): `notifications-dispatch` every minute → `notif_invoke_dispatcher()` → `pg_net` POST to `send-notifications` with the shared secret from Vault (`notifications_dispatch_url`, `notifications_dispatch_secret`); `notifications-scheduled` every 15 min → `enqueue_scheduled_notifications()` (idempotent); `notifications-purge` weekly (terminal rows older than 180 days).

---

### 17. Companies within an organization *(`028_multi_company.sql`)*
* **Model**: `organizations` (tenant) → many `companies` → employees (`profiles.company_id`, NOT NULL). One Supabase Auth account per person; no per-company login.
* **`companies`**: existing table (012), now partner-managed - `companies_insert` / `companies_update` require `auth_rank() >= 90`; no delete (deactivate instead). `UNIQUE (organization_id, lower(trim(name)))`. `trg_guard_company_deactivation` refuses to deactivate a company that still has active employees.
* **New `company_id` columns** (NOT NULL, composite FK `(organization_id, company_id) → companies`): `clients`, `jobs`, `employee_salary_history`. Backfilled from existing relationships (client → relationship partner's company; job → client's company; salary → employee's company). `trg_*_company` (`set_record_company()`) fills a missing value (job → its client's company, salary → the employee's company, otherwise the caller's company) and stops non-partners moving a record to another company. Every other company-specific table derives its company: tasks / timesheet entries / budget requests / job assignments → their job; statutory compliances → their client; leave / attendance / nil weeks / claims → the employee.
* **Salary history**: each row records the company paying that CTC from `effective_from`. A company move or CTC change adds a row from the chosen date; earlier rows are never overwritten.
* **Access (RLS)**: helpers `auth_company_id()`, `auth_all_companies()` (partner), `auth_company_ok(company)`, `auth_profile_visible(profile)`, `auth_job_visible(job)`, `auth_client_visible(client)`. Partners see every company of their organization. Everyone else sees their own company, plus: themselves, their supervisor, their direct reports, jobs they opened / are tasked on / booked time on / are assigned to, jobs their direct reports work on, and people who work on their company's jobs. Salary history stays partner-only.
* **App**: partners switch the company on screen from the header (`ACTIVE_COMPANY_ID`, remembered per user in localStorage); lists are scoped to it and the data is re-read from Supabase on every switch. Non-partners have no switcher.

---

### 18. Designations and job code access *(`030_employee_designations.sql`)*
* **Designation = `profiles.role`** (no separate role system). Ranks, mirrored by `auth_rank()` / `profile_rank()` and `RANK` in `index.html`: trainee 10 · associate 20 · senior_associate 30 · (legacy accounts 40) · senior_executive 50 · assistant_manager 60 · manager 70 · partner 90.
* **Migration of existing data**: `senior` → `assistant_manager`, `article` → `trainee`; everyone keeps the access they had (existing `>= 50 / >= 70 / >= 90` thresholds are unchanged).
* **Job codes and assigning work - Assistant Manager and above (`auth_rank() >= 60`)**: `jobs_insert` requires it; trigger `trg_tasks_assignment_rank` (`enforce_task_assignment_rank()`) rejects, for a signed-in user below it, inserting or deleting a task or changing its `assigned_to` / `assigned_by` / `job_id`. Service-role calls are exempt. Frontend: `CAN.createJob()` / `CAN.reassignTask()` (`ASSIGN_RANK`).
* **`partner_task_assignments()`** (Work screen "Assigned by" filter) counts tasks assigned or opened by a partner, manager or assistant manager.
* **Claim payment**: with `accounts` no longer assignable, Manager and above mark approved claims paid (never their own) - already permitted by `expense_claims_update`.

---

### 19. `job_services` *(added in `035_job_services.sql`)*
* **Purpose**: The Service list of the job code form - one list per organization, shared by its companies. `jobs.service_category` stores the service's `code` as text (no FK), and the suggested job code is built from it (`CLIENT/STATAUD/2026-27`).
* **Columns**: `code` (`^[A-Z][A-Z0-9]{1,9}$`), `name` (1–80), `is_active`, `sort_order`, `created_by`. Unique per organization: `code`, and `lower(btrim(name))`.
* **Seed**: the 14 services the app originally hardcoded (STATAUD, TAXAUD, INTAUD, GSTR1, GSTR3B, GSTR9, ITRNA, ITRAUD, TDSRET, AOC4, MGT7, ACCTG, CERT, ADV) - for existing organizations once, and for new ones by trigger `trg_seed_job_services`.
* **Access (RLS)**: read organization-wide; insert Assistant Manager and above (`auth_rank() >= 60`, same as `jobs_insert`). No UPDATE/DELETE privilege yet. Frontend: "+ Add Service" in the job code form, `CAN.createJob()`.

---

### 20. Responsible Partner per job code *(`042_job_responsible_partner.sql`)*
* **Model**: a client has one Relationship Partner (`clients.relationship_partner_id`, client ownership; may be any AM+). Each job has its own Responsible Partner (`jobs.responsible_partner_id`), which must be an active, not deleted `role = 'partner'` profile of the same organization - any company of it.
* **Default**: on insert with no value, the client's Relationship Partner if they are an active Partner, else `NULL` (the app then makes the user choose). Existing jobs were backfilled the same way.
* **Who may choose a non-default partner / change it** (`auth_can_set_job_partner(company)`, `CAN.setJobPartner()`): Partner on any job; Manager (rank 70) only on jobs of their own company (checked before and after the update). Assistant Managers and below keep the default - narrower than `jobs_update` (rank 60) on purpose. When the client has no Partner to default to, whoever may raise the job names one. Clearing it through the API is refused. Service-role calls are exempt.
* **Triggers on `jobs`**: `trg_jobs_responsible_partner` (BEFORE INSERT / UPDATE OF responsible_partner_id - default, validation, permission; runs after `trg_jobs_company`), `trg_jobs_responsible_partner_audit` (AFTER UPDATE - `audit_logs` row `job_responsible_partner_changed`), `trg_notif_job_partner_changed` (AFTER INSERT / UPDATE - e-mail).
* **`org_partners()`**: id, name, company, active of the organization's partners (active ones plus any still named on a job), callable by every member - `profiles` RLS hides other-company partners from non-partners.
* **E-mail**: `job_partner_changed` → To the new partner, CC the previous one (To the previous one when the new partner made the change). A new job e-mails its partner only when it is not the client's Relationship Partner. Job e-mails follow the current partner: `task_assigned` (CC), `budget_requested` (CC), `task_overdue` (CC), `job_closed` (own copy), and the partner daily summary includes jobs the partner is responsible for.
* **App**: New job form "Responsible Partner"; Edit job / job card "Change Responsible Partner" (current → choose → confirm); job card shows both partners; Job codes filter by responsible partner; Today card "Jobs you are responsible for" (partners); Assignment-wise and Task register reports carry the column; budget requests show it.

---

### 21. Holiday management *(`043_holiday_management.sql`)*
* **`holidays`** (001) gains `description` (optional, <= 500), `created_by`, `updated_by`, `updated_at`; `name` must be 1–100 characters. One holiday per date per organization (`uq_org_holiday_date`, unchanged). Holidays are organization-wide: every employee of every company sees them (`holidays_select`, 036) in My calendar.
* **Who writes**: Partners only (`holidays_write`, 036) - widened to Partners, Managers and Assistant Managers by 046.
* **Past dates locked** (`trg_guard_holiday_change`, API users only): a holiday dated today or earlier - "today" in the organization's notification timezone, `org_today(org)` - cannot be added, moved or deleted, and a holiday cannot be moved onto such a date; its name and description stay editable. Attendance status and earned leave for those days are already settled.
* **App**: "Holidays <year>" card on My calendar (Add / Edit / Delete for Partners; `CAN.manageHolidays()`); the day detail shows the description.

---

### 22. Managed designations *(`044_managed_designations.sql`)*
* **`designations`**: `name` (2–60, unique per organization ignoring case/spaces), `access_role` (one of trainee … partner - the permission level), `is_builtin`, `is_active`, `sort_order`, `created_by` / `updated_by`. The 7 built-in designations carry the existing names (Trainee … Partner) and are seeded for every organization (`trg_seed_designations` for new ones); they are read-only.
* **`profiles.designation_id`** → `designations(organization_id, id)` (NO ACTION). `profiles.role` remains the permission level used by `auth_rank()`, `profile_rank()` and every policy. `trg_profiles_designation_sync` keeps them in step: setting `designation_id` sets `role` to its `access_role` (designation must be active and in the same organization); setting only `role` (create-employee, older app) links the built-in designation of that role (none for legacy `accounts` / `admin`). Existing employees were linked to the built-in matching their role; no role changed.
* **Who manages the list** (`designations_*` RLS + `trg_guard_designation_change`): everyone in the organization reads; Partner / Manager / Assistant Manager (`auth_rank() >= 60`) add, rename, (de)activate and delete - a non-partner only designations below their own level (`auth_can_manage_designation`); never a built-in. `access_role` cannot change after creation. A designation used by any employee (deleted ones included) cannot be deleted - deactivate it. Assigning designations to employees stays Partner-only (`profiles_update`).
* **App**: Setup → Designations page (`CAN.manageDesignations()` / `CAN.editDesignation()`); the employee form lists active designations grouped by access level; new employees are created with the level's role, then the custom designation is set; Team, Profile and payslips show the designation name; hours-by-grade reports still group by access level; bulk employee import accepts designation names.

### 23. Optional Saturdays / holidays and timesheet minimum *(`045_optional_days_and_timesheet_minimum.sql`)*
* **Rule start** `optional_days_rule_from()` = 2026-11-01 (index.html `OPTIONAL_DAYS_FROM`). From then, every Saturday and every declared holiday is optional: not working is never an absence or deduction; working counts as Present. Sundays stay the weekly off. Earlier dates keep the old rules (2nd/4th Saturday holiday, extra day's pay for holiday work).
* **Earned Leave credit**: `trg_attendance_holiday_worked` (AFTER INSERT on `attendance_punches`) calls `credit_extra_work_day()` on a punch-out dated the org's today ±1 day; it credits 1 EL day when the date is a non-Sunday Saturday/holiday (`extra_work_day_reason()`) and the day has a punch-in and a punch-out (`attendance_day_complete()`). Timesheet entries no longer earn EL (017's `trg_timesheet_holiday_worked` dropped). No extra pay for these days from Nov 2026.
* **`earned_leave_transactions.reason`** (`saturday_worked` / `holiday_worked`, NOT NULL). The UNIQUE `(organization_id, profile_id, worked_date)` stops duplicate credits. Every credit/removal writes `audit_logs` (`earned_leave_credited` / `earned_leave_removed`). `holiday_worked_days()` now also returns `reason`, `credited_at`.
* **`timesheet_half_days`** `(organization_id, profile_id, work_date)` PK: the owner inserts/deletes their own; readable by the owner and anyone who can see that profile. `trg_guard_timesheet_half_day` freezes it once the date has pending/approved time.
* **`trg_timesheet_day_minimum`** (AFTER UPDATE OF status on `timesheet_entries`): when the owner submits (draft/queried → pending/approved) an entry dated from 2026-11-01, that day's total hours must be ≥ 8, or ≥ 4 when marked half day or on an approved half-day leave. Approver approve/query/undo is never checked.

---

### 24. Company holidays - managers & live updates *(`046_holiday_managers_realtime.sql`)*
* **`holidays_write`** now `auth_rank() >= 60` (Partner, Manager, Assistant Manager) within the organization; every other employee reads only (`holidays_select`, 036). Holidays stay organization-wide, not tied to the writer's company. The 043 past-date lock is unchanged for every writer.
* **Realtime**: `holidays` is in the `supabase_realtime` publication. The app (`startHolidaySync()`) re-reads the list on any change and when the tab becomes visible again, and the calendar labels the day "Holiday: <name>".

* **Holiday date changes** *(`049_holiday_date_change_reclassify.sql`)*: `trg_holiday_reclassify_attendance` (AFTER INSERT / UPDATE OF `holiday_date` / DELETE on `holidays`) calls `reconcile_extra_work_day_credits(org, date)` for the old and new date. From 2026-11-01 it removes `earned_leave_transactions` credits that no longer qualify, corrects `reason` / `holiday_id`, and credits complete, live-recorded days (punch-out within ±1 day of `punch_date`) up to the org's today. Each change is audited (`earned_leave_removed` / `earned_leave_reclassified` / `earned_leave_credited`). `attendance_punches` is never written. Applied once for Bhai Dooj moving 2026-11-11 → 2026-11-10; `seed_2026_holidays_for_org()` now seeds 10 Nov. The app re-reads `holiday_worked_days()` whenever the holiday list changes.

### 25. Custom client types *(`047_custom_client_types.sql`)*
* **`clients.entity_type`** is free text: `clients_entity_type_check` (001, nine fixed values) is replaced by `chk_clients_entity_type` - no leading/trailing spaces, 1–100 characters. Stored exactly as entered after trimming. NOT NULL and DEFAULT 'Private Ltd' unchanged; no existing row changed.
* **App / import**: the Add Client form takes any type with suggestions (`CLIENT_TYPE_SUGGESTIONS` + types already in use - suggestions only, never a restriction); the import template's Type dropdown also accepts typed values (Excel information-style validation); `import-clients` accepts any type up to 100 characters, blank = Private Ltd.
* **Relationship partner** (`clients.relationship_partner_id`, unchanged column/FK): the app and `import-clients` now accept any active employee of any designation (previously Assistant Manager and above). It grants no access; 042's job default still applies only when it is an active Partner.

### 26. Recurring job codes *(`048_recurring_jobs.sql`)*
* **`jobs.frequency`**: `one_time` (default - every pre-048 job) | `monthly` | `quarterly` | `half_yearly` | `yearly`.
* **Period**: `period_start` is always the 1st of a month; `period_end` = start + 1/3/6/12 calendar months − 1 day; `period_fy` is set to the period name (`Oct 2026`, `Q3 FY 2026-27`, `H1 FY 2026-27`, `FY 2026-27`; off-boundary periods `Feb 2026 – Apr 2026`). All NULL on one-time jobs.
* **Due-date rules** (recurring only): statutory = day `stat_due_day` of the month `stat_due_month_offset` months after the period's last month (both NULL = no statutory date). Internal = `internal_due_rule` `fixed` (`internal_due_day` + `internal_due_month_offset`, same meaning) or `statutory_offset` (`internal_due_offset_days`, negative = before). Calendar months, never a fixed day count; a day the month lacks becomes its last day (31st → 28/29 Feb). `trg_jobs_recurrence` (`guard_job_recurrence()`) derives `period_end`, `period_fy`, `statutory_due_date` and `internal_due_date` from the rules on insert and on any update of those columns; status-only updates do not fire it. Helpers: `job_frequency_months`, `job_period_end`, `job_rule_day`, `job_period_label` (mirrored in `index.html`: `periodEndOf`, `ruleDay`, `periodLabel`).
* **Rollover** - `roll_recurring_jobs(p_org)`, SECURITY DEFINER: the day after a period ends (org-local date, `notification_settings.timezone`), raises the next period's job with the same job code and details (client, company, title with the period name swapped, service, budget, fee, responsible partner - or the client default if they are no longer an active Partner - opener, rules, `job_assignments`) and closes the ended job with an automatic closing note (an already-closed job keeps its own). Catches up missed periods one at a time. Each job rolls once (`uq_jobs_previous_job`); a next period already raised by hand is linked instead of duplicated; reopening a closed period does not close it again. Skipped: `recurrence_stopped_at` set, client archived. Signed-in callers act on their own organization and run as the system (caller identity cleared for that transaction). Schedules: pg_cron `recurring-jobs-rollover` hourly at :10; the app also calls it on load.
* **App**: Job code form "Frequency", "Period starts", statutory/internal due rules with a three-period preview and an explanation; Period / FY and both due dates are calculated (read-only) for recurring jobs; "Last period - do not raise the next one" on edit. Job card shows frequency, period, both due dates and previous/next period. Pickers show `code · period` for recurring jobs.

### 27. Partner attendance overrides *(`050_attendance_overrides.sql`)*
* **`attendance_overrides`**: one row per employee per date (`UNIQUE (organization_id, profile_id, override_date)`). `status` `present` | `absent`; optional partner-entered `in_time` / `out_time` (Present only, out > in - never written as punches); `reason` (optional, <= 500); `day_type` (`working`, `weekly_off`, `holiday`, `saturday_holiday`, `optional_saturday`); `is_exceptional` (any non-working day); `batch_id`; `created_by` / `updated_by` / timestamps. FKs to `profiles` ON DELETE RESTRICT.
* **`attendance_override_history`**: append-only audit of every set / clear: employee, date, `original_status` → `new_status` (vocabulary: `present`, `incomplete`, `absent`, `not_marked`, `leave`, day types, `override_present`, `override_absent`), timings, reason, `operation_type` (`individual` = 1 employee × 1 date, else `bulk`), `batch_id`, `performed_by`, `performed_at`.
* **Write path**: only `apply_attendance_override(p_profile_ids, p_dates, p_action present|absent|clear, p_reason (optional), p_in_time, p_out_time, p_include_off_days, p_dry_run)`, SECURITY DEFINER. Rejects callers below Partner (`auth_rank() < 90`) and employees outside the caller's organization. One call = one transaction (any error writes nothing); max 366 dates / 10,000 records. Per day it takes the same advisory lock as the punch trigger. Skips (reported, never written): future dates (`org_today`), dates outside joining/exit or deleted employees, approved leave (full or half), and Sundays / holidays / Saturdays unless `p_include_off_days`. A blank time keeps the time already entered. `p_dry_run = true` returns the same per-record result without writing - the app's preview.
* **Earned Leave**: `attendance_day_complete()` now honours overrides (Present = complete, Absent = not); raw punch check is `attendance_punches_complete()`. `sync_override_el_credit()` adds / removes that day's `earned_leave_transactions` credit (new `source_type 'override'`), audited in `audit_logs`, for dates from 2026-11-01.
* **Access (RLS)**: overrides - read own, or rank >= 50 for visible people (as `attendance_punches`); history - Partners only. No insert/update/delete privilege for API users on either table.
* **App**: on the existing Attendance page, Partners get an "Override Attendance" button (Team today card) that opens a small dialog: selected employees (one or many) or All employees, a date or date range, Present / Absent, optional reason, Save → confirmation (the function's dry run) → Confirm. There is no separate page or navigation entry. Approved leave always wins over an override. Overrides show as dashed tags in monthly attendance, Team today and both attendance Excel reports (extra "Override" columns). Salary / payslips: a Present override counts the day as worked, Absent as not worked - loss of pay on a working day; on a holiday / optional day it only removes "worked", never deducts pay.

### 28. Balanced Leave (BL) *(`050_attendance_overrides.sql`, section 7)*
* **Leave type**: `leave_types` row `BL` "Balanced Leave" (paid, `annual_days` 0 - not used) seeded for every existing organization. Requests use the normal `leaves` rows / approval workflow / RLS / notifications. CL / SL / CSL / ML / PL / EL / LWP calculations are unchanged.
* **`balanced_leave_balances`**: PK `(organization_id, profile_id)`, `balance NUMERIC(6,1)` in steps of 0.5. Locked `FOR UPDATE` (`bl_lock_balance()`) for every change, so approvals, accrual and partner edits for one employee are serialised. Changed only by `bl_post()`.
* **`balanced_leave_months`**: one decision per employee per month (`UNIQUE (organization_id, profile_id, accrual_month)`, 1st of month): `credited`, `outcome` (`no_leave`, `leave_taken`, `inactive`, `not_employed`, `partner_credit`, `partner_removal`), `is_manual` (partner decision), `note`, `decided_by`, `decided_at`. The automatic process never changes an `is_manual` row.
* **`balanced_leave_transactions`**: append-only ledger - `txn_type` (`accrual`, `accrual_reversal`, `leave_deduction`, `leave_restore`, `manual_credit`, `manual_debit`, `manual_set`, `month_credit`, `month_removal`), signed `days`, `balance_before` / `balance_after` (CHECK after = before + days), `accrual_month`, `leave_id`, `reason` (required), `is_manual`, `performed_by` (required when manual), `created_at`.
* **Monthly accrual**: `run_balanced_leave_accrual(p_org)` (service role; pg_cron `balanced-leave-accrual` daily 00:20 UTC) settles every ended month from `bl_accrual_from()` (2026-11-01, org timezone) with no decision yet: 1 BL when the employee has no approved leave of any type that month (`bl_month_eligibility()`), else none. Pending leave in the month postpones the decision. Leave on optional Saturdays / holidays and old-rule 2nd/4th Saturdays is ignored (`bl_day_chargeable()`, same as the app's balance). Active, non-deleted, joined by the month's last day, not left before it ended; mid-month joiners are judged on the same rule, credits are whole days. Leave approved / cancelled later for a settled month re-settles it (`bl_settle_month()`: credit withdrawn / restored) unless a partner decided it. Daily runs + the UNIQUE month row make it idempotent.
* **Using BL** (triggers on `leaves`): `trg_leaves_bl_guard` (BEFORE) refuses a pending BL day above balance − other pending BL days; `trg_leaves_bl_sync` (AFTER) deducts on approval (refused if the balance is too low), returns the days if it is later rejected / cancelled, and re-checks the month's credit.
* **Partner override**: `adjust_balanced_leave(p_profile_id, p_action, p_reason, p_days, p_month)`, SECURITY DEFINER, Partner only (`auth_rank() >= 90`), reason required: `credit` / `debit` N days (debit cannot go below 0), `set` balance, `credit_month` (even if leave was taken), `remove_month` (removes or blocks that month's credit; may leave a negative balance if it was already used). Months up to the current one.
* **Access (RLS)**: all three tables - read own, your direct reports', or (Partners) anyone visible. No insert/update/delete privilege for API users.
* **App**: Leave page - BL row in "Leave balance" (Earned = credits this year, Remaining = stored balance), "Balanced Leave history" card, BL available shown in Apply for leave, and for Partners a "Team Balanced Leave" card with History and Adjust dialogs.

### 29. Task-based visibility *(`051_task_based_visibility.sql`)*
* **"Works under"** - `auth_supervises(profile)`: caller is an Assistant Manager / Manager (rank 60-89) and either assigned one of the employee's current tasks (`tasks.assigned_to` = employee, `tasks.assigned_by` = caller, `status <> 'completed'`) or is the employee's `reports_to`. Derived live from `tasks`, so it follows reassignment and completion; one employee can be under several managers. Job membership / job ownership do not count.
* **Tasks** (`tasks_select` / `tasks_update` / `tasks_delete` via `auth_task_visible(assigned_to, assigned_by)`): Partner - every task; Assistant Manager / Manager - own tasks, tasks they assigned, and every task of someone working under them; everyone else (Senior Executive, Accounts, Senior Associate, Associate, Trainee) - own tasks only. Insert unchanged (rank >= 60 on a visible job). Jobs, clients and profiles visibility are unchanged.
* **`assigned_by`**: `trg_00_tasks_stamp_assigned_by` (BEFORE INSERT/UPDATE, API callers only) sets it to the signed-in user on insert and whenever `assigned_to` changes, and keeps the old value otherwise. System jobs (no `auth.uid()`) keep what they write.
* **Attendance** (`attendance_punches_select`, `attendance_overrides_select`): own rows always; Partner everything; Assistant Manager / Manager only rows dated `org_today()` of people working under them; everyone else nothing else. **Earned Leave credits** (`earned_leave_transactions_select`): own, or Partner.
* **Not changed**: timesheets (separate audit), leaves, claims / payments, approvals (`reports_to`), Balanced Leave, partner-only functions.
* **App**: "Team today" (Attendance) for Assistant Manager and above only, listing Partners everyone and Assistant Managers / Managers only the people working under them (`supervisesProfile()`, mirrors `auth_supervises()`).

### 30. Payslip earnings & deductions *(`052_payslip_components.sql`)*
* **`employee_payslip_components`**: one row per employee per month (`salary_month` = first of the month, UNIQUE with `profile_id`). Earnings `basic`, `sa`, `la`, `ca`, `hra`; deductions `tds`, `pf`, `pt`, `other_deductions` + `other_deduction_remark`; optional `payment_date`. Each amount is NULL (blank) or >= 0; `other_deductions > 0` requires a non-blank remark (CHECK).
* **No payroll rules**: every amount is typed in by a Partner. The app only adds the earnings (Total Earnings), adds the deductions (Total Deductions) and subtracts (Net Salary).
* **Access (RLS)**: Partners read/write their organization's rows; everyone else reads only their own rows.
* **App**: Salary page - "Enter / Edit amounts" per employee (dialog with live totals; "Remove amounts" reverts). Payslip (screen and PDF) is black and white with Employee details, Earnings, Deductions (with the Other Deductions remark), Net Salary, amount in words and an attendance summary. A month with no row keeps the existing attendance-based payslip, so earlier payslips are unchanged. `salaryCalculation()` and the Salary table figures are not changed.

### 31. Clients shared across an organization's companies *(`053_org_shared_clients.sql`)*
* **Read**: `clients_select` = same organization (`auth_org_id()`, from the caller's own profile). Every company of an organization sees all its clients; other organizations see none. `auth_client_visible()` is organization-wide too (statutory compliances follow it).
* **Edit**: `clients_update` = same organization and rank >= 60, whichever company added the client. Moving a client's `company_id` stays Partner-only (`trg_clients_company`); archiving stays Partner-only. Insert (own company, rank >= 60) and delete (Partner) unchanged.
* **`clients.company_id`** is kept as "company that added the client"; no data changed.
* **Statutory dates**: a date keeps the company it is saved under; the client's company is only a default when none is given.
* **App**: statutory date client list shows all active clients; a new job code uses the client's company when the user may raise jobs there (Partners), otherwise the user's own company. Client import already checks duplicates organization-wide (`import-clients`).

## 3. Security, Multi-Tenancy & Delete Integrity Principles

1. **Multi-Tenant Composite Keys**:
   All inter-table relationships use composite foreign keys `(organization_id, foreign_id) REFERENCES parent(organization_id, id)`. This ensures that a child entity in Organization A can never be linked to a parent entity in Organization B at the database engine level.
2. **Safe Delete Rules**:
   - Critical historical records (`timesheet_entries`, `attendance_punches`, `expense_claims`, `leaves`) have `ON DELETE RESTRICT` on their profile and job foreign keys. Employees with recorded hours cannot be deleted; they must be deactivated.
   - Audit trail records in `audit_logs` set actor to `NULL` on profile removal, preserving the audit log permanently.
3. **Authentication Strategy**:
   - `auth_user_id` in `profiles` references `auth.users(id)` in Supabase, keeping authentication identity linked while allowing `contact_email` to remain purely organizational contact information.
4. **Row-Level Security (RLS)**:
   - `ALTER TABLE ... ENABLE ROW LEVEL SECURITY;` is active across all 18 tables.
   - Specific fine-grained access policies (e.g. isolating `fee_amount` to Partners, restricting timesheet edits to authors in `draft` status) are intentionally deferred to the authentication integration phase when `auth.uid()` and verified JWT claims are established.
   - `003_auth_integration.sql` established organization-scoped access for `authenticated`. `005_approval_history.sql` narrowed `budget_requests`, `expense_claims` and `expense_claim_lines` further: a *decided* (approved/rejected) row is readable only by its requester and by the roles authorized to decide that request type (`auth_rank() >= 70` for budget/claim decisions, plus `role = 'accounts'` for paid claims) - mirroring `CAN.approveBudget()` / `CAN.approveClaim()` / `CAN.payClaim()` in `index.html`. *Pending* rows are unaffected. `timesheet_entries` RLS is unchanged - it stays organization-wide because job-cost totals (visible to every role on the Job codes screen) are computed across every employee's entries by design.
   - `007_leave_management.sql` narrowed `leaves` the same way: a row is readable by its own profile always, by any senior-and-up when `status = 'approved'` (needed by the existing Team-today board), and in full (any status) by whoever is authorized to decide it - mirroring `CAN.approveSheet()` exactly, via the new `profile_rank(uuid)` helper (the same rank lookup as `auth_rank()`, for an arbitrary target profile rather than the caller). `leave_types` is organization-wide readable, partner-only writable. `employee_leave_balances` follows the same visibility rule as `leaves` and is partner-only writable.

### 27. Repeating job codes *(`054_job_schedules.sql`, replaces §26's rules)*
* **App**: the job code form keeps plain Statutory due / Internal due date pickers plus one **Repeat** dropdown (Does not repeat / Daily / Weekly / Monthly / Every 3 months / Every 6 months / Yearly) and **Ends** (Never / After N times / On a date), with a preview of the next due dates. The 048 frequency, period and due-date-rule UI is gone.
* **`job_schedules`**: `repeat`, `repeat_interval`, `repeat_start` (= the internal due date it counts from), `repeat_until` / `repeat_count` (one at most), `extra_dates`, `skipped_dates`, `statutory_offset_days` (statutory due = internal due + this). Monthly/yearly count from the start (no drift; 31st → last day of shorter months). RLS: org read; rank ≥ 60 write.
* **`jobs`**: `schedule_id`, `schedule_date`; unique `(organization_id, schedule_id, schedule_date)`; plain codes unique via `uq_jobs_org_code_plain`. `trg_jobs_schedule` (`guard_job_schedule()`) refuses a code shared by a plain job and a schedule, or two jobs of a schedule on one date. `trg_jobs_recurrence` (048) is dropped.
* **Generation** - `generate_scheduled_jobs(p_org)`, SECURITY DEFINER: for each schedule, once its latest job is closed or its date has passed, raises the job for the next date (same code, client, company, title, service, budget, fee, responsible partner or client default, opener, `job_assignments`; `previous_job_id` = the latest job; `period_fy` = the date, e.g. `20 Dec 2026`). Nothing is closed automatically. Catches up missed dates. pg_cron `scheduled-jobs-generate` hourly at :10 (048's `recurring-jobs-rollover` is unscheduled); the app calls it on load, after saving a repeating job and after closing one. `roll_recurring_jobs()` now just calls it (older app builds).
* **Existing 048 series** were converted: monthly repeat every 1/3/6/12 months from the first period's internal due date, statutory offset from the latest period, ending at the last period if "Last period" was ticked; every existing row attached with its own internal due date. No row's dates, status, tasks or time were changed.
