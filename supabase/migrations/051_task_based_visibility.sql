-- ==============================================================================
-- 051: TASK-BASED VISIBILITY (tasks and attendance)
-- ==============================================================================
-- Audit (2026-11-17) found task and attendance reads were company-wide:
--   * tasks_select / tasks_update used auth_job_visible(), which is true for
--     every job of the caller's company, so every employee (Trainee upwards)
--     could read every task of their company through the API.
--   * attendance_punches_select / attendance_overrides_select allowed rank >= 50
--     (Senior Executive upwards) to read the whole company's punches, all dates.
--   * earned_leave_transactions_select was organization-wide (who worked which
--     Saturday / holiday) for everyone.
--   * tasks.assigned_by was whatever the client sent.
--
-- Rules after this migration (decided 2026-11-17):
--   "X works under A" (A = Assistant Manager or Manager, rank 60-89) when
--     A assigned at least one of X's current tasks (tasks.assigned_to = X,
--     tasks.assigned_by = A, status <> 'completed'), OR X.reports_to = A.
--     Derived live from tasks, so it follows every reassignment. One employee
--     can be under several managers at once. Job membership / job ownership
--     does NOT create the relationship.  -> auth_supervises(profile)
--   Tasks
--     Partner (90)            every task of the organization (unchanged).
--     Assistant Manager /     own tasks, tasks they assigned, and every task of
--     Manager (60-89)         an employee who works under them.
--     Everyone else           own tasks only (incl. Accounts, Senior Executive).
--   Attendance (punches, partner overrides)
--     Partner                 everything (unchanged).
--     Assistant Manager /     own, all dates; employees under them: TODAY only
--     Manager                 (org_today(), the organization's timezone).
--     Everyone else           own only.
--   Earned Leave credits      own, or Partner (salary / team EL are partner screens).
--   tasks.assigned_by         stamped from the signed-in user on insert and on
--                             reassignment; cannot be set to anyone else.
--
-- Not changed: timesheets (separate audit), leaves, jobs, clients, profiles,
-- claims / payments, approvals (reports_to), all write rules other than the
-- task row filter, partner-only functions, SECURITY DEFINER jobs and triggers.
--
-- Depends on 028, 030, 036, 038, 043, 050. Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/051_task_based_visibility.sql
-- ==============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regclass('public.attendance_overrides') IS NULL
     OR to_regprocedure('public.org_today(uuid)') IS NULL
     OR to_regprocedure('public.auth_rank()') IS NULL THEN
    RAISE EXCEPTION '051 requires 043 and 050 to be applied first.';
  END IF;
END $$;

-- 1. Reporting relationship --------------------------------------------------------
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_to_by ON tasks (assigned_to, assigned_by);
CREATE INDEX IF NOT EXISTS idx_tasks_assigned_by ON tasks (assigned_by);

-- True when the caller is an Assistant Manager / Manager (rank 60-89) and the
-- employee works under them. Partners do not need it (they see everything);
-- nobody "supervises" themselves.
CREATE OR REPLACE FUNCTION auth_supervises(p_profile UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT p_profile IS NOT NULL
     AND auth_profile_id() IS NOT NULL
     AND p_profile <> auth_profile_id()
     AND auth_rank() BETWEEN 60 AND 89
     AND EXISTS (
       SELECT 1 FROM profiles p
       WHERE p.id = p_profile AND p.organization_id = auth_org_id()
         AND (p.reports_to = auth_profile_id()
              OR EXISTS (SELECT 1 FROM tasks t
                         WHERE t.organization_id = p.organization_id
                           AND t.assigned_to = p.id
                           AND t.assigned_by = auth_profile_id()
                           AND t.status <> 'completed')));
$$;
COMMENT ON FUNCTION auth_supervises(UUID) IS
  'Caller (Assistant Manager / Manager) supervises the employee: assigned one of their current (not completed) tasks, or is their reports_to (051).';

-- A task row the caller may read / update.
CREATE OR REPLACE FUNCTION auth_task_visible(p_assigned_to UUID, p_assigned_by UUID)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT (p_assigned_to IS NOT NULL AND p_assigned_to = auth_profile_id())
      OR auth_rank() >= 90
      OR (auth_rank() BETWEEN 60 AND 89
          AND ((p_assigned_by IS NOT NULL AND p_assigned_by = auth_profile_id())
               OR auth_supervises(p_assigned_to)));
$$;

-- 2. Tasks RLS ---------------------------------------------------------------------
-- Partners keep auth_job_visible() (true for every job of the organization).
DROP POLICY IF EXISTS tasks_select ON tasks;
CREATE POLICY tasks_select ON tasks FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_task_visible(assigned_to, assigned_by));

-- Insert unchanged (rank >= 60 on a visible job); assigned_by is stamped below,
-- so INSERT ... RETURNING passes tasks_select.
DROP POLICY IF EXISTS tasks_insert ON tasks;
CREATE POLICY tasks_insert ON tasks FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_job_visible(job_id) AND auth_rank() >= 60);

