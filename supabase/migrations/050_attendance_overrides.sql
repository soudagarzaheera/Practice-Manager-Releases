-- ==============================================================================
-- 050: PARTNER ATTENDANCE OVERRIDES
-- ==============================================================================
-- Inspected first (repo, 2026-11-17):
--   * attendance_punches is the raw punch log: insert-own only through the API
--     (036 B6 - no update/delete policy); trg_validate_attendance_site_punch
--     (038) allows one punch-in and one punch-out per employee per day.
--   * There is no stored "attendance status". Present / Absent / Holiday /
--     Leave is calculated in index.html (attendanceDayStatusOf(),
--     salaryCalculation()) from punches, holidays, Sundays, optional days (045)
--     and approved leaves.
--   * Earned Leave for a worked Saturday / holiday lives in
--     earned_leave_transactions, keyed on attendance_day_complete() (045, 049).
--
-- Design (additive - no existing row is changed or deleted):
--   attendance_overrides        one row per employee per date (UNIQUE), status
--                               'present' | 'absent', optional partner-entered
--                               in/out times (never written as punches),
--                               optional reason, day type, exceptional flag (holiday /
--                               weekly-off / optional day), who and when.
--   attendance_override_history append-only audit of every set / clear:
--                               original and new status, reason (optional), partner,
--                               timestamp, individual vs bulk, batch id.
--   apply_attendance_override() the ONLY write path. SECURITY DEFINER, partner
--                               only (auth_rank() >= 90), one transaction per
--                               call (any error rolls back every row), and a
--                               dry-run mode the app uses for its preview so
--                               the preview and the write use the same rules.
--
-- Rules enforced by the server:
--   * Partner only. Target employees must be in the caller's organization and
--     visible to them (auth_profile_visible - partners: every company).
--   * No future dates (organization's today, org_today()).
--   * Dates outside the employee's joining/exit dates, or deleted employees,
--     are skipped.
--   * Approved leave (full or half day) is never overridden - skipped.
--   * Sundays, holidays, old-rule 2nd/4th Saturdays and optional Saturdays are
--     skipped unless the partner explicitly includes them; such overrides are
--     stored with is_exceptional = true.
--   * Punch rows, times and GPS data are never inserted, changed or deleted.
--   * Duplicates are impossible: UNIQUE (organization_id, profile_id,
--     override_date) + INSERT ... ON CONFLICT DO UPDATE, under the same
--     per-employee-per-day advisory lock the punch trigger uses.
--   * attendance_day_complete() becomes override-aware (present -> complete,
--     absent -> not complete), and each changed day's Earned Leave credit is
--     brought in line (sync_override_el_credit), with audit_logs rows, for
--     dates from optional_days_rule_from() (2026-11-01), as in 045/049.
--
-- Read access: overrides - own rows, or rank >= 50 for people already visible
-- (same as attendance_punches_select, 038), so payslips, monthly attendance,
-- reports and Team today all show them. History - partners only.
-- No insert/update/delete privilege or policy for API users on either table.
--
-- Section 7 adds BALANCED LEAVE (BL): monthly accrual, deduction on approval,
-- partner overrides and a full ledger - see the header of section 7.
--
-- Depends on 007, 038, 043, 045, 049 (and 026 for pg_cron). Re-runnable. Apply with:
--   supabase db query --linked -f supabase/migrations/050_attendance_overrides.sql
-- ==============================================================================

BEGIN;

DO $$
BEGIN
  IF to_regprocedure('public.credit_extra_work_day(uuid,uuid,date,text,uuid)') IS NULL
     OR to_regprocedure('public.reconcile_extra_work_day_credits(uuid,date)') IS NULL
     OR to_regprocedure('public.org_today(uuid)') IS NULL THEN
    RAISE EXCEPTION '050 requires 043, 045 and 049 to be applied first.';
  END IF;
END $$;

-- 1. Tables ---------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS attendance_overrides (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  override_date   DATE NOT NULL,
  status          TEXT NOT NULL,
  in_time         TIME,
  out_time        TIME,
  reason          TEXT,
  day_type        TEXT NOT NULL,
  is_exceptional  BOOLEAN NOT NULL DEFAULT false,
  batch_id        UUID NOT NULL,
  created_by      UUID NOT NULL,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_by      UUID NOT NULL,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_attendance_override_day UNIQUE (organization_id, profile_id, override_date),
  CONSTRAINT chk_att_override_status CHECK (status IN ('present', 'absent')),
  CONSTRAINT chk_att_override_times CHECK (status = 'present' OR (in_time IS NULL AND out_time IS NULL)),
  CONSTRAINT chk_att_override_time_order CHECK (in_time IS NULL OR out_time IS NULL OR out_time > in_time),
  CONSTRAINT chk_att_override_reason CHECK (reason IS NULL OR char_length(reason) BETWEEN 1 AND 500),
  CONSTRAINT chk_att_override_day_type CHECK (day_type IN
    ('working', 'weekly_off', 'holiday', 'saturday_holiday', 'optional_saturday')),
  CONSTRAINT fk_att_override_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_att_override_created_by FOREIGN KEY (organization_id, created_by)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_att_override_updated_by FOREIGN KEY (organization_id, updated_by)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_att_override_org_date ON attendance_overrides (organization_id, override_date);
CREATE INDEX IF NOT EXISTS idx_att_override_profile_date ON attendance_overrides (profile_id, override_date);
COMMENT ON TABLE attendance_overrides IS
  'Partner override of one employee''s attendance status for one date (050). Punches are never changed; the app shows the override instead of the punch-derived status, unless approved leave exists. Written only by apply_attendance_override().';

CREATE TABLE IF NOT EXISTS attendance_override_history (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  override_date   DATE NOT NULL,
  action          TEXT NOT NULL CHECK (action IN ('set', 'clear')),
  original_status TEXT NOT NULL,
  new_status      TEXT NOT NULL,
  in_time         TIME,
  out_time        TIME,
  reason          TEXT,
  day_type        TEXT NOT NULL,
  is_exceptional  BOOLEAN NOT NULL DEFAULT false,
  operation_type  TEXT NOT NULL CHECK (operation_type IN ('individual', 'bulk')),
  batch_id        UUID NOT NULL,
  performed_by    UUID NOT NULL,
  performed_at    TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT fk_att_override_hist_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_att_override_hist_by FOREIGN KEY (organization_id, performed_by)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_att_override_hist_org_at ON attendance_override_history (organization_id, performed_at DESC);
CREATE INDEX IF NOT EXISTS idx_att_override_hist_profile ON attendance_override_history (profile_id, override_date);
CREATE INDEX IF NOT EXISTS idx_att_override_hist_batch ON attendance_override_history (batch_id);
COMMENT ON TABLE attendance_override_history IS
  'Append-only audit of every attendance override set or cleared (050). Partners read; nobody writes through the API.';

-- 2. Access ---------------------------------------------------------------------
ALTER TABLE attendance_overrides ENABLE ROW LEVEL SECURITY;
ALTER TABLE attendance_override_history ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS attendance_overrides_select ON attendance_overrides;
CREATE POLICY attendance_overrides_select ON attendance_overrides FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR (auth_rank() >= 50 AND auth_profile_visible(profile_id))));

DROP POLICY IF EXISTS attendance_override_history_select ON attendance_override_history;
CREATE POLICY attendance_override_history_select ON attendance_override_history FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 90);

