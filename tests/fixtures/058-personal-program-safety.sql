-- Keep 057 immutable for already deployed databases.
ALTER TABLE personal_program_owners ADD COLUMN version bigint NOT NULL DEFAULT 0 CHECK (version >= 0);

-- Recover personal programs previously assigned via the generic admin API.
-- Preserve their assignments and execution history and expose their actual started state.
UPDATE personal_program_owners o
SET started_at=COALESCE((SELECT MIN(up.assigned_at) FROM user_programs up WHERE up.program_id=o.program_id),o.created_at),
    version=version+1
WHERE o.started_at IS NULL AND EXISTS(SELECT 1 FROM user_programs up WHERE up.program_id=o.program_id);

CREATE OR REPLACE FUNCTION guard_personal_program_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_id integer; started timestamp;
BEGIN
    SELECT user_id, started_at INTO owner_id, started FROM personal_program_owners
      WHERE program_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.program_id ELSE NEW.program_id END;
    IF owner_id IS NOT NULL THEN
        IF TG_OP = 'INSERT' AND current_setting('workouts.personal_program_start', true) IS DISTINCT FROM NEW.program_id::text THEN
            RAISE EXCEPTION 'Personal programs must be started through their dedicated API' USING ERRCODE = '23514';
        END IF;
        IF TG_OP = 'DELETE' AND started IS NOT NULL THEN
            RAISE EXCEPTION 'A started personal program assignment cannot be removed' USING ERRCODE = '23514';
        ELSIF TG_OP <> 'DELETE' AND NEW.user_id <> owner_id THEN
            RAISE EXCEPTION 'A personal program can only be assigned to its owner' USING ERRCODE = '23514';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE OR REPLACE FUNCTION guard_personal_program_structure() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_data jsonb; new_data jsonb; program_key integer;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_data := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN new_data := to_jsonb(NEW); END IF;
    FOR program_key IN
        SELECT p.program_id FROM personal_program_owners p WHERE
          (TG_TABLE_NAME = 'programs' AND p.program_id IN ((old_data->>'id')::integer, (new_data->>'id')::integer)) OR
          (TG_TABLE_NAME IN ('program_workouts','program_translations') AND p.program_id IN ((old_data->>'program_id')::integer, (new_data->>'program_id')::integer)) OR
          (TG_TABLE_NAME IN ('workouts','workout_exercises','workout_translations') AND p.program_id IN
            (SELECT o.program_id FROM personal_workout_owners o WHERE o.workout_id IN
              (CASE WHEN TG_TABLE_NAME='workouts' THEN (old_data->>'id')::integer ELSE (old_data->>'workout_id')::integer END,
               CASE WHEN TG_TABLE_NAME='workouts' THEN (new_data->>'id')::integer ELSE (new_data->>'workout_id')::integer END)))
    LOOP
        PERFORM pg_advisory_xact_lock(71003, program_key);
        IF EXISTS(SELECT 1 FROM personal_program_owners WHERE program_id=program_key AND started_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Started personal program structure is immutable' USING ERRCODE = '23514';
        END IF;
        UPDATE personal_program_owners o SET version=o.version+1 WHERE o.program_id=program_key
          AND EXISTS(SELECT 1 FROM programs p JOIN users u ON u.id=o.user_id WHERE p.id=program_key);
    END LOOP;
    IF TG_OP <> 'DELETE' AND TG_TABLE_NAME = 'program_workouts' THEN
        IF EXISTS(SELECT 1 FROM personal_program_owners WHERE program_id=NEW.program_id) OR
           EXISTS(SELECT 1 FROM personal_workout_owners WHERE workout_id=NEW.workout_id) THEN
            IF NOT EXISTS(SELECT 1 FROM personal_workout_owners WHERE workout_id=NEW.workout_id AND program_id=NEW.program_id) THEN
                RAISE EXCEPTION 'Personal workout must belong to the same personal program' USING ERRCODE = '23514';
            END IF;
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;

CREATE TRIGGER personal_program_translation_structure_guard BEFORE INSERT OR UPDATE OR DELETE ON program_translations
    FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
CREATE TRIGGER personal_workout_translation_structure_guard BEFORE INSERT OR UPDATE OR DELETE ON workout_translations
    FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
