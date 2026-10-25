CREATE TABLE personal_program_owners (
    program_id integer PRIMARY KEY REFERENCES programs(id) ON DELETE CASCADE,
    user_id integer NOT NULL REFERENCES users(id) ON DELETE CASCADE,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    started_at timestamp,
    UNIQUE(program_id, user_id)
);
CREATE INDEX idx_personal_program_owner_user ON personal_program_owners(user_id);
CREATE TABLE personal_workout_owners (
    workout_id integer PRIMARY KEY REFERENCES workouts(id) ON DELETE CASCADE,
    program_id integer NOT NULL,
    user_id integer NOT NULL,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP,
    FOREIGN KEY(program_id, user_id) REFERENCES personal_program_owners(program_id, user_id) ON DELETE CASCADE
);
CREATE INDEX idx_personal_workout_owner_user ON personal_workout_owners(user_id);
CREATE INDEX idx_personal_workout_owner_program ON personal_workout_owners(program_id);

-- Old assignment APIs, including admin APIs, cannot distribute a private program.
CREATE FUNCTION guard_personal_program_assignment() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE owner_id integer; started timestamp;
BEGIN
    SELECT user_id, started_at INTO owner_id, started FROM personal_program_owners
      WHERE program_id = CASE WHEN TG_OP = 'DELETE' THEN OLD.program_id ELSE NEW.program_id END;
    IF owner_id IS NOT NULL THEN
        IF TG_OP = 'DELETE' AND started IS NOT NULL THEN
            RAISE EXCEPTION 'A started personal program assignment cannot be removed' USING ERRCODE = '23514';
        ELSIF TG_OP <> 'DELETE' AND NEW.user_id <> owner_id THEN
            RAISE EXCEPTION 'A personal program can only be assigned to its owner' USING ERRCODE = '23514';
        END IF;
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END $$;
CREATE TRIGGER personal_program_assignment_guard BEFORE INSERT OR UPDATE OR DELETE ON user_programs
    FOR EACH ROW EXECUTE FUNCTION guard_personal_program_assignment();

-- Protect template history even when older admin endpoints are used.
CREATE FUNCTION guard_personal_program_structure() RETURNS trigger LANGUAGE plpgsql AS $$
DECLARE old_data jsonb; new_data jsonb; program_key integer;
BEGIN
    IF TG_OP <> 'INSERT' THEN old_data := to_jsonb(OLD); END IF;
    IF TG_OP <> 'DELETE' THEN new_data := to_jsonb(NEW); END IF;
    FOR program_key IN
        SELECT p.program_id FROM personal_program_owners p WHERE
          (TG_TABLE_NAME = 'programs' AND p.program_id IN ((old_data->>'id')::integer, (new_data->>'id')::integer)) OR
          (TG_TABLE_NAME = 'program_workouts' AND p.program_id IN ((old_data->>'program_id')::integer, (new_data->>'program_id')::integer)) OR
          (TG_TABLE_NAME IN ('workouts','workout_exercises') AND p.program_id IN
            (SELECT o.program_id FROM personal_workout_owners o WHERE o.workout_id IN
              (CASE WHEN TG_TABLE_NAME='workouts' THEN (old_data->>'id')::integer ELSE (old_data->>'workout_id')::integer END,
               CASE WHEN TG_TABLE_NAME='workouts' THEN (new_data->>'id')::integer ELSE (new_data->>'workout_id')::integer END)))
    LOOP
        PERFORM pg_advisory_xact_lock(71003, program_key);
        IF EXISTS(SELECT 1 FROM personal_program_owners WHERE program_id=program_key AND started_at IS NOT NULL) THEN
            RAISE EXCEPTION 'Started personal program structure is immutable' USING ERRCODE = '23514';
        END IF;
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
CREATE TRIGGER personal_program_structure_guard BEFORE UPDATE OR DELETE ON programs FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
CREATE TRIGGER personal_workout_structure_guard BEFORE UPDATE OR DELETE ON workouts FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
CREATE TRIGGER personal_program_workout_structure_guard BEFORE INSERT OR UPDATE OR DELETE ON program_workouts FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
CREATE TRIGGER personal_workout_exercise_structure_guard BEFORE INSERT OR UPDATE OR DELETE ON workout_exercises FOR EACH ROW EXECUTE FUNCTION guard_personal_program_structure();