REVOKE ALL ON attendance_overrides, attendance_override_history FROM PUBLIC, anon, authenticated;
GRANT SELECT ON attendance_overrides, attendance_override_history TO authenticated;

-- 3. Day classification and raw status ---------------------------------------------
-- Mirrors index.html: Sunday = weekly off; declared holiday; before
-- 2026-11-01 the 2nd/4th Saturday is a holiday; from then every Saturday is optional.
CREATE OR REPLACE FUNCTION attendance_day_type(p_org UUID, p_date DATE)
RETURNS TEXT
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE
    WHEN EXTRACT(ISODOW FROM p_date) = 7 THEN 'weekly_off'
    WHEN EXISTS (SELECT 1 FROM holidays h
                 WHERE h.organization_id = p_org AND h.holiday_date = p_date) THEN 'holiday'
    WHEN EXTRACT(ISODOW FROM p_date) = 6 AND p_date >= optional_days_rule_from() THEN 'optional_saturday'
    WHEN EXTRACT(ISODOW FROM p_date) = 6
         AND ((EXTRACT(DAY FROM p_date)::INT - 1) / 7 + 1) IN (2, 4) THEN 'saturday_holiday'
    ELSE 'working'
  END;
$$;

-- The 045 definition of a complete day, from punches alone.
CREATE OR REPLACE FUNCTION attendance_punches_complete(p_org UUID, p_profile UUID, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT EXISTS (SELECT 1 FROM attendance_punches a
                 WHERE a.organization_id = p_org AND a.profile_id = p_profile
                   AND a.punch_date = p_date AND a.punch_type = 'in')
     AND EXISTS (SELECT 1 FROM attendance_punches a
                 WHERE a.organization_id = p_org AND a.profile_id = p_profile
                   AND a.punch_date = p_date AND a.punch_type = 'out');
$$;

-- Override-aware: a partner's Present counts as a complete day, Absent as not.
-- Used by credit_extra_work_day / reconcile_extra_work_day_credits /
-- record_attendance_holiday_worked, so Earned Leave follows overrides.
CREATE OR REPLACE FUNCTION attendance_day_complete(p_org UUID, p_profile UUID, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT COALESCE(
    (SELECT o.status = 'present' FROM attendance_overrides o
     WHERE o.organization_id = p_org AND o.profile_id = p_profile AND o.override_date = p_date),
    attendance_punches_complete(p_org, p_profile, p_date));
$$;

-- Status of a day ignoring any override (the "existing status" in previews and history).
CREATE OR REPLACE FUNCTION attendance_base_status(p_org UUID, p_profile UUID, p_date DATE)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_type TEXT := attendance_day_type(p_org, p_date);
  v_in BOOLEAN;
  v_out BOOLEAN;
BEGIN
  IF EXISTS (SELECT 1 FROM leaves l
             WHERE l.organization_id = p_org AND l.profile_id = p_profile
               AND l.leave_date = p_date AND l.status = 'approved') THEN
    RETURN 'leave';
  END IF;
  v_in := EXISTS (SELECT 1 FROM attendance_punches a WHERE a.organization_id = p_org
                    AND a.profile_id = p_profile AND a.punch_date = p_date AND a.punch_type = 'in');
  v_out := EXISTS (SELECT 1 FROM attendance_punches a WHERE a.organization_id = p_org
                    AND a.profile_id = p_profile AND a.punch_date = p_date AND a.punch_type = 'out');
  IF v_in AND v_out THEN RETURN 'present'; END IF;
  IF v_in THEN RETURN 'incomplete'; END IF;
  IF v_type <> 'working' THEN RETURN v_type; END IF;
  IF p_date >= org_today(p_org) THEN RETURN 'not_marked'; END IF;
  RETURN 'absent';
END;
$$;

-- 4. Earned Leave follows overrides ------------------------------------------------
DO $$
DECLARE c RECORD;
BEGIN
  FOR c IN SELECT conname FROM pg_constraint
           WHERE conrelid = 'public.earned_leave_transactions'::regclass AND contype = 'c'
             AND pg_get_constraintdef(oid) ILIKE '%source_type%'
  LOOP
    EXECUTE format('ALTER TABLE earned_leave_transactions DROP CONSTRAINT %I', c.conname);
  END LOOP;
END $$;
ALTER TABLE earned_leave_transactions ADD CONSTRAINT chk_earned_leave_source_type
  CHECK (source_type IN ('timesheet', 'attendance', 'backfill', 'override'));

-- Bring ONE employee's credit for ONE date in line after an override changes.
CREATE OR REPLACE FUNCTION sync_override_el_credit(p_org UUID, p_profile UUID, p_date DATE)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reason  TEXT;
  v_ok      BOOLEAN;
  v_ov      attendance_overrides%ROWTYPE;
  v_has_ov  BOOLEAN;
  v_old     earned_leave_transactions%ROWTYPE;
  v_has_old BOOLEAN;
  v_tz      TEXT;
  v_holiday UUID;
  v_id      UUID;
  v_source  TEXT;
BEGIN
  IF p_date < optional_days_rule_from() OR p_date > org_today(p_org) THEN
    RETURN;   -- old-rule dates keep their payroll; future dates never credit
  END IF;
  v_reason := extra_work_day_reason(p_org, p_date);
  v_ok := v_reason IS NOT NULL AND attendance_day_complete(p_org, p_profile, p_date);

  SELECT * INTO v_old FROM earned_leave_transactions e
  WHERE e.organization_id = p_org AND e.profile_id = p_profile AND e.worked_date = p_date;
  v_has_old := FOUND;

  IF v_has_old AND NOT v_ok THEN
    DELETE FROM earned_leave_transactions WHERE id = v_old.id;
    INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values)
    VALUES (p_org, auth_profile_id(), 'earned_leave_removed', 'earned_leave_transactions', v_old.id::text,
            to_jsonb(v_old) || jsonb_build_object('note', '050: attendance override - day not worked'));
    RETURN;
  END IF;
  IF v_has_old OR NOT v_ok THEN
    RETURN;
  END IF;

  SELECT * INTO v_ov FROM attendance_overrides o
  WHERE o.organization_id = p_org AND o.profile_id = p_profile AND o.override_date = p_date;
  v_has_ov := FOUND;
  IF v_has_ov THEN
    v_source := 'override';
  ELSE
    -- No override: only a live-recorded punch-out earns (045 / 049 rule).
    v_tz := COALESCE((SELECT s.timezone FROM notification_settings s WHERE s.organization_id = p_org), 'Asia/Kolkata');
    IF NOT EXISTS (SELECT 1 FROM attendance_punches a
                   WHERE a.organization_id = p_org AND a.profile_id = p_profile
                     AND a.punch_date = p_date AND a.punch_type = 'out'
                     AND (a.created_at AT TIME ZONE v_tz)::date BETWEEN p_date - 1 AND p_date + 1) THEN
      RETURN;
    END IF;
    v_source := 'backfill';
  END IF;

  SELECT h.id INTO v_holiday FROM holidays h WHERE h.organization_id = p_org AND h.holiday_date = p_date;
  INSERT INTO earned_leave_transactions
    (organization_id, profile_id, worked_date, holiday_id, source_type, source_id, reason)
  VALUES (p_org, p_profile, p_date, v_holiday, v_source, CASE WHEN v_has_ov THEN v_ov.id END, v_reason)
  ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING
  RETURNING id INTO v_id;
  IF v_id IS NOT NULL THEN
    INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, new_values)
    VALUES (p_org, auth_profile_id(), 'earned_leave_credited', 'earned_leave_transactions', v_id::text,
            jsonb_build_object('profile_id', p_profile, 'worked_date', p_date, 'reason', v_reason,
                               'earned_days', 1, 'source_type', v_source,
                               'note', '050: attendance override'));
  END IF;
