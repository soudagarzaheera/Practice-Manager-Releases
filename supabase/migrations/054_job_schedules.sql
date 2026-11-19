-- ==============================================================================
-- 054: CALENDAR-BASED JOB CODE SCHEDULES (replaces 048's frequency rules)
-- ==============================================================================
-- 048 made a job code recur through rules: frequency, period start, "day N of
-- the month <offset> months after the period ends" for the statutory and the
-- internal due date, and a rollover that closed each period when it ended.
-- That is replaced by plain dates: the job code form keeps its Statutory due
-- and Internal due date pickers and gains one "Repeat" dropdown (Does not
-- repeat / Daily / Weekly / Monthly / Every 3 months / Every 6 months /
-- Yearly) with an optional end (after N times, or on a date).
--
--   job_schedules           one row per scheduled job code (a series):
--     repeat                'none' | 'daily' | 'weekly' | 'monthly' | 'yearly'
--     repeat_interval       every N days / weeks / months / years (1 = every)
--     repeat_start          first date of the repeat (NULL when 'none')
--     repeat_until          last possible date of the repeat, or NULL
--     repeat_count          number of repeat dates, or NULL (until/count: one
--                           at most; both NULL = no end)
--     extra_dates           single dates outside the repeat ("Does not
--                           repeat" on a repeating code keeps just the
--                           current job's date here = no more jobs)
--     skipped_dates         repeat dates to leave out (not set by the form yet)
--     statutory_offset_days days from each internal due date to its statutory
--                           due date (negative = before; NULL = none), taken
--                           from the two dates on the form
--   jobs.schedule_id        the series a job belongs to (NULL = plain job)
--   jobs.schedule_date      the date this job was raised for = its internal
--                           due date
--
-- Schedule dates = repeat dates (minus skipped) + extra dates. Monthly and
-- yearly repeats count from repeat_start (start + k months), so they never
-- drift; a day the month does not have becomes its last day (31st -> 30 Apr).
-- Same rule as scheduleOccurrence() in index.html.
--
-- Generating jobs - generate_scheduled_jobs(), section 4: every scheduled job
-- code has one job per scheduled date. The job for the next date is raised
-- (same job code, client, company, title, service, budget, fee, responsible
-- partner, opener, team) once the latest job's date has passed or the latest
-- job has been closed - whichever comes first. Unlike 048, nothing is closed
-- automatically: an overdue job stays open (and overdue) until someone closes
-- it. Each date is raised once (unique schedule_id + schedule_date).
-- Runs hourly from pg_cron and whenever the app loads (caller's organization).
-- roll_recurring_jobs() is kept as an alias so older app builds keep working.
--
-- Existing data, section 5: every 048 recurring series (one job code, rows
-- linked by period) becomes a schedule: monthly repeat every 1/3/6/12 months
-- from its first period's internal due date, no end (or ending at the last
-- period when "Last period" was ticked), the statutory date kept at the
-- latest period's distance from it. Each existing row is attached with its
-- own internal due date. No job row's dates, status, tasks or time change,
-- and the 048 columns are kept as history (no longer read or written by the app).
--
-- Additive; safe to re-run.
-- ==============================================================================

-- ---- 1. table + columns ---------------------------------------------------------
CREATE TABLE IF NOT EXISTS job_schedules (
  id               UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  organization_id  UUID NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  repeat           TEXT NOT NULL DEFAULT 'none',
  repeat_interval  SMALLINT NOT NULL DEFAULT 1,
  repeat_start     DATE,
  repeat_until     DATE,
  repeat_count     SMALLINT,
  extra_dates      DATE[] NOT NULL DEFAULT '{}',
  skipped_dates    DATE[] NOT NULL DEFAULT '{}',
  statutory_offset_days INTEGER,
  created_by       UUID,
  created_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at       TIMESTAMPTZ NOT NULL DEFAULT now(),
  CONSTRAINT uq_job_schedules_org_id UNIQUE (organization_id, id),
  CONSTRAINT chk_job_schedules_repeat CHECK (repeat IN ('none', 'daily', 'weekly', 'monthly', 'yearly')),
  CONSTRAINT chk_job_schedules_interval CHECK (repeat_interval BETWEEN 1 AND 99),
  CONSTRAINT chk_job_schedules_start CHECK (repeat = 'none' OR repeat_start IS NOT NULL),
  CONSTRAINT chk_job_schedules_end CHECK (repeat_until IS NULL OR repeat_count IS NULL),
  CONSTRAINT chk_job_schedules_count CHECK (repeat_count IS NULL OR repeat_count BETWEEN 1 AND 999),
  CONSTRAINT chk_job_schedules_until CHECK (repeat_until IS NULL OR repeat_start IS NULL OR repeat_until >= repeat_start),
  CONSTRAINT chk_job_schedules_stat_offset CHECK (statutory_offset_days IS NULL OR statutory_offset_days BETWEEN -3660 AND 3660),
  CONSTRAINT chk_job_schedules_size CHECK (cardinality(extra_dates) <= 1000 AND cardinality(skipped_dates) <= 1000)
);

-- A database that ran the first draft of this file has job_schedules with a
-- boolean "statutory" (schedule dates = statutory dates) instead of
-- statutory_offset_days (schedule dates = internal due dates). Bring it to
-- this version: the gap is taken from each schedule's latest job, the repeat
-- start moves back by it, and the attached jobs' schedule_date becomes their
-- internal due date. No job's due dates change.
ALTER TABLE job_schedules ADD COLUMN IF NOT EXISTS statutory_offset_days INTEGER;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM information_schema.columns
             WHERE table_schema = 'public' AND table_name = 'job_schedules' AND column_name = 'statutory') THEN
    UPDATE job_schedules s
    SET statutory_offset_days = x.gap,
        repeat_start = CASE WHEN s.repeat_start IS NOT NULL AND x.gap IS NOT NULL THEN s.repeat_start - x.gap ELSE s.repeat_start END
    FROM (SELECT DISTINCT ON (schedule_id) schedule_id, statutory_due_date - internal_due_date AS gap
          FROM jobs WHERE schedule_id IS NOT NULL AND schedule_date IS NOT NULL
          -- prefer the original 048 rows (a job the draft raised has no gap)
          ORDER BY schedule_id, (frequency <> 'one_time') DESC, schedule_date DESC) x
    WHERE x.schedule_id = s.id AND s.statutory AND s.statutory_offset_days IS NULL;

    UPDATE jobs j SET schedule_date = j.internal_due_date
    FROM job_schedules s
    WHERE j.schedule_id = s.id AND s.statutory
      AND j.schedule_date IS NOT NULL AND j.internal_due_date IS NOT NULL
      AND j.schedule_date <> j.internal_due_date;

    ALTER TABLE job_schedules DROP COLUMN statutory;
  END IF;
END;
$$;

DROP TRIGGER IF EXISTS trg_job_schedules_updated_at ON job_schedules;
CREATE TRIGGER trg_job_schedules_updated_at BEFORE UPDATE ON job_schedules
  FOR EACH ROW EXECUTE FUNCTION update_updated_at_column();

ALTER TABLE job_schedules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON job_schedules FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON job_schedules TO authenticated;

-- Everyone in the organization reads schedules (jobs carry their own
-- visibility); Assistant Manager and above - who raise and edit job codes -
-- write them, as for jobs (030/032).
DROP POLICY IF EXISTS job_schedules_select ON job_schedules;
CREATE POLICY job_schedules_select ON job_schedules FOR SELECT TO authenticated
  USING (organization_id = auth_org_id());
DROP POLICY IF EXISTS job_schedules_insert ON job_schedules;
CREATE POLICY job_schedules_insert ON job_schedules FOR INSERT TO authenticated
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);
DROP POLICY IF EXISTS job_schedules_update ON job_schedules;
CREATE POLICY job_schedules_update ON job_schedules FOR UPDATE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60)
  WITH CHECK (organization_id = auth_org_id() AND auth_rank() >= 60);
