-- ==============================================================================
-- 048: RECURRING JOB CODES (frequency, period, due-date rules, rollover)
-- ==============================================================================
-- A job code can now recur: Monthly, Quarterly, Half-yearly or Yearly
-- (One-time = every existing job, unchanged).
--
--   jobs.frequency          'one_time' (default) | 'monthly' | 'quarterly' |
--                           'half_yearly' | 'yearly'
--   jobs.period_start/end   the job's calendar period. The start is always the
--                           1st of a month; the end is worked out here (start +
--                           1/3/6/12 calendar months − 1 day). NULL on one-time jobs.
--   statutory rule          stat_due_day + stat_due_month_offset: day N of the
--                           month that is <offset> months after the period's
--                           last month (0 = the period's last month). Both NULL
--                           = no statutory due date.
--   internal rule           internal_due_rule 'fixed' (internal_due_day +
--                           internal_due_month_offset, as above) or
--                           'statutory_offset' (internal_due_offset_days days
--                           after the statutory due date; negative = before).
--   previous_job_id         the earlier period this job was raised from.
--   recurrence_stopped_at   set = do not raise a next period after this one.
--
-- Dates use calendar months, never a fixed number of days, so they do not
-- drift. A day the target month does not have becomes that month's last day
-- (31st → 28/29 Feb, 30 Apr …). On a recurring job, statutory_due_date and
-- internal_due_date always follow the rules (trigger, section 3).
--
-- Rollover - roll_recurring_jobs(), section 4: the day after a period ends
-- (organization's local date, notification_settings.timezone, default
-- Asia/Kolkata), the period's job is closed and the next period's job is
-- raised with the same job code and saved details (client, company, title,
-- service, budget, fee, responsible partner, opener, frequency, rules, team).
-- The closed job keeps its period, dates, tasks, time and closing history.
-- Each job rolls over once (previous_job_id is unique), so reopening a closed
-- period does not close it again or raise a second next period.
-- Runs hourly from pg_cron and whenever the app loads (caller's organization).
--
-- Duplicates: UNIQUE (organization_id, job_code) is replaced by
--   * one-time jobs: job code unique, as before;
--   * recurring jobs: job code + period unique;
--   * a code is either one-time or recurring, never both (trigger, 23505).
--
-- Additive: no existing row changes (all become frequency 'one_time').
-- Safe to re-run.
-- ==============================================================================

-- ---- 1. columns ------------------------------------------------------------------
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS frequency TEXT NOT NULL DEFAULT 'one_time';
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS period_start DATE;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS period_end DATE;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS stat_due_day SMALLINT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS stat_due_month_offset SMALLINT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS internal_due_rule TEXT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS internal_due_day SMALLINT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS internal_due_month_offset SMALLINT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS internal_due_offset_days SMALLINT;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS previous_job_id UUID;
ALTER TABLE jobs ADD COLUMN IF NOT EXISTS recurrence_stopped_at TIMESTAMPTZ;

ALTER TABLE jobs DROP CONSTRAINT IF EXISTS chk_jobs_frequency;
ALTER TABLE jobs ADD CONSTRAINT chk_jobs_frequency
  CHECK (frequency IN ('one_time', 'monthly', 'quarterly', 'half_yearly', 'yearly'));
ALTER TABLE jobs DROP CONSTRAINT IF EXISTS chk_jobs_recurrence_rules;
ALTER TABLE jobs ADD CONSTRAINT chk_jobs_recurrence_rules CHECK (
  (stat_due_day IS NULL OR stat_due_day BETWEEN 1 AND 31)
  AND (stat_due_month_offset IS NULL OR stat_due_month_offset BETWEEN 0 AND 12)
  AND (internal_due_rule IS NULL OR internal_due_rule IN ('fixed', 'statutory_offset'))
  AND (internal_due_day IS NULL OR internal_due_day BETWEEN 1 AND 31)
  AND (internal_due_month_offset IS NULL OR internal_due_month_offset BETWEEN 0 AND 12)
  AND (internal_due_offset_days IS NULL OR internal_due_offset_days BETWEEN -366 AND 366)
);

ALTER TABLE jobs DROP CONSTRAINT IF EXISTS fk_jobs_previous_job;
ALTER TABLE jobs ADD CONSTRAINT fk_jobs_previous_job
  FOREIGN KEY (organization_id, previous_job_id) REFERENCES jobs(organization_id, id)
  ON DELETE SET NULL (previous_job_id);

-- ---- 2. uniqueness ----------------------------------------------------------------
-- Nothing references uq_org_job_code (no FK, no ON CONFLICT target).
ALTER TABLE jobs DROP CONSTRAINT IF EXISTS uq_org_job_code;
CREATE UNIQUE INDEX IF NOT EXISTS uq_jobs_org_code_one_time
  ON jobs (organization_id, job_code) WHERE period_start IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS uq_jobs_org_code_period
  ON jobs (organization_id, upper(btrim(job_code)), period_start) WHERE period_start IS NOT NULL;
-- One next period per job.
CREATE UNIQUE INDEX IF NOT EXISTS uq_jobs_previous_job
  ON jobs (organization_id, previous_job_id) WHERE previous_job_id IS NOT NULL;

-- ---- 3. date helpers + recurrence trigger -------------------------------------------
CREATE OR REPLACE FUNCTION job_frequency_months(p_frequency TEXT)
RETURNS INTEGER LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE p_frequency WHEN 'monthly' THEN 1 WHEN 'quarterly' THEN 3
                          WHEN 'half_yearly' THEN 6 WHEN 'yearly' THEN 12 END;
$$;

-- Last day of the period that starts on p_start.
CREATE OR REPLACE FUNCTION job_period_end(p_start DATE, p_frequency TEXT)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
  SELECT (p_start + make_interval(months => job_frequency_months(p_frequency)) - interval '1 day')::date;
$$;

-- Day p_day of the month p_offset months after p_anchor's month; a day that
-- month does not have becomes its last day. Same rule as ruleDay() in index.html.
CREATE OR REPLACE FUNCTION job_rule_day(p_anchor DATE, p_day INTEGER, p_offset INTEGER)
RETURNS DATE LANGUAGE sql IMMUTABLE AS $$
  SELECT CASE WHEN p_anchor IS NULL OR p_day IS NULL OR p_offset IS NULL THEN NULL
    ELSE m + (LEAST(p_day, extract(day FROM (m + interval '1 month' - interval '1 day'))::int) - 1) END
  FROM (SELECT (date_trunc('month', p_anchor) + make_interval(months => COALESCE(p_offset, 0)))::date AS m) s;
$$;

-- Period name, e.g. 'Oct 2026', 'Q3 FY 2026-27', 'H1 FY 2026-27', 'FY 2026-27'
-- (Indian FY from April); a period not on those boundaries is 'Feb 2026 – Apr 2026'.
-- Same rule as periodLabel() in index.html.
CREATE OR REPLACE FUNCTION job_period_label(p_start DATE, p_frequency TEXT)
RETURNS TEXT LANGUAGE plpgsql STABLE AS $$
DECLARE
  m INT; y INT; fy_y INT; fy TEXT; rng TEXT;
BEGIN
  IF p_start IS NULL OR job_frequency_months(p_frequency) IS NULL THEN RETURN NULL; END IF;
  m := extract(month FROM p_start); y := extract(year FROM p_start);
  fy_y := CASE WHEN m >= 4 THEN y ELSE y - 1 END;
  fy := fy_y || '-' || lpad(((fy_y + 1) % 100)::text, 2, '0');
  rng := to_char(p_start, 'Mon YYYY') || ' – ' || to_char(job_period_end(p_start, p_frequency), 'Mon YYYY');
  RETURN CASE p_frequency
    WHEN 'monthly'     THEN to_char(p_start, 'Mon YYYY')
    WHEN 'quarterly'   THEN CASE WHEN m IN (1, 4, 7, 10) THEN 'Q' || ((m + 8) % 12 / 3 + 1) || ' FY ' || fy ELSE rng END
    WHEN 'half_yearly' THEN CASE WHEN m = 4 THEN 'H1 FY ' || fy WHEN m = 10 THEN 'H2 FY ' || fy ELSE rng END
    WHEN 'yearly'      THEN CASE WHEN m = 4 THEN 'FY ' || fy ELSE rng END
  END;
END;
$$;

-- Normalises the period and rules, sets both due dates from the rules, and
-- refuses a job code clash with a readable message.
CREATE OR REPLACE FUNCTION guard_job_recurrence()
RETURNS TRIGGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
BEGIN
  NEW.frequency := COALESCE(NEW.frequency, 'one_time');
  IF NEW.frequency = 'one_time' THEN
    NEW.period_start := NULL; NEW.period_end := NULL;
    NEW.stat_due_day := NULL; NEW.stat_due_month_offset := NULL;
    NEW.internal_due_rule := NULL; NEW.internal_due_day := NULL;
    NEW.internal_due_month_offset := NULL; NEW.internal_due_offset_days := NULL;
  ELSE
    IF NEW.period_start IS NULL THEN
      RAISE EXCEPTION 'A recurring job needs the month its period starts.' USING ERRCODE = '23502';
    END IF;
    NEW.period_start := date_trunc('month', NEW.period_start)::date;
    NEW.period_end := job_period_end(NEW.period_start, NEW.frequency);
    NEW.period_fy := job_period_label(NEW.period_start, NEW.frequency);

    IF (NEW.stat_due_day IS NULL) <> (NEW.stat_due_month_offset IS NULL) THEN
      RAISE EXCEPTION 'The statutory due rule needs both a day and a month.' USING ERRCODE = '23514';
    END IF;
    IF NEW.internal_due_rule IS NULL THEN
      RAISE EXCEPTION 'A recurring job needs an internal due date rule.' USING ERRCODE = '23502';
    ELSIF NEW.internal_due_rule = 'fixed' THEN
      IF NEW.internal_due_day IS NULL OR NEW.internal_due_month_offset IS NULL THEN
        RAISE EXCEPTION 'The internal due rule needs both a day and a month.' USING ERRCODE = '23514';
      END IF;
      NEW.internal_due_offset_days := NULL;
    ELSE
      IF NEW.internal_due_offset_days IS NULL OR NEW.stat_due_day IS NULL THEN
        RAISE EXCEPTION 'An internal due date counted from the statutory due date needs a statutory due rule and a number of days.'
          USING ERRCODE = '23514';
      END IF;
      NEW.internal_due_day := NULL; NEW.internal_due_month_offset := NULL;
    END IF;

    NEW.statutory_due_date := job_rule_day(NEW.period_end, NEW.stat_due_day, NEW.stat_due_month_offset);
    NEW.internal_due_date := CASE NEW.internal_due_rule
      WHEN 'fixed' THEN job_rule_day(NEW.period_end, NEW.internal_due_day, NEW.internal_due_month_offset)
      ELSE NEW.statutory_due_date + NEW.internal_due_offset_days END;
  END IF;

  IF EXISTS (
    SELECT 1 FROM jobs o
    WHERE o.organization_id = NEW.organization_id AND o.id <> NEW.id
      AND upper(btrim(o.job_code)) = upper(btrim(NEW.job_code))
      AND (o.period_start IS NULL OR NEW.period_start IS NULL OR o.period_start = NEW.period_start)
  ) THEN
    RAISE EXCEPTION 'Job code % already exists%.', NEW.job_code,
      CASE WHEN NEW.period_start IS NULL THEN '' ELSE ' for ' || job_period_label(NEW.period_start, NEW.frequency) END
      USING ERRCODE = '23505';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guard_job_recurrence() FROM PUBLIC, anon, authenticated;

-- Not fired by status-only updates (closing, reopening), so those never move a
-- job's period or dates.
DROP TRIGGER IF EXISTS trg_jobs_recurrence ON jobs;
CREATE TRIGGER trg_jobs_recurrence
  BEFORE INSERT OR UPDATE OF job_code, frequency, period_start, period_end,
    stat_due_day, stat_due_month_offset, internal_due_rule, internal_due_day,
    internal_due_month_offset, internal_due_offset_days, statutory_due_date, internal_due_date
  ON jobs FOR EACH ROW EXECUTE FUNCTION guard_job_recurrence();

-- ---- 4. rollover --------------------------------------------------------------------
-- Signed-in callers act on their own organization only (p_org is ignored);
-- pg_cron passes nothing = every organization. Returns the number of jobs
-- raised. Idempotent. A job that cannot roll over (e.g. a clash) is skipped
-- with a warning and the rest carry on. Catches up one period per round, so a
-- missed month is raised (and closed) rather than skipped.
CREATE OR REPLACE FUNCTION roll_recurring_jobs(p_org UUID DEFAULT NULL)
RETURNS INTEGER
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public AS $$
DECLARE
  v_org UUID := p_org;
  o RECORD;
  j RECORD;
  v_today DATE;
  v_start DATE;
  v_label TEXT;
  v_old_label TEXT;
  v_next UUID;
  v_round INT;
  v_round_made INT;
  v_made INT := 0;
BEGIN
  IF auth.uid() IS NOT NULL THEN
    v_org := auth_org_id();
    IF v_org IS NULL THEN RETURN 0; END IF;
    -- The rollover is a system action, whoever's app load set it off: drop the
    -- caller's identity for the rest of this transaction (the RPC call), so
    -- 042's partner guard treats the carried-forward partner as it does a
    -- pg_cron run instead of checking this caller's own permission.
    PERFORM set_config('request.jwt.claim.sub', '', true);
    PERFORM set_config('request.jwt.claims', '', true);
  END IF;

  FOR o IN
    SELECT org.id, COALESCE(s.timezone, 'Asia/Kolkata') AS tz
    FROM organizations org
    LEFT JOIN notification_settings s ON s.organization_id = org.id
    WHERE v_org IS NULL OR org.id = v_org
  LOOP
    v_today := (now() AT TIME ZONE o.tz)::date;

    FOR v_round IN 1..120 LOOP
      v_round_made := 0;
      FOR j IN
        SELECT x.* FROM jobs x
        WHERE x.organization_id = o.id
          AND x.frequency <> 'one_time'
          AND x.period_end < v_today
          AND x.recurrence_stopped_at IS NULL
          AND NOT EXISTS (SELECT 1 FROM jobs n
                          WHERE n.organization_id = x.organization_id AND n.previous_job_id = x.id)
          AND (x.client_id IS NULL OR EXISTS (SELECT 1 FROM clients c
                 WHERE c.organization_id = x.organization_id AND c.id = x.client_id AND c.is_active))
        ORDER BY x.period_start
        FOR UPDATE OF x SKIP LOCKED
      LOOP
        BEGIN
          v_start := (j.period_start + make_interval(months => job_frequency_months(j.frequency)))::date;
          v_label := job_period_label(v_start, j.frequency);
          v_old_label := COALESCE(NULLIF(btrim(j.period_fy), ''), job_period_label(j.period_start, j.frequency));
          v_next := NULL;

          -- The next period may already have been raised by hand: link it
          -- instead of raising a duplicate.
          SELECT n.id INTO v_next FROM jobs n
          WHERE n.organization_id = j.organization_id
            AND upper(btrim(n.job_code)) = upper(btrim(j.job_code))
            AND n.period_start = v_start AND n.previous_job_id IS NULL
          LIMIT 1;

          IF v_next IS NOT NULL THEN
            UPDATE jobs SET previous_job_id = j.id WHERE id = v_next;
          ELSE
            INSERT INTO jobs (
              organization_id, client_id, company_id, job_code, title, service_category, period_fy,
              status, budget_hours, fee_amount, is_overhead, opened_by, opened_on, responsible_partner_id,
              frequency, period_start, stat_due_day, stat_due_month_offset, internal_due_rule,
              internal_due_day, internal_due_month_offset, internal_due_offset_days, previous_job_id
            ) VALUES (
              j.organization_id, j.client_id, j.company_id, j.job_code,
              CASE WHEN v_old_label <> '' AND position(v_old_label IN j.title) > 0
                   THEN replace(j.title, v_old_label, v_label) ELSE j.title END,
              j.service_category, v_label,
              'open', j.budget_hours, j.fee_amount, j.is_overhead, j.opened_by, v_today,
              -- a partner who has since left falls back to the client's default (042)
              CASE WHEN is_active_partner(j.organization_id, j.responsible_partner_id)
                   THEN j.responsible_partner_id END,
              j.frequency, v_start, j.stat_due_day, j.stat_due_month_offset, j.internal_due_rule,
              j.internal_due_day, j.internal_due_month_offset, j.internal_due_offset_days, j.id
            ) RETURNING id INTO v_next;

            INSERT INTO job_assignments (organization_id, job_id, profile_id, role_in_job)
            SELECT a.organization_id, v_next, a.profile_id, a.role_in_job
            FROM job_assignments a
            WHERE a.organization_id = j.organization_id AND a.job_id = j.id
            ON CONFLICT DO NOTHING;
            v_made := v_made + 1;
          END IF;

          -- Close the ended period (an already-closed job keeps its own closing details).
          IF j.status <> 'closed' THEN
            UPDATE jobs SET status = 'closed', closed_at = now(),
              closing_note = format('Period %s ended - closed automatically. The next period (%s) was raised with the same job code.',
                                    v_old_label, v_label)
            WHERE id = j.id;
          END IF;
          v_round_made := v_round_made + 1;
        EXCEPTION WHEN OTHERS THEN
          RAISE WARNING 'recurring job % (%) not rolled over: %', j.job_code, j.id, SQLERRM;
        END;
      END LOOP;
      EXIT WHEN v_round_made = 0;
    END LOOP;
  END LOOP;
  RETURN v_made;
END;
$$;

REVOKE ALL ON FUNCTION job_frequency_months(text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION job_period_end(date, text) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION job_rule_day(date, integer, integer) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION job_period_label(date, text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION job_frequency_months(text), job_period_end(date, text),
  job_rule_day(date, integer, integer), job_period_label(date, text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION roll_recurring_jobs(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION roll_recurring_jobs(uuid) TO authenticated, service_role;

-- ---- 5. schedule (cron.schedule upserts by job name) ----------------------------------
SELECT cron.schedule('recurring-jobs-rollover', '10 * * * *',
  $cron$ SELECT public.roll_recurring_jobs(); $cron$);
