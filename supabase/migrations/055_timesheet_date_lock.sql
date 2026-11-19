-- ==============================================================================
-- 055: TIMESHEETS LOCK PER DATE, NOT PER WEEK
-- ==============================================================================
-- Bug: after submitting the 16th and 17th, the 18th could not be entered. The
-- My time screen locked the whole week as soon as the week's status read
-- "submitted" (every entry with the approver, none in draft). The database
-- had no week lock - 036's guard_timesheet_entry locks each submitted row on
-- its own - but it also did not stop new time being added to a date that was
-- already submitted. The app now locks per date (dateSubmitted() in
-- index.html); this makes the database enforce the same rule.
--
-- Rule: a person cannot add a draft entry to - or move a draft onto - a date
-- of theirs that is submitted: it has time pending or approved and none of
-- its time was sent back (queried). A sent-back date is open again for
-- corrections, as before. Other dates of the same week are never affected.
-- Existing rows are not touched. Approver decisions, undo and service/cron
-- writes are unaffected (only API callers adding or moving drafts are checked).
-- Safe to re-run.
-- ==============================================================================

CREATE OR REPLACE FUNCTION guard_timesheet_date_locked()
RETURNS TRIGGER LANGUAGE plpgsql SET search_path = public AS $$
DECLARE
  v_date DATE := COALESCE(NEW.entry_date, NEW.week_start_date + NEW.day_index);
BEGIN
  IF current_user NOT IN ('authenticated', 'anon') THEN RETURN NEW; END IF;
  IF NEW.status <> 'draft' THEN RETURN NEW; END IF;
  IF TG_OP = 'UPDATE'
     AND v_date IS NOT DISTINCT FROM COALESCE(OLD.entry_date, OLD.week_start_date + OLD.day_index)
     AND NEW.profile_id IS NOT DISTINCT FROM OLD.profile_id THEN
    RETURN NEW;                                   -- a draft edited on its own date
  END IF;

  IF EXISTS (
       SELECT 1 FROM timesheet_entries t
       WHERE t.organization_id = NEW.organization_id AND t.profile_id = NEW.profile_id AND t.id <> NEW.id
         AND COALESCE(t.entry_date, t.week_start_date + t.day_index) = v_date
         AND t.status IN ('pending', 'approved'))
     AND NOT EXISTS (
       SELECT 1 FROM timesheet_entries t
       WHERE t.organization_id = NEW.organization_id AND t.profile_id = NEW.profile_id AND t.id <> NEW.id
         AND COALESCE(t.entry_date, t.week_start_date + t.day_index) = v_date
         AND t.status = 'queried') THEN
    RAISE EXCEPTION 'Time for % is already submitted and locked - choose a date that is not submitted yet.',
      to_char(v_date, 'Dy DD Mon YYYY') USING ERRCODE = '42501';
  END IF;
  RETURN NEW;
END;
$$;
REVOKE ALL ON FUNCTION guard_timesheet_date_locked() FROM PUBLIC, anon, authenticated;

DROP TRIGGER IF EXISTS trg_timesheet_date_locked ON timesheet_entries;
CREATE TRIGGER trg_timesheet_date_locked
  BEFORE INSERT OR UPDATE OF entry_date, week_start_date, day_index, profile_id ON timesheet_entries
  FOR EACH ROW EXECUTE FUNCTION guard_timesheet_date_locked();