-- Only a schedule no job uses can go (the foreign key below refuses the rest);
-- the app deletes one only to undo a job code that failed to save.
DROP POLICY IF EXISTS job_schedules_delete ON job_schedules;
CREATE POLICY job_schedules_delete ON job_schedules FOR DELETE TO authenticated
  USING (organization_id = auth_org_id() AND auth_rank() >= 60);

ALTER TABLE jobs ADD COLUMN IF NOT EXISTS schedule_id UUID;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS schedule_date DATE;
ALTER TABLE jobs DROP CONSTRAINT IF EXISTS fk_jobs_schedule;
ALTER TABLE jobs ADD CONSTRAINT fk_jobs_schedule
  FOREIGN KEY (organization_id, schedule_id) REFERENCES job_schedules(organization_id, id);
CREATE INDEX IF NOT EXISTS idx_jobs_schedule ON jobs (schedule_id, schedule_date) WHERE schedule_id IS NOT NULL;

-- ---- 2. uniqueness ----------------------------------------------------------------
-- A plain job code is unique; jobs of one schedule share their code, one job per date.
DROP INDEX IF EXISTS uq_jobs_org_code_one_time;
CREATE UNIQUE INDEX IF NOT EXISTS uq_jobs_org_code_plain
  ON jobs (organization_id, job_code) WHERE period_start IS NULL AND schedule_id IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_jobs_schedule_date
  ON jobs (organization_id, schedule_id, schedule_date) WHERE schedule_id IS NOT NULL AND schedule_date IS NOT NULL;

