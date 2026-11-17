-- ==============================================================================
-- 049: RE-CLASSIFY ATTENDANCE WHEN A HOLIDAY'S DATE CHANGES
-- ==============================================================================
-- Problem (found live, 2026-11-17): "Bhai Dooj" was stored on 2026-11-11 and
-- later moved to 2026-11-10. Employees who worked on 11 Nov had already been
-- credited 1 Earned Leave with reason 'holiday_worked' by
-- trg_attendance_holiday_worked (045). Nothing re-checks
-- earned_leave_transactions when a holiday changes, so 11 Nov still showed as
-- "Holiday worked" (EL history, EL balance, salary "EL earned"), even though
-- the holiday list said 10 Nov.
--
-- earned_leave_transactions is the only place the database keeps a day's
-- holiday classification. Attendance status, calendar, dashboard and salary
-- are recalculated in the app from `holidays` + `attendance_punches`.
--
-- This migration:
--   1. reconcile_extra_work_day_credits(org, date) brings ONE date's ledger
--      rows in line with the current holidays, using the 045 rules:
--        * removes credits that no longer qualify (date is no longer a
--          holiday/Saturday, or the day is not complete);
--        * corrects reason / holiday_id on credits that still qualify
--          (e.g. a holiday moved onto a Saturday);
--        * adds a credit for a complete day that now qualifies, only for a
--          date up to the organization's today, and only when the punch-out
--          was recorded live (within ±1 day of its punch_date - the same
--          anti-back-dating rule as the 045 punch trigger).
--      Only dates from optional_days_rule_from() (2026-11-01) are touched;
--      older payroll keeps its old rules, as in 045. Every change is written
--      to audit_logs (earned_leave_removed / earned_leave_reclassified /
--      earned_leave_credited).
--   2. trg_holiday_reclassify_attendance (AFTER INSERT / UPDATE OF
--      holiday_date / DELETE on holidays) runs it for the old and new date, so
--      future holiday edits update attendance classification automatically.
--   3. One-time correction for the 11 Nov → 10 Nov move, every organization.
--   4. seed_2026_holidays_for_org() (017) seeds Bhai Dooj on 10 Nov, not 11.
--
-- attendance_punches is never written: punch times, GPS coordinates,
-- addresses and all other attendance data are preserved; no punch rows are
-- added or deleted. No new tables. The past-date lock (043) is unchanged.
-- Re-runnable. Apply with: supabase db query --linked -f <this file>
-- ==============================================================================

-- 1. Reconcile one date ------------------------------------------------------------
CREATE OR REPLACE FUNCTION reconcile_extra_work_day_credits(p_org UUID, p_date DATE)
RETURNS VOID
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_reason  TEXT;
  v_holiday UUID;
  v_tz      TEXT;