END;
$$;

-- 5. The write path ----------------------------------------------------------------
-- p_action: 'present' | 'absent' | 'clear' (remove the override, back to punches).
-- p_dry_run = true returns exactly what would happen and writes nothing.
-- Returns { dry_run, batch_id, operation_type, action, employees, dates,
--           affected_employees, created, updated, cleared, unchanged, skipped,
--           rows: [{ profile_id, date, day_type, exceptional, original_status,
--                    new_status, outcome, skip_reason }] }.
CREATE OR REPLACE FUNCTION apply_attendance_override(
  p_profile_ids      UUID[],
  p_dates            DATE[],
  p_action           TEXT,
  p_reason           TEXT DEFAULT NULL,
  p_in_time          TIME DEFAULT NULL,
  p_out_time         TIME DEFAULT NULL,
  p_include_off_days BOOLEAN DEFAULT false,
  p_dry_run          BOOLEAN DEFAULT true)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org       UUID := auth_org_id();
  v_me        UUID := auth_profile_id();
  v_reason    TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_today     DATE;
  v_profiles  UUID[];
  v_dates     DATE[];
  v_cells     INT;
  v_op        TEXT;
  v_batch     UUID := gen_random_uuid();
  v_pid       UUID;
  v_date      DATE;
  v_prof      RECORD;
  v_type      TEXT;
  v_exc       BOOLEAN;
  v_ex        attendance_overrides%ROWTYPE;
  v_has_ex    BOOLEAN;
  v_original  TEXT;
  v_new       TEXT;
  v_outcome   TEXT;
  v_skip      TEXT;
  v_touched   BOOLEAN;
  v_in        TIME;
  v_out       TIME;
  v_rows      JSONB[] := '{}';
  v_created   INT := 0;
  v_updated   INT := 0;
  v_cleared   INT := 0;
  v_unchanged INT := 0;
  v_skipped   INT := 0;
  v_affected  INT := 0;
BEGIN
  IF v_org IS NULL OR v_me IS NULL OR auth_rank() < 90 THEN
    RAISE EXCEPTION 'Only partners can override attendance.' USING ERRCODE = '42501';
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('present', 'absent', 'clear') THEN
    RAISE EXCEPTION 'Unknown attendance override action.' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'The reason can be at most 500 characters.' USING ERRCODE = '22023';
  END IF;
  IF p_action <> 'present' AND (p_in_time IS NOT NULL OR p_out_time IS NOT NULL) THEN
    RAISE EXCEPTION 'Timings can only be entered when marking Present.' USING ERRCODE = '22023';
  END IF;
  IF p_in_time IS NOT NULL AND p_out_time IS NOT NULL AND p_out_time <= p_in_time THEN
    RAISE EXCEPTION 'The out time must be after the in time.' USING ERRCODE = '22023';
  END IF;

  SELECT array_agg(DISTINCT x) INTO v_profiles FROM unnest(p_profile_ids) AS x WHERE x IS NOT NULL;
  SELECT array_agg(DISTINCT d ORDER BY d) INTO v_dates FROM unnest(p_dates) AS d WHERE d IS NOT NULL;
  IF v_profiles IS NULL OR v_dates IS NULL THEN
    RAISE EXCEPTION 'Select at least one employee and one date.' USING ERRCODE = '22023';
  END IF;
  v_cells := cardinality(v_profiles) * cardinality(v_dates);
  IF cardinality(v_dates) > 366 OR v_cells > 10000 THEN
    RAISE EXCEPTION 'Too many records in one operation (% employees x % dates). Split it into smaller batches.',
      cardinality(v_profiles), cardinality(v_dates) USING ERRCODE = '22023';
  END IF;
  v_op := CASE WHEN v_cells = 1 THEN 'individual' ELSE 'bulk' END;
  v_today := org_today(v_org);

  FOREACH v_pid IN ARRAY v_profiles LOOP
    SELECT p.id, p.joining_date, p.exit_date, p.deleted_at INTO v_prof
    FROM profiles p WHERE p.id = v_pid AND p.organization_id = v_org;
    IF NOT FOUND OR NOT auth_profile_visible(v_pid) THEN
      RAISE EXCEPTION 'Employee % is not in your organization.', v_pid USING ERRCODE = '42501';
    END IF;
    v_touched := false;

    FOREACH v_date IN ARRAY v_dates LOOP
      IF NOT p_dry_run THEN
        -- Same lock as trg_validate_attendance_site_punch: serialises with punches.
        PERFORM pg_advisory_xact_lock(hashtext('attendance:' || v_pid::text || ':' || v_date::text));
      END IF;
      v_type := attendance_day_type(v_org, v_date);
      v_exc := v_type <> 'working';
      SELECT * INTO v_ex FROM attendance_overrides o
      WHERE o.organization_id = v_org AND o.profile_id = v_pid AND o.override_date = v_date;
      v_has_ex := FOUND;
      v_original := CASE WHEN v_has_ex THEN 'override_' || v_ex.status
                         ELSE attendance_base_status(v_org, v_pid, v_date) END;

      v_skip := CASE
        WHEN v_date > v_today THEN 'future_date'
        WHEN v_prof.deleted_at IS NOT NULL
          OR (v_prof.joining_date IS NOT NULL AND v_date < v_prof.joining_date)
          OR (v_prof.exit_date IS NOT NULL AND v_date > v_prof.exit_date) THEN 'not_employed'
        WHEN p_action <> 'clear' AND EXISTS (
               SELECT 1 FROM leaves l WHERE l.organization_id = v_org AND l.profile_id = v_pid
                 AND l.leave_date = v_date AND l.status = 'approved') THEN 'approved_leave'
        WHEN p_action <> 'clear' AND v_exc AND NOT COALESCE(p_include_off_days, false) THEN 'off_day'
        ELSE NULL END;

      IF v_skip IS NOT NULL THEN
        v_outcome := 'skip'; v_new := v_original; v_skipped := v_skipped + 1;
      ELSIF p_action = 'clear' THEN
        IF v_has_ex THEN
          v_outcome := 'clear'; v_new := attendance_base_status(v_org, v_pid, v_date); v_cleared := v_cleared + 1;
        ELSE
          v_outcome := 'unchanged'; v_new := v_original; v_unchanged := v_unchanged + 1;
        END IF;
      ELSE
        v_new := 'override_' || p_action;
        -- Present: a blank time keeps the one already entered for that day.
        v_in := CASE WHEN p_action = 'present' THEN
                  COALESCE(p_in_time, CASE WHEN v_has_ex AND v_ex.status = 'present' THEN v_ex.in_time END) END;
        v_out := CASE WHEN p_action = 'present' THEN
                  COALESCE(p_out_time, CASE WHEN v_has_ex AND v_ex.status = 'present' THEN v_ex.out_time END) END;
        IF v_in IS NOT NULL AND v_out IS NOT NULL AND v_out <= v_in THEN
          RAISE EXCEPTION 'For % on %, the out time (%) would be before the in time (%) already entered. Enter both times.',
            (SELECT full_name FROM profiles WHERE id = v_pid), v_date, v_out, v_in USING ERRCODE = '22023';
        END IF;
        IF v_has_ex AND v_ex.status = p_action
           AND v_ex.in_time IS NOT DISTINCT FROM v_in AND v_ex.out_time IS NOT DISTINCT FROM v_out THEN
          v_outcome := 'unchanged'; v_unchanged := v_unchanged + 1;
        ELSIF v_has_ex THEN
          v_outcome := 'update'; v_updated := v_updated + 1;
        ELSE
          v_outcome := 'create'; v_created := v_created + 1;
        END IF;
      END IF;

      IF v_outcome IN ('create', 'update', 'clear') THEN
        v_touched := true;
        IF NOT p_dry_run THEN
          IF v_outcome = 'clear' THEN
            DELETE FROM attendance_overrides WHERE id = v_ex.id;
          ELSE
            INSERT INTO attendance_overrides
              (organization_id, profile_id, override_date, status, in_time, out_time, reason,
               day_type, is_exceptional, batch_id, created_by, updated_by)
            VALUES (v_org, v_pid, v_date, p_action, v_in, v_out, v_reason,
                    v_type, v_exc, v_batch, v_me, v_me)
            ON CONFLICT (organization_id, profile_id, override_date) DO UPDATE
              SET status = EXCLUDED.status, in_time = EXCLUDED.in_time, out_time = EXCLUDED.out_time,
                  reason = EXCLUDED.reason, day_type = EXCLUDED.day_type,
                  is_exceptional = EXCLUDED.is_exceptional, batch_id = EXCLUDED.batch_id,
                  updated_by = EXCLUDED.updated_by, updated_at = now();
          END IF;
          INSERT INTO attendance_override_history
            (organization_id, profile_id, override_date, action, original_status, new_status,
             in_time, out_time, reason, day_type, is_exceptional, operation_type, batch_id, performed_by)
          VALUES (v_org, v_pid, v_date, CASE WHEN v_outcome = 'clear' THEN 'clear' ELSE 'set' END,
                  v_original, v_new,
                  CASE WHEN v_outcome = 'clear' THEN NULL ELSE v_in END,
                  CASE WHEN v_outcome = 'clear' THEN NULL ELSE v_out END,
                  v_reason, v_type, v_exc, v_op, v_batch, v_me);
          PERFORM sync_override_el_credit(v_org, v_pid, v_date);
        END IF;
      END IF;

      v_rows := array_append(v_rows, jsonb_build_object(
        'profile_id', v_pid, 'date', v_date, 'day_type', v_type, 'exceptional', v_exc,
        'original_status', v_original, 'new_status', v_new, 'outcome', v_outcome, 'skip_reason', v_skip));
    END LOOP;

    IF v_touched THEN v_affected := v_affected + 1; END IF;
  END LOOP;

  RETURN jsonb_build_object(
    'dry_run', p_dry_run,
    'batch_id', CASE WHEN p_dry_run THEN NULL ELSE v_batch END,
    'operation_type', v_op, 'action', p_action,
    'employees', cardinality(v_profiles), 'dates', cardinality(v_dates),
    'affected_employees', v_affected,
    'created', v_created, 'updated', v_updated, 'cleared', v_cleared,
    'unchanged', v_unchanged, 'skipped', v_skipped,
    'rows', to_jsonb(v_rows));