-- ---- 3. schedule date helpers + job guard --------------------------------------------
-- The k-th repeat date (k = 0 is the start). Months/years count from the start.
CREATE OR REPLACE FUNCTION job_schedule_occurrence(p_start DATE, p_repeat TEXT, p_interval INTEGER, p_k INTEGER)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_repeat
    WHEN 'daily'   THEN p_start + p_k * p_interval
    WHEN 'weekly'  THEN p_start + 7 * p_k * p_interval
    WHEN 'monthly' THEN (p_start + make_interval(months => p_k * p_interval))::date
    WHEN 'yearly'  THEN (p_start + make_interval(years => p_k * p_interval))::date
  END;
$$;

-- The first schedule date after p_after (NULL = none left).
CREATE OR REPLACE FUNCTION job_schedule_next(p_schedule UUID, p_after DATE)
RETURNS DATE LANGUAGE plpgsql STABLE SET search_path = public AS $$
DECLARE
  s job_schedules%ROWTYPE;
  v_extra DATE;
  v_rule DATE;
  d DATE;
  k INT := 0;
BEGIN
  SELECT * INTO s FROM job_schedules WHERE id = p_schedule;
  IF NOT FOUND THEN RETURN NULL; END IF;
  SELECT min(x) INTO v_extra FROM unnest(s.extra_dates) x WHERE x > p_after;
  IF s.repeat <> 'none' AND s.repeat_start IS NOT NULL THEN
    -- daily/weekly: jump straight to the first step at or after p_after
    IF s.repeat IN ('daily', 'weekly') AND p_after > s.repeat_start THEN
      k := GREATEST(0, ((p_after - s.repeat_start) / (CASE s.repeat WHEN 'weekly' THEN 7 ELSE 1 END * s.repeat_interval)) - 1);
    END IF;
    LOOP
      EXIT WHEN s.repeat_count IS NOT NULL AND k >= s.repeat_count;
      d := job_schedule_occurrence(s.repeat_start, s.repeat, s.repeat_interval, k);
      EXIT WHEN s.repeat_until IS NOT NULL AND d > s.repeat_until;
      EXIT WHEN v_extra IS NOT NULL AND d >= v_extra;
      IF d > p_after AND NOT (d = ANY (s.skipped_dates)) THEN v_rule := d; EXIT; END IF;
      k := k + 1;
      EXIT WHEN k > 200000;
    END LOOP;
  END IF;
  RETURN LEAST(v_rule, v_extra);     -- LEAST ignores NULLs
END;
$$;

-- 048's rule trigger is retired: due dates are no longer derived from rules.
DROP TRIGGER IF EXISTS trg_jobs_recurrence ON jobs;

-- Keeps schedule_date in step with schedule_id and refuses a job code clash:
-- a code belongs to one plain job or to one schedule (any number of dates).
CREATE OR REPLACE FUNCTION guard_job_schedule()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  IF NEW.schedule_id IS NULL THEN
    NEW.schedule_date := NULL;
  ELSIF NEW.schedule_date IS NULL THEN
    NEW.schedule_date := COALESCE(NEW.internal_due_date, NEW.statutory_due_date);
    IF NEW.schedule_date IS NULL THEN
      RAISE EXCEPTION 'A scheduled job needs its due date.' USING ERRCODE = '23502';
    END IF;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jobs o
    WHERE o.organization_id = NEW.organization_id AND o.id <> NEW.id
      AND upper(btrim(o.job_code)) = upper(btrim(NEW.job_code))
      AND NOT (NEW.schedule_id IS NOT NULL AND o.schedule_id IS NOT DISTINCT FROM NEW.schedule_id)
  ) THEN
    RAISE EXCEPTION 'Job code % already exists.', NEW.job_code USING ERRCODE = '23505';
  END IF;
  IF NEW.schedule_id IS NOT NULL AND EXISTS (
    SELECT 1 FROM jobs o
    WHERE o.organization_id = NEW.organization_id AND o.id <> NEW.id
      AND o.schedule_id = NEW.schedule_id AND o.schedule_date = NEW.schedule_date
  ) THEN
    RAISE EXCEPTION 'Job code % already has a job due on %.', NEW.job_code, to_char(NEW.schedule_date, 'DD Mon YYYY')
      USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guard_job_schedule() FROM PUBLIC, anon, authenticated;