DROP POLICY IF EXISTS tasks_update ON tasks;
CREATE POLICY tasks_update ON tasks FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_task_visible(assigned_to, assigned_by))
  WITH CHECK (organization_id = auth_org_id() AND auth_job_visible(job_id)
              AND auth_task_visible(assigned_to, assigned_by));

DROP POLICY IF EXISTS tasks_delete ON tasks;
CREATE POLICY tasks_delete ON tasks FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60
         AND auth_job_visible(job_id) AND auth_task_visible(assigned_to, assigned_by));

-- 3. assigned_by from the signed-in user -------------------------------------------------
-- API callers only (auth.uid() set). System jobs (recurring rollover, service
-- role, migrations) keep what they write. Named to run before the other BEFORE
-- triggers on tasks (alphabetical), so the guards see the stamped value.
CREATE OR REPLACE FUNCTION stamp_task_assigned_by()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF auth.uid() IS NULL THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'INSERT' THEN
    NEW.assigned_by := auth_profile_id();
  ELSIF NEW.assigned_to IS DISTINCT FROM OLD.assigned_to THEN
    NEW.assigned_by := auth_profile_id();      -- reassignment
  ELSE
    NEW.assigned_by := OLD.assigned_by;        -- cannot be changed on its own
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION stamp_task_assigned_by() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_00_tasks_stamp_assigned_by ON tasks;
CREATE TRIGGER trg_00_tasks_stamp_assigned_by
  BEFORE INSERT OR UPDATE ON tasks
  FOR EACH ROW EXECUTE FUNCTION stamp_task_assigned_by();

-- 4. Attendance RLS --------------------------------------------------------------------
DROP POLICY IF EXISTS attendance_punches_select ON attendance_punches;
CREATE POLICY attendance_punches_select ON attendance_punches FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR auth_rank() >= 90
    OR (punch_date = org_today(organization_id) AND auth_supervises(profile_id))));

DROP POLICY IF EXISTS attendance_overrides_select ON attendance_overrides;
CREATE POLICY attendance_overrides_select ON attendance_overrides FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR auth_rank() >= 90
    OR (override_date = org_today(organization_id) AND auth_supervises(profile_id))));

DROP POLICY IF EXISTS earned_leave_transactions_select ON earned_leave_transactions;
CREATE POLICY earned_leave_transactions_select ON earned_leave_transactions FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (profile_id = auth_profile_id() OR auth_rank() >= 90));

-- 5. Privileges ------------------------------------------------------------------------
-- Used inside policies, so signed-in users must be able to execute them; they
-- only answer questions about the caller's own access.
REVOKE ALL ON FUNCTION auth_supervises(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_supervises(UUID) TO authenticated;
REVOKE ALL ON FUNCTION auth_task_visible(UUID, UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION auth_task_visible(UUID, UUID) TO authenticated;

COMMIT;