END;
$$;

-- 6. Privileges ------------------------------------------------------------------------
REVOKE ALL ON FUNCTION attendance_day_type(UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION attendance_punches_complete(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION attendance_day_complete(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION attendance_base_status(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION sync_override_el_credit(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION apply_attendance_override(UUID[], DATE[], TEXT, TEXT, TIME, TIME, BOOLEAN, BOOLEAN)
  FROM PUBLIC, anon;
-- Callable by signed-in users; the function itself rejects anyone below Partner.
GRANT EXECUTE ON FUNCTION apply_attendance_override(UUID[], DATE[], TEXT, TEXT, TIME, TIME, BOOLEAN, BOOLEAN)
  TO authenticated;

-- ==============================================================================
-- 7. BALANCED LEAVE (BL)
-- ==============================================================================
-- A separate leave type with a stored, ledger-backed balance. CL / SL / CSL /
-- ML / PL / EL / LWP and their calculations are not touched: BL is a new
-- leave_types row plus its own three tables.
--
--   balanced_leave_balances      one row per employee: current BL balance. The
--                                row is locked (FOR UPDATE) for every change,
--                                so concurrent approvals / accrual / partner
--                                edits for one employee run one at a time.
--   balanced_leave_months        one row per employee per month once that month
--                                is decided: credited or not, why, and whether
--                                a partner decided it (is_manual). UNIQUE per
--                                employee-month, so a month is never credited
--                                twice; is_manual rows are never changed by
--                                the automatic process.
--   balanced_leave_transactions  append-only ledger: every credit / deduction
--                                with balance before and after, reason,
--                                automatic or manual, and who did it.
--
-- Monthly accrual (run_balanced_leave_accrual, pg_cron daily 00:20 UTC):
--   * For every month from bl_accrual_from() (2026-11-01) that has ended in the
--     organization's timezone, each employee without a decision for it is
--     settled: 1 BL if no approved leave of ANY type that month, else none.
--   * Only approved leave counts. Pending leave in the month postpones the
--     decision until it is approved / rejected / cancelled (daily retries).
--     Leave on optional Saturdays / holidays (from 2026-11-01) and old-rule
--     2nd/4th Saturdays is not counted, the same days the app's balance skips.
--   * Eligibility: an active, non-deleted employee who joined on or before
--     the month's last day and had not left before it ended. A mid-month joiner
--     is judged on the same rule over the days they were employed; credits
--     are always whole days (never pro-rated).
--   * If leave is approved (or cancelled) for an already-settled month later,
--     that month is re-settled automatically (credit withdrawn / restored),
--     unless a partner has decided that month.
--
-- Using BL: a leave row with leave_type 'BL'
--   * BEFORE insert/update to pending: balance minus other pending BL days
--     must cover it, or the request is refused.
--   * On approval the days are deducted; if it is later rejected / cancelled
--     they are returned. The approval is refused if the balance is too low.
--   * The existing approval workflow, RLS and notifications are unchanged.
--
-- Partner override: adjust_balanced_leave() - partner only (auth_rank() >= 90),
-- reason required: credit / debit N days, set balance, credit a month (even
-- if leave was taken), remove a month's credit. Month decisions it makes are
-- is_manual and the automatic process never changes them.
-- ==============================================================================

DO $$
BEGIN
  IF to_regclass('public.leave_types') IS NULL OR to_regclass('public.leaves') IS NULL THEN
    RAISE EXCEPTION 'Balanced Leave requires 007 (leave management) to be applied first.';
  END IF;
END $$;

CREATE OR REPLACE FUNCTION bl_accrual_from()
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$ SELECT DATE '2026-11-01' $$;

-- 7.1 Leave type -------------------------------------------------------------------
INSERT INTO leave_types (organization_id, code, label, annual_days, is_paid, is_active)
SELECT o.id, 'BL', 'Balanced Leave', 0, true, true FROM organizations o
ON CONFLICT (organization_id, code) DO NOTHING;

-- 7.2 Tables -------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS balanced_leave_balances (
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  balance         NUMERIC(6,1) NOT NULL DEFAULT 0,
  updated_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  PRIMARY KEY (organization_id, profile_id),
  CONSTRAINT chk_bl_balance_step CHECK (balance * 2 = trunc(balance * 2)),
  CONSTRAINT fk_bl_balance_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);
COMMENT ON TABLE balanced_leave_balances IS
  'Current Balanced Leave (BL) balance per employee (050). Changed only through bl_post(); every change has a balanced_leave_transactions row.';

CREATE TABLE IF NOT EXISTS balanced_leave_months (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  accrual_month   DATE NOT NULL,
  credited        BOOLEAN NOT NULL,
  outcome         TEXT NOT NULL,
  is_manual       BOOLEAN NOT NULL DEFAULT false,
  note            TEXT,
  decided_by      UUID,
  decided_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_bl_month UNIQUE (organization_id, profile_id, accrual_month),
  CONSTRAINT chk_bl_month_first CHECK (accrual_month = date_trunc('month', accrual_month)::date),
  CONSTRAINT chk_bl_month_outcome CHECK (outcome IN
    ('no_leave', 'leave_taken', 'inactive', 'not_employed', 'partner_credit', 'partner_removal')),
  CONSTRAINT chk_bl_month_manual CHECK (is_manual = (outcome IN ('partner_credit', 'partner_removal'))),
  CONSTRAINT fk_bl_month_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_bl_month_by FOREIGN KEY (organization_id, decided_by)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_bl_month_profile ON balanced_leave_months (profile_id, accrual_month);
COMMENT ON TABLE balanced_leave_months IS
  'Monthly Balanced Leave decision per employee (050). UNIQUE per month = no double credit. is_manual rows (partner decisions) are never changed by the automatic accrual.';

CREATE TABLE IF NOT EXISTS balanced_leave_transactions (
  id              UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  profile_id      UUID NOT NULL,
  txn_type        TEXT NOT NULL,
  days            NUMERIC(6,1) NOT NULL,
  balance_before  NUMERIC(6,1) NOT NULL,
  balance_after   NUMERIC(6,1) NOT NULL,
  accrual_month   DATE,
  leave_id        UUID REFERENCES leaves(id) ON DELETE SET NULL,
  reason          TEXT NOT NULL,
  is_manual       BOOLEAN NOT NULL,
  performed_by    UUID,
  created_at      TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT chk_bl_txn_type CHECK (txn_type IN
    ('accrual', 'accrual_reversal', 'leave_deduction', 'leave_restore',
     'manual_credit', 'manual_debit', 'manual_set', 'month_credit', 'month_removal')),
  CONSTRAINT chk_bl_txn_math CHECK (balance_after = balance_before + days),
  CONSTRAINT chk_bl_txn_reason CHECK (char_length(reason) BETWEEN 1 AND 500),
  CONSTRAINT chk_bl_txn_manual CHECK (is_manual = (txn_type IN
    ('manual_credit', 'manual_debit', 'manual_set', 'month_credit', 'month_removal'))),
  CONSTRAINT chk_bl_txn_manual_by CHECK (NOT is_manual OR performed_by IS NOT NULL),
  CONSTRAINT fk_bl_txn_profile FOREIGN KEY (organization_id, profile_id)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT,
  CONSTRAINT fk_bl_txn_by FOREIGN KEY (organization_id, performed_by)
    REFERENCES profiles(organization_id, id) ON DELETE RESTRICT
);
CREATE INDEX IF NOT EXISTS idx_bl_txn_profile_at ON balanced_leave_transactions (profile_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bl_txn_org_at ON balanced_leave_transactions (organization_id, created_at DESC);
CREATE INDEX IF NOT EXISTS idx_bl_txn_leave ON balanced_leave_transactions (leave_id) WHERE leave_id IS NOT NULL;
COMMENT ON TABLE balanced_leave_transactions IS
  'Append-only Balanced Leave ledger (050): every credit / deduction with balance before and after, reason, automatic or manual, and who performed it.';

-- 7.3 Access ---------------------------------------------------------------------------
-- Read: yourself, your direct manager (who approves your leave), and partners
-- for anyone they can see. Nobody writes through the API.
ALTER TABLE balanced_leave_balances ENABLE ROW LEVEL SECURITY;
ALTER TABLE balanced_leave_months ENABLE ROW LEVEL SECURITY;
ALTER TABLE balanced_leave_transactions ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS balanced_leave_balances_select ON balanced_leave_balances;
CREATE POLICY balanced_leave_balances_select ON balanced_leave_balances FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = balanced_leave_balances.profile_id
                 AND p.reports_to = auth_profile_id())
    OR (auth_rank() >= 90 AND auth_profile_visible(profile_id))));

DROP POLICY IF EXISTS balanced_leave_months_select ON balanced_leave_months;
CREATE POLICY balanced_leave_months_select ON balanced_leave_months FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = balanced_leave_months.profile_id
                 AND p.reports_to = auth_profile_id())
    OR (auth_rank() >= 90 AND auth_profile_visible(profile_id))));

DROP POLICY IF EXISTS balanced_leave_transactions_select ON balanced_leave_transactions;
CREATE POLICY balanced_leave_transactions_select ON balanced_leave_transactions FOR SELECT TO authenticated
  USING (organization_id = auth_org_id() AND (
    profile_id = auth_profile_id()
    OR EXISTS (SELECT 1 FROM profiles p WHERE p.id = balanced_leave_transactions.profile_id
                 AND p.reports_to = auth_profile_id())
    OR (auth_rank() >= 90 AND auth_profile_visible(profile_id))));

REVOKE ALL ON balanced_leave_balances, balanced_leave_months, balanced_leave_transactions
  FROM PUBLIC, anon, authenticated;
GRANT SELECT ON balanced_leave_balances, balanced_leave_months, balanced_leave_transactions TO authenticated;

-- 7.4 Helpers ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION bl_leave_days(p_part TEXT)
RETURNS NUMERIC LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_part = 'half' THEN 0.5 ELSE 1 END::NUMERIC;
$$;

-- Same days the app's leave balance skips (isSaturdayHoliday / isOptionalWorkDay).
CREATE OR REPLACE FUNCTION bl_day_chargeable(p_org UUID, p_date DATE)
RETURNS BOOLEAN
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public AS $$
  SELECT CASE attendance_day_type(p_org, p_date)
    WHEN 'saturday_holiday'  THEN false
    WHEN 'optional_saturday' THEN false
    WHEN 'holiday'           THEN p_date < optional_days_rule_from()
    ELSE true END;
$$;

-- Creates the balance row if missing and locks it; returns the balance.
CREATE OR REPLACE FUNCTION bl_lock_balance(p_org UUID, p_profile UUID)
RETURNS NUMERIC
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE v NUMERIC;
BEGIN
  INSERT INTO balanced_leave_balances (organization_id, profile_id)
  VALUES (p_org, p_profile) ON CONFLICT DO NOTHING;
  SELECT b.balance INTO v FROM balanced_leave_balances b
  WHERE b.organization_id = p_org AND b.profile_id = p_profile
  FOR UPDATE;
  RETURN v;
END;
$$;

-- The ONLY place a balance changes. p_set_to (when not NULL) sets an absolute
-- balance; otherwise p_days is added (signed). A decrease that would take the
-- balance below zero is refused unless p_allow_negative. Automatic zero
-- changes are not logged; manual ones always are (audit of every override).
CREATE OR REPLACE FUNCTION bl_post(
  p_org UUID, p_profile UUID, p_type TEXT, p_days NUMERIC, p_set_to NUMERIC,
  p_reason TEXT, p_month DATE, p_leave UUID, p_allow_negative BOOLEAN)
RETURNS UUID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_before NUMERIC;
  v_delta  NUMERIC;
  v_manual BOOLEAN := p_type IN ('manual_credit', 'manual_debit', 'manual_set', 'month_credit', 'month_removal');
  v_id     UUID;
BEGIN
  v_before := bl_lock_balance(p_org, p_profile);
  v_delta := CASE WHEN p_set_to IS NOT NULL THEN p_set_to - v_before ELSE COALESCE(p_days, 0) END;
  IF v_delta = 0 AND NOT v_manual THEN
    RETURN NULL;
  END IF;
  IF v_delta < 0 AND v_before + v_delta < 0 AND NOT p_allow_negative THEN
    RAISE EXCEPTION 'Not enough Balanced Leave: % day(s) available, % needed.', v_before, -v_delta
      USING ERRCODE = 'P0001';
  END IF;
  UPDATE balanced_leave_balances SET balance = v_before + v_delta, updated_at = now()
  WHERE organization_id = p_org AND profile_id = p_profile;
  INSERT INTO balanced_leave_transactions
    (organization_id, profile_id, txn_type, days, balance_before, balance_after,
     accrual_month, leave_id, reason, is_manual, performed_by)
  VALUES (p_org, p_profile, p_type, v_delta, v_before, v_before + v_delta,
          p_month, p_leave, left(p_reason, 500), v_manual, auth_profile_id())
  RETURNING id INTO v_id;
  RETURN v_id;
END;
$$;

-- Monthly eligibility. Returns 'no_leave' | 'leave_taken' | 'inactive' |
-- 'not_employed' | 'pending' (decide later) | NULL (not employed that month).
CREATE OR REPLACE FUNCTION bl_month_eligibility(p_org UUID, p_profile UUID, p_month DATE)
RETURNS TEXT
LANGUAGE plpgsql STABLE SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_end  DATE := (p_month + INTERVAL '1 month' - INTERVAL '1 day')::date;
  v_from DATE;
  v_p    RECORD;
BEGIN
  SELECT p.joining_date, p.exit_date, p.deleted_at, p.is_active INTO v_p
  FROM profiles p WHERE p.id = p_profile AND p.organization_id = p_org;
  IF NOT FOUND OR v_p.deleted_at IS NOT NULL THEN RETURN NULL; END IF;
  IF v_p.joining_date IS NOT NULL AND v_p.joining_date > v_end THEN RETURN NULL; END IF;
  IF v_p.exit_date IS NOT NULL AND v_p.exit_date < p_month THEN RETURN NULL; END IF;
  IF v_p.exit_date IS NOT NULL AND v_p.exit_date < v_end THEN RETURN 'not_employed'; END IF;
  IF NOT v_p.is_active THEN RETURN 'inactive'; END IF;
  v_from := GREATEST(p_month, COALESCE(v_p.joining_date, p_month));
  IF EXISTS (SELECT 1 FROM leaves l
             WHERE l.organization_id = p_org AND l.profile_id = p_profile
               AND l.leave_date BETWEEN v_from AND v_end AND l.status = 'approved'
               AND bl_day_chargeable(p_org, l.leave_date)) THEN
    RETURN 'leave_taken';
  END IF;
  IF EXISTS (SELECT 1 FROM leaves l
             WHERE l.organization_id = p_org AND l.profile_id = p_profile
               AND l.leave_date BETWEEN v_from AND v_end AND l.status = 'pending'
               AND bl_day_chargeable(p_org, l.leave_date)) THEN
    RETURN 'pending';
  END IF;
  RETURN 'no_leave';
END;
$$;

-- Automatic decision for one employee-month. No-op for months not yet ended,
-- before bl_accrual_from(), or decided by a partner. Idempotent: the balance
-- lock serialises it per employee and the month row records the result.
CREATE OR REPLACE FUNCTION bl_settle_month(p_org UUID, p_profile UUID, p_month DATE)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_month  DATE := date_trunc('month', p_month)::date;
  v_m      balanced_leave_months%ROWTYPE;
  v_has    BOOLEAN;
  v_out    TEXT;
  v_credit BOOLEAN;
  v_label  TEXT;
BEGIN
  IF v_month < bl_accrual_from() OR (v_month + INTERVAL '1 month')::date > org_today(p_org) THEN
    RETURN;
  END IF;
  PERFORM bl_lock_balance(p_org, p_profile);
  SELECT * INTO v_m FROM balanced_leave_months m
  WHERE m.organization_id = p_org AND m.profile_id = p_profile AND m.accrual_month = v_month;
  v_has := FOUND;
  IF v_has AND v_m.is_manual THEN
    RETURN;   -- a partner's decision always wins
  END IF;

  v_out := bl_month_eligibility(p_org, p_profile, v_month);
  IF v_out IS NULL OR v_out = 'pending' THEN
    RETURN;
  END IF;
  v_credit := v_out = 'no_leave';
  IF v_has AND v_m.credited = v_credit AND v_m.outcome = v_out THEN
    RETURN;
  END IF;

  v_label := to_char(v_month, 'FMMonth YYYY');
  IF v_credit AND NOT (v_has AND v_m.credited) THEN
    PERFORM bl_post(p_org, p_profile, 'accrual', 1, NULL,
      'Monthly Balanced Leave for ' || v_label || ' (no leave taken)', v_month, NULL, false);
  ELSIF NOT v_credit AND v_has AND v_m.credited THEN
    PERFORM bl_post(p_org, p_profile, 'accrual_reversal', -1, NULL,
      'Monthly Balanced Leave for ' || v_label || ' withdrawn (leave approved for that month)',
      v_month, NULL, true);
  END IF;

  INSERT INTO balanced_leave_months (organization_id, profile_id, accrual_month, credited, outcome, is_manual)
  VALUES (p_org, p_profile, v_month, v_credit, v_out, false)
  ON CONFLICT (organization_id, profile_id, accrual_month) DO UPDATE
    SET credited = EXCLUDED.credited, outcome = EXCLUDED.outcome,
        decided_by = NULL, decided_at = now(), note = NULL
    WHERE NOT balanced_leave_months.is_manual;
END;
$$;

-- 7.5 Monthly accrual (scheduled) -----------------------------------------------------------
-- Settles every ended month (from bl_accrual_from()) that has no decision yet.
-- Runs daily so a missed run, or a month waiting on pending leave, is picked
-- up the next day. One employee-month failing never stops the others.
CREATE OR REPLACE FUNCTION run_balanced_leave_accrual(p_org UUID DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_o      RECORD;
  v_p      RECORD;
  v_month  DATE;
  v_last   DATE;
  v_seen   INT := 0;
  v_errors INT := 0;
BEGIN
  FOR v_o IN SELECT o.id FROM organizations o WHERE p_org IS NULL OR o.id = p_org LOOP
    -- One run per organization at a time; a concurrent run just skips it.
    IF NOT pg_try_advisory_xact_lock(hashtext('balanced_leave_accrual:' || v_o.id::text)) THEN
      CONTINUE;
    END IF;
    v_last := (date_trunc('month', org_today(v_o.id)) - INTERVAL '1 month')::date;
    v_month := bl_accrual_from();
    WHILE v_month <= v_last LOOP
      FOR v_p IN
        SELECT p.id FROM profiles p
        WHERE p.organization_id = v_o.id AND p.deleted_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM balanced_leave_months m
                          WHERE m.organization_id = v_o.id AND m.profile_id = p.id
                            AND m.accrual_month = v_month)
      LOOP
        BEGIN
          PERFORM bl_settle_month(v_o.id, v_p.id, v_month);
          v_seen := v_seen + 1;
        EXCEPTION WHEN OTHERS THEN
          v_errors := v_errors + 1;
          RAISE WARNING 'Balanced Leave accrual failed for profile % month %: %', v_p.id, v_month, SQLERRM;
        END;
      END LOOP;
      v_month := (v_month + INTERVAL '1 month')::date;
    END LOOP;
  END LOOP;
  RETURN jsonb_build_object('checked', v_seen, 'errors', v_errors);
END;
$$;

-- 7.6 Leave requests: balance check, deduction, month re-check --------------------------
CREATE OR REPLACE FUNCTION bl_guard_leave_request()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_bal     NUMERIC;
  v_pending NUMERIC;
  v_need    NUMERIC;
BEGIN
  IF NEW.leave_type IS DISTINCT FROM 'BL' OR NEW.status <> 'pending' THEN
    RETURN NEW;
  END IF;
  IF TG_OP = 'UPDATE' AND OLD.leave_type = 'BL' AND OLD.status = 'pending'
     AND OLD.duration_part IS NOT DISTINCT FROM NEW.duration_part
     AND OLD.leave_date = NEW.leave_date THEN
    RETURN NEW;
  END IF;
  IF NOT bl_day_chargeable(NEW.organization_id, NEW.leave_date) THEN
    RETURN NEW;
  END IF;
  v_bal := bl_lock_balance(NEW.organization_id, NEW.profile_id);
  -- Earlier rows of the same multi-day INSERT are visible here, so a request
  -- is checked as a whole.
  SELECT COALESCE(sum(bl_leave_days(l.duration_part)), 0) INTO v_pending
  FROM leaves l
  WHERE l.organization_id = NEW.organization_id AND l.profile_id = NEW.profile_id
    AND l.leave_type = 'BL' AND l.status = 'pending' AND l.id <> NEW.id
    AND bl_day_chargeable(l.organization_id, l.leave_date);
  v_need := bl_leave_days(NEW.duration_part);
  IF v_need > v_bal - v_pending THEN
    RAISE EXCEPTION 'Not enough Balanced Leave: % day(s) available (balance %, already requested %).',
      GREATEST(v_bal - v_pending, 0), v_bal, v_pending USING ERRCODE = 'P0001';
  END IF;
  RETURN NEW;
END;
$$;

CREATE OR REPLACE FUNCTION bl_sync_leave()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_want NUMERIC;
  v_have NUMERIC;
  v_diff NUMERIC;
  v_what TEXT;
BEGIN
  IF TG_OP = 'UPDATE'
     AND OLD.leave_type IS NOT DISTINCT FROM NEW.leave_type
     AND OLD.status IS NOT DISTINCT FROM NEW.status
     AND OLD.duration_part IS NOT DISTINCT FROM NEW.duration_part
     AND OLD.leave_date = NEW.leave_date THEN
    RETURN NULL;
  END IF;

  -- 1. BL deduction: the ledger total for this leave row must equal what it
  --    should cost now (approved BL on a chargeable day, else nothing).
  IF NEW.leave_type = 'BL' OR (TG_OP = 'UPDATE' AND OLD.leave_type = 'BL') THEN
    v_want := CASE WHEN NEW.leave_type = 'BL' AND NEW.status = 'approved'
                        AND bl_day_chargeable(NEW.organization_id, NEW.leave_date)
                   THEN -bl_leave_days(NEW.duration_part) ELSE 0 END;
    PERFORM bl_lock_balance(NEW.organization_id, NEW.profile_id);
    SELECT COALESCE(sum(t.days), 0) INTO v_have FROM balanced_leave_transactions t
    WHERE t.leave_id = NEW.id AND t.txn_type IN ('leave_deduction', 'leave_restore');
    v_diff := v_want - v_have;
    v_what := to_char(NEW.leave_date, 'DD Mon YYYY')
              || CASE WHEN NEW.duration_part = 'half' THEN ' (half day)' ELSE '' END;
    IF v_diff < 0 THEN
      PERFORM bl_post(NEW.organization_id, NEW.profile_id, 'leave_deduction', v_diff, NULL,
        'Balanced Leave taken on ' || v_what, date_trunc('month', NEW.leave_date)::date, NEW.id, false);
    ELSIF v_diff > 0 THEN
      PERFORM bl_post(NEW.organization_id, NEW.profile_id, 'leave_restore', v_diff, NULL,
        'Balanced Leave on ' || v_what || ' returned (' || NEW.status || ')',
        date_trunc('month', NEW.leave_date)::date, NEW.id, true);
    END IF;
  END IF;

  -- 2. Any leave approved / withdrawn after a month was settled re-checks it.
  PERFORM bl_settle_month(NEW.organization_id, NEW.profile_id, NEW.leave_date);
  IF TG_OP = 'UPDATE' AND date_trunc('month', OLD.leave_date) <> date_trunc('month', NEW.leave_date) THEN
    PERFORM bl_settle_month(OLD.organization_id, OLD.profile_id, OLD.leave_date);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_leaves_bl_guard ON leaves;
CREATE TRIGGER trg_leaves_bl_guard
  BEFORE INSERT OR UPDATE OF status, leave_type, duration_part, leave_date ON leaves
  FOR EACH ROW EXECUTE FUNCTION bl_guard_leave_request();

DROP TRIGGER IF EXISTS trg_leaves_bl_sync ON leaves;
CREATE TRIGGER trg_leaves_bl_sync
  AFTER INSERT OR UPDATE OF status, leave_type, duration_part, leave_date ON leaves
  FOR EACH ROW EXECUTE FUNCTION bl_sync_leave();

-- 7.7 Partner override ----------------------------------------------------------------------
-- p_action: 'credit' | 'debit' (p_days > 0, steps of 0.5)
--           'set'           (p_days = new balance, >= 0)
--           'credit_month'  (p_month: credit 1 BL for that month, even if leave was taken)
--           'remove_month'  (p_month: remove / block that month's credit)
-- Reason is required. Returns { profile_id, action, balance_before, balance }.
CREATE OR REPLACE FUNCTION adjust_balanced_leave(
  p_profile_id UUID,
  p_action     TEXT,
  p_reason     TEXT,
  p_days       NUMERIC DEFAULT NULL,
  p_month      DATE DEFAULT NULL)
RETURNS JSONB
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org    UUID := auth_org_id();
  v_me     UUID := auth_profile_id();
  v_reason TEXT := NULLIF(btrim(COALESCE(p_reason, '')), '');
  v_month  DATE;
  v_before NUMERIC;
  v_after  NUMERIC;
  v_m      balanced_leave_months%ROWTYPE;
  v_has    BOOLEAN;
BEGIN
  IF v_org IS NULL OR v_me IS NULL OR auth_rank() < 90 THEN
    RAISE EXCEPTION 'Only partners can adjust Balanced Leave.' USING ERRCODE = '42501';
  END IF;
  IF p_action IS NULL OR p_action NOT IN ('credit', 'debit', 'set', 'credit_month', 'remove_month') THEN
    RAISE EXCEPTION 'Unknown Balanced Leave adjustment.' USING ERRCODE = '22023';
  END IF;
  IF v_reason IS NULL THEN
    RAISE EXCEPTION 'Give a reason for this adjustment.' USING ERRCODE = '22023';
  END IF;
  IF char_length(v_reason) > 500 THEN
    RAISE EXCEPTION 'The reason can be at most 500 characters.' USING ERRCODE = '22023';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM profiles p WHERE p.id = p_profile_id AND p.organization_id = v_org
                   AND p.deleted_at IS NULL)
     OR NOT auth_profile_visible(p_profile_id) THEN
    RAISE EXCEPTION 'Employee is not in your organization.' USING ERRCODE = '42501';
  END IF;

  IF p_action IN ('credit', 'debit', 'set') THEN
    IF p_days IS NULL OR p_days < 0 OR p_days > 999 OR p_days * 2 <> trunc(p_days * 2) THEN
      RAISE EXCEPTION 'Enter the days in steps of 0.5 (0 to 999).' USING ERRCODE = '22023';
    END IF;
    IF p_action <> 'set' AND p_days = 0 THEN
      RAISE EXCEPTION 'Enter more than 0 days.' USING ERRCODE = '22023';
    END IF;
  ELSE
    IF p_month IS NULL THEN
      RAISE EXCEPTION 'Choose the month.' USING ERRCODE = '22023';
    END IF;
    v_month := date_trunc('month', p_month)::date;
    IF v_month > date_trunc('month', org_today(v_org))::date THEN
      RAISE EXCEPTION 'A future month cannot be changed yet.' USING ERRCODE = '22023';
    END IF;
  END IF;

  v_before := bl_lock_balance(v_org, p_profile_id);

  IF p_action = 'credit' THEN
    PERFORM bl_post(v_org, p_profile_id, 'manual_credit', p_days, NULL, v_reason, NULL, NULL, true);
  ELSIF p_action = 'debit' THEN
    PERFORM bl_post(v_org, p_profile_id, 'manual_debit', -p_days, NULL, v_reason, NULL, NULL, false);
  ELSIF p_action = 'set' THEN
    PERFORM bl_post(v_org, p_profile_id, 'manual_set', NULL, p_days, v_reason, NULL, NULL, true);
  ELSE
    SELECT * INTO v_m FROM balanced_leave_months m
    WHERE m.organization_id = v_org AND m.profile_id = p_profile_id AND m.accrual_month = v_month;
    v_has := FOUND;
    IF p_action = 'credit_month' THEN
      PERFORM bl_post(v_org, p_profile_id, 'month_credit',
        CASE WHEN v_has AND v_m.credited THEN 0 ELSE 1 END, NULL, v_reason, v_month, NULL, true);
    ELSE
      -- Removing a credit that was already spent can leave a negative balance.
      PERFORM bl_post(v_org, p_profile_id, 'month_removal',
        CASE WHEN v_has AND v_m.credited THEN -1 ELSE 0 END, NULL, v_reason, v_month, NULL, true);
    END IF;
    INSERT INTO balanced_leave_months
      (organization_id, profile_id, accrual_month, credited, outcome, is_manual, note, decided_by)
    VALUES (v_org, p_profile_id, v_month, p_action = 'credit_month',
            CASE WHEN p_action = 'credit_month' THEN 'partner_credit' ELSE 'partner_removal' END,
            true, v_reason, v_me)
    ON CONFLICT (organization_id, profile_id, accrual_month) DO UPDATE
      SET credited = EXCLUDED.credited, outcome = EXCLUDED.outcome, is_manual = true,
          note = EXCLUDED.note, decided_by = EXCLUDED.decided_by, decided_at = now();
  END IF;

  SELECT b.balance INTO v_after FROM balanced_leave_balances b
  WHERE b.organization_id = v_org AND b.profile_id = p_profile_id;
  RETURN jsonb_build_object('profile_id', p_profile_id, 'action', p_action,
                            'balance_before', v_before, 'balance', v_after);
END;
$$;

-- 7.8 Privileges -------------------------------------------------------------------------------
REVOKE ALL ON FUNCTION bl_leave_days(TEXT) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_day_chargeable(UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_lock_balance(UUID, UUID) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_post(UUID, UUID, TEXT, NUMERIC, NUMERIC, TEXT, DATE, UUID, BOOLEAN)
  FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_month_eligibility(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_settle_month(UUID, UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_guard_leave_request() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION bl_sync_leave() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION run_balanced_leave_accrual(UUID) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION run_balanced_leave_accrual(UUID) TO service_role;
REVOKE ALL ON FUNCTION adjust_balanced_leave(UUID, TEXT, TEXT, NUMERIC, DATE) FROM PUBLIC, anon;
-- Callable by signed-in users; the function itself rejects anyone below Partner.
GRANT EXECUTE ON FUNCTION adjust_balanced_leave(UUID, TEXT, TEXT, NUMERIC, DATE) TO authenticated;

-- 7.9 Schedule (cron.schedule upserts by job name) -----------------------------------------------
-- 00:20 UTC = 05:50 IST, after midnight in the organization's timezone.
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_extension WHERE extname = 'pg_cron') THEN
    PERFORM cron.schedule('balanced-leave-accrual', '20 0 * * *',
      $cron$ SELECT public.run_balanced_leave_accrual(); $cron$);
  ELSE
    RAISE WARNING '050: pg_cron is not installed - schedule public.run_balanced_leave_accrual() daily.';
  END IF;
END $$;

COMMIT;