-- Not fired by status-only updates (closing, reopening).
DROP TRIGGER IF EXISTS trg_jobs_schedule ON jobs;
CREATE TRIGGER trg_jobs_schedule
  BEFORE INSERT OR UPDATE OF job_code, schedule_id, schedule_date ON jobs
  FOR EACH ROW EXECUTE FUNCTION guard_job_schedule();

-- ---- 4. generating the next scheduled job ---------------------------------------------
-- Signed-in callers act on their own organization only (p_org is ignored);
-- pg_cron passes nothing = every organization. Returns the number of jobs
-- raised. Idempotent. A schedule that cannot raise its job (e.g. a clash) is
-- skipped with a warning and the rest carry on. Catches up one date per round.
CREATE OR REPLACE FUNCTION generate_scheduled_jobs(p_org UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org UUID := p_org;
  o RECORD;
  s RECORD;
  j jobs%ROWTYPE;
  v_today DATE;
  v_date DATE;
  v_label TEXT;
  v_new UUID;
  v_round INT;
  v_round_made INT;
  v_made INT := 0;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    v_org := auth_org_id();
    IF v_org IS NULL THEN RETURN 0; END IF;
    -- A system action, whoever's app load set it off: drop the caller's
    -- identity for the rest of this transaction (as 048's rollover did), so
    -- 042's partner guard treats the carried-forward partner as a pg_cron run.
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '', true);
  END IF;

  FOR o IN
    SELECT org.id, COALESCE(ns.timezone, 'Asia/Kolkata') AS tz
    FROM organizations org
    LEFT JOIN notification_settings ns ON ns.organization_id = org.id
    WHERE v_org IS NULL OR org.id = v_org
  LOOP
    v_today := (now() AT TIME ZONE o.tz)::date;

    FOR v_round IN 1..120 LOOP
      v_round_made := 0;
      -- the schedule row is the lock: two runs never raise the same date
      FOR s IN SELECT sc.id, sc.statutory_offset_days FROM job_schedules sc WHERE sc.organization_id = o.id
               FOR UPDATE SKIP LOCKED LOOP
        BEGIN
          -- the latest job of the schedule is the one carried forward
          SELECT x.* INTO j FROM jobs x
          WHERE x.organization_id = o.id AND x.schedule_id = s.id AND x.schedule_date IS NOT NULL
          ORDER BY x.schedule_date DESC LIMIT 1;
          CONTINUE WHEN NOT FOUND;
          CONTINUE WHEN j.schedule_date >= v_today AND j.status <> 'closed';
          CONTINUE WHEN j.client_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM clients c
                 WHERE c.organization_id = j.organization_id AND c.id = j.client_id AND c.is_active);
          CONTINUE WHEN EXISTS (SELECT 1 FROM jobs n WHERE n.organization_id = o.id AND n.previous_job_id = j.id);

          v_date := job_schedule_next(s.id, j.schedule_date);
          CONTINUE WHEN v_date IS NULL;
          v_label := to_char(v_date, 'DD Mon YYYY');

          INSERT INTO jobs (
            organization_id, client_id, company_id, job_code, title, service_category, period_fy,
            status, budget_hours, fee_amount, is_overhead, opened_by, opened_on, responsible_partner_id,
            internal_due_date, statutory_due_date, schedule_id, schedule_date, previous_job_id
          ) VALUES (
            j.organization_id, j.client_id, j.company_id, j.job_code,
            CASE WHEN COALESCE(btrim(j.period_fy), '') <> '' AND position(j.period_fy IN j.title) > 0
                 THEN replace(j.title, j.period_fy, v_label) ELSE j.title END,
            j.service_category, v_label,
            'open', j.budget_hours, j.fee_amount, j.is_overhead, j.opened_by, v_today,
            -- a partner who has since left falls back to the client's default (042)
            CASE WHEN is_active_partner(j.organization_id, j.responsible_partner_id)
                 THEN j.responsible_partner_id END,
            v_date, v_date + s.statutory_offset_days, s.id, v_date, j.id
          ) RETURNING id INTO v_new;

          INSERT INTO job_assignments (organization_id, job_id, profile_id, role_in_job)
          SELECT a.organization_id, v_new, a.profile_id, a.role_in_job
          FROM job_assignments a
          WHERE a.organization_id = j.organization_id AND a.job_id = j.id
          ON CONFLICT DO NOTHING;

          v_made := v_made + 1;
          v_round_made := v_round_made + 1;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'scheduled job % (schedule %) not raised: %', j.job_code, s.id, SQLERRM;
        END;
      END LOOP;
      EXIT WHEN v_round_made = 0;
    END LOOP;
  END LOOP;
  RETURN v_made;