BEGIN
  IF p_org IS NULL OR p_date IS NULL OR p_date < optional_days_rule_from() THEN
    RETURN;
  END IF;
  v_reason := extra_work_day_reason(p_org, p_date);
  SELECT h.id INTO v_holiday FROM holidays h
  WHERE h.organization_id = p_org AND h.holiday_date = p_date;

  -- (a) credits that no longer qualify
  WITH removed AS (
    DELETE FROM earned_leave_transactions e
    WHERE e.organization_id = p_org AND e.worked_date = p_date
      AND (v_reason IS NULL OR NOT attendance_day_complete(p_org, e.profile_id, p_date))
    RETURNING e.*
  )
  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values)
  SELECT r.organization_id, auth_profile_id(), 'earned_leave_removed', 'earned_leave_transactions', r.id::text,
         to_jsonb(r) || jsonb_build_object('note', '049: holiday date changed - date no longer qualifies')
  FROM removed r;

  IF v_reason IS NULL THEN
    RETURN;
  END IF;

  -- (b) credits that still qualify but for a different reason / holiday
  WITH changed AS (
    UPDATE earned_leave_transactions e
    SET reason = v_reason, holiday_id = v_holiday
    FROM earned_leave_transactions old
    WHERE old.id = e.id
      AND e.organization_id = p_org AND e.worked_date = p_date
      AND (e.reason IS DISTINCT FROM v_reason OR e.holiday_id IS DISTINCT FROM v_holiday)
    RETURNING e.*, old.reason AS old_reason, old.holiday_id AS old_holiday_id
  )
  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, old_values, new_values)
  SELECT c.organization_id, auth_profile_id(), 'earned_leave_reclassified', 'earned_leave_transactions', c.id::text,
         jsonb_build_object('worked_date', c.worked_date, 'reason', c.old_reason, 'holiday_id', c.old_holiday_id),
         jsonb_build_object('worked_date', c.worked_date, 'reason', c.reason, 'holiday_id', c.holiday_id,
                            'note', '049: holiday date changed')
  FROM changed c;

  -- (c) complete, live-recorded days that now qualify (past/today only)
  IF p_date > org_today(p_org) THEN
    RETURN;
  END IF;
  v_tz := COALESCE((SELECT s.timezone FROM notification_settings s WHERE s.organization_id = p_org), 'Asia/Kolkata');

  WITH qualifying AS (
    SELECT DISTINCT a.profile_id
    FROM attendance_punches a
    WHERE a.organization_id = p_org AND a.punch_date = p_date AND a.punch_type = 'out'
      AND (a.created_at AT TIME ZONE v_tz)::date BETWEEN p_date - 1 AND p_date + 1
      AND attendance_day_complete(p_org, a.profile_id, p_date)
  ), added AS (
    INSERT INTO earned_leave_transactions
      (organization_id, profile_id, worked_date, holiday_id, source_type, source_id, reason)
    SELECT p_org, q.profile_id, p_date, v_holiday, 'backfill', NULL, v_reason
    FROM qualifying q
    ON CONFLICT (organization_id, profile_id, worked_date) DO NOTHING
    RETURNING *
  )
  INSERT INTO audit_logs (organization_id, actor_profile_id, action, entity_type, entity_id, new_values)
  SELECT a.organization_id, auth_profile_id(), 'earned_leave_credited', 'earned_leave_transactions', a.id::text,
         jsonb_build_object('profile_id', a.profile_id, 'worked_date', a.worked_date, 'reason', a.reason,
                            'earned_days', 1, 'source_type', 'backfill',
                            'note', '049: holiday date changed')
  FROM added a;
END;
$$;

-- 2. Run it whenever a holiday is added, moved or deleted --------------------------
CREATE OR REPLACE FUNCTION holiday_reclassify_attendance()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF TG_OP IN ('UPDATE', 'DELETE') THEN
    PERFORM reconcile_extra_work_day_credits(OLD.organization_id, OLD.holiday_date);
  END IF;
  IF TG_OP IN ('INSERT', 'UPDATE') THEN
    PERFORM reconcile_extra_work_day_credits(NEW.organization_id, NEW.holiday_date);
  END IF;
  RETURN NULL;
END;
$$;

DROP TRIGGER IF EXISTS trg_holiday_reclassify_attendance ON holidays;
CREATE TRIGGER trg_holiday_reclassify_attendance
  AFTER INSERT OR UPDATE OF holiday_date, organization_id OR DELETE ON holidays
  FOR EACH ROW EXECUTE FUNCTION holiday_reclassify_attendance();

REVOKE ALL ON FUNCTION reconcile_extra_work_day_credits(UUID, DATE) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION holiday_reclassify_attendance() FROM PUBLIC, anon, authenticated;

-- 3. One-time correction: Bhai Dooj moved 2026-11-11 → 2026-11-10 -----------------
-- Only these two dates, every organization. Other dates are not touched.
SELECT reconcile_extra_work_day_credits(o.id, d.d)
FROM organizations o
CROSS JOIN (VALUES (DATE '2026-11-10'), (DATE '2026-11-11')) AS d(d);

-- 4. New organizations get the corrected date --------------------------------------
CREATE OR REPLACE FUNCTION seed_2026_holidays_for_org()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  INSERT INTO holidays (organization_id, holiday_date, name, is_mandatory)
  VALUES
    (NEW.id, DATE '2026-10-02', 'Mahatma Gandhi Jayanti', true),
    (NEW.id, DATE '2026-11-09', 'Saal Mubarak', true),
    (NEW.id, DATE '2026-11-10', 'Bhai Dooj', true)
  ON CONFLICT (organization_id, holiday_date) DO NOTHING;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION seed_2026_holidays_for_org() FROM PUBLIC, anon, authenticated;