END;
$$;

-- Older app builds call roll_recurring_jobs() on load: same work now.
CREATE OR REPLACE FUNCTION roll_recurring_jobs(p_org UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE sql SECURITY DEFINER SET search_path = public AS $$
  SELECT generate_scheduled_jobs(p_org);
$$;

REVOKE ALL ON FUNCTION job_schedule_occurrence(date, text, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION job_schedule_next(uuid, date) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_schedule_occurrence(date, text, integer, integer), job_schedule_next(uuid, date)
  TO authenticated, service_role;
REVOKE ALL ON FUNCTION generate_scheduled_jobs(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION generate_scheduled_jobs(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION roll_recurring_jobs(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION roll_recurring_jobs(uuid) TO authenticated, service_role;

-- ---- 5. existing 048 recurring jobs -> schedules ---------------------------------------
-- Only rows not yet attached (re-run safe). Rows are grouped per organization
-- and job code (048 kept one code per series). The guard is off while a
-- series is attached row by row (its other rows are not attached yet).
ALTER TABLE jobs DISABLE TRIGGER trg_jobs_schedule;
DO $$
DECLARE
  g RECORD;
  v_sched UUID;
BEGIN
  FOR g IN
    SELECT organization_id, upper(btrim(job_code)) AS code_key,
           (array_agg(frequency ORDER BY period_start DESC NULLS LAST))[1] AS frequency,
           (array_agg(id ORDER BY period_start DESC NULLS LAST))[1] AS latest_id,
           (array_agg(statutory_due_date - internal_due_date ORDER BY period_start DESC NULLS LAST))[1] AS stat_gap
    FROM jobs
    WHERE frequency IS NOT NULL AND frequency <> 'one_time' AND schedule_id IS NULL
    GROUP BY organization_id, upper(btrim(job_code))
  LOOP
    WITH sr AS (
      SELECT id, period_start, recurrence_stopped_at,
             COALESCE(internal_due_date, statutory_due_date, period_end) AS d
      FROM jobs
      WHERE organization_id = g.organization_id AND upper(btrim(job_code)) = g.code_key
        AND frequency <> 'one_time' AND schedule_id IS NULL
    )
    INSERT INTO job_schedules (organization_id, repeat, repeat_interval, repeat_start, repeat_until, statutory_offset_days)
    SELECT g.organization_id, 'monthly',
           CASE g.frequency WHEN 'quarterly' THEN 3 WHEN 'half_yearly' THEN 6 WHEN 'yearly' THEN 12 ELSE 1 END,
           (SELECT min(d) FROM sr),
           -- "Last period" ticked on the latest period: the schedule ends there
           (SELECT r.d FROM sr r WHERE r.id = g.latest_id AND r.recurrence_stopped_at IS NOT NULL),
           g.stat_gap
    WHERE (SELECT min(d) FROM sr) IS NOT NULL
    RETURNING id INTO v_sched;

    CONTINUE WHEN v_sched IS NULL;

    -- each row keeps its own dates; two rows on one date: the later-raised one
    -- is attached without a date (kept, never carried forward)
    UPDATE jobs x SET schedule_id = v_sched,
      schedule_date = CASE WHEN r.rn = 1 THEN r.d END
    FROM (
      SELECT id,
             COALESCE(internal_due_date, statutory_due_date, period_end) AS d,
             row_number() OVER (PARTITION BY COALESCE(internal_due_date, statutory_due_date, period_end) ORDER BY created_at) AS rn
      FROM jobs
      WHERE organization_id = g.organization_id AND upper(btrim(job_code)) = g.code_key
        AND frequency <> 'one_time' AND schedule_id IS NULL
    ) r
    WHERE x.id = r.id;
    v_sched := NULL;
  END LOOP;
END;
$$;
ALTER TABLE jobs ENABLE TRIGGER trg_jobs_schedule;

-- ---- 6. schedule (cron.schedule upserts by job name) ----------------------------------
DO $$
BEGIN
  PERFORM cron.unschedule('recurring-jobs-rollover');
EXCEPTION WHEN OTHERS THEN NULL;
END;
$$;
SELECT cron.schedule('scheduled-jobs-generate', '10 * * * *',
  $cron$ SELECT public.generate_scheduled_jobs(); $cron$);

-- Tell the API (PostgREST) about the new table and columns straight away.
NOTIFY pgrst, 'reload schema';
