-- Frozen production migration 029 trigger definitions for restore regression coverage.
-- Every bump occurs in the same transaction as its prescription change.
-- Use BEFORE DELETE so child ownership is still available during cascade deletes.
CREATE OR REPLACE FUNCTION mobile_bump_user_workout_details(ids INTEGER[])
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    -- Deterministic lock order for changes affecting several executions.
    PERFORM id FROM user_workouts WHERE id = ANY(ids) ORDER BY id FOR UPDATE;
    UPDATE user_workouts SET detail_version = detail_version + 1 WHERE id = ANY(ids);
END;
$$;

CREATE OR REPLACE FUNCTION mobile_bump_workout_details(ids INTEGER[])
RETURNS VOID LANGUAGE plpgsql AS $$
BEGIN
    PERFORM mobile_bump_user_workout_details(ARRAY(
        SELECT id FROM user_workouts WHERE workout_id = ANY(ids) ORDER BY id
    ));
END;
$$;

CREATE OR REPLACE FUNCTION mobile_prescription_detail_changed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    old_id INTEGER;
    new_id INTEGER;
    ids INTEGER[];
BEGIN
    IF TG_TABLE_NAME = 'workout_exercises' THEN
        IF TG_OP = 'UPDATE' AND
           ROW(OLD.workout_id, OLD.exercise_id, OLD.sets, OLD.repetitions,
               OLD.rest_seconds, OLD.notes, OLD.order_index) IS NOT DISTINCT FROM
           ROW(NEW.workout_id, NEW.exercise_id, NEW.sets, NEW.repetitions,
               NEW.rest_seconds, NEW.notes, NEW.order_index) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.workout_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.workout_id; END IF;
        PERFORM mobile_bump_workout_details(ARRAY[old_id, new_id]);
    ELSIF TG_TABLE_NAME = 'user_workout_exercises' THEN
        IF TG_OP = 'UPDATE' AND
           ROW(OLD.user_workout_id, OLD.workout_exercise_id) IS NOT DISTINCT FROM
           ROW(NEW.user_workout_id, NEW.workout_exercise_id) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.user_workout_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.user_workout_id; END IF;
        PERFORM mobile_bump_user_workout_details(ARRAY[old_id, new_id]);
    ELSIF TG_TABLE_NAME = 'user_workout_exercise_sets' THEN
        IF TG_OP = 'UPDATE' AND
           ROW(OLD.user_workout_exercise_id, OLD.set_number, OLD.target_repetitions,
               OLD.target_weight_kg, OLD.rest_seconds) IS NOT DISTINCT FROM
           ROW(NEW.user_workout_exercise_id, NEW.set_number, NEW.target_repetitions,
               NEW.target_weight_kg, NEW.rest_seconds) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.user_workout_exercise_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.user_workout_exercise_id; END IF;
        SELECT ARRAY_AGG(DISTINCT user_workout_id) INTO ids
        FROM user_workout_exercises WHERE id = ANY(ARRAY[old_id, new_id]);
        PERFORM mobile_bump_user_workout_details(ids);
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;

CREATE TRIGGER trg_mobile_workout_prescription
BEFORE INSERT OR UPDATE OR DELETE ON workout_exercises
FOR EACH ROW EXECUTE FUNCTION mobile_prescription_detail_changed();
CREATE TRIGGER trg_mobile_user_workout_exercise
BEFORE INSERT OR UPDATE OR DELETE ON user_workout_exercises
FOR EACH ROW EXECUTE FUNCTION mobile_prescription_detail_changed();
CREATE TRIGGER trg_mobile_user_workout_set
BEFORE INSERT OR UPDATE OR DELETE ON user_workout_exercise_sets
FOR EACH ROW EXECUTE FUNCTION mobile_prescription_detail_changed();

CREATE OR REPLACE FUNCTION mobile_user_workout_reference_changed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
BEGIN
    IF ROW(OLD.workout_id, OLD.program_workout_id, OLD.program_id) IS DISTINCT FROM
       ROW(NEW.workout_id, NEW.program_workout_id, NEW.program_id) THEN
        NEW.detail_version := OLD.detail_version + 1;
    END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_mobile_user_workout_reference
BEFORE UPDATE OF workout_id, program_workout_id, program_id ON user_workouts
FOR EACH ROW EXECUTE FUNCTION mobile_user_workout_reference_changed();

CREATE OR REPLACE FUNCTION mobile_detail_metadata_changed()
RETURNS TRIGGER LANGUAGE plpgsql AS $$
DECLARE
    old_id INTEGER;
    new_id INTEGER;
BEGIN
    IF TG_TABLE_NAME = 'workouts' THEN
        IF ROW(OLD.duration_minutes, OLD.intensity_level) IS DISTINCT FROM
           ROW(NEW.duration_minutes, NEW.intensity_level) THEN
            PERFORM mobile_bump_workout_details(ARRAY[NEW.id]);
        END IF;
    ELSIF TG_TABLE_NAME = 'workout_translations' THEN
        IF TG_OP = 'UPDATE' AND
           ROW(OLD.workout_id, OLD.language_id, OLD.name, OLD.description) IS NOT DISTINCT FROM
           ROW(NEW.workout_id, NEW.language_id, NEW.name, NEW.description) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.workout_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.workout_id; END IF;
        PERFORM mobile_bump_workout_details(ARRAY[old_id, new_id]);
    ELSIF TG_TABLE_NAME = 'program_workouts' THEN
        IF TG_OP = 'UPDATE' AND ROW(OLD.program_id, OLD.workout_id, OLD.day_index) IS NOT DISTINCT FROM
           ROW(NEW.program_id, NEW.workout_id, NEW.day_index) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.program_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.program_id; END IF;
        -- day/order changes can affect siblings' orderIndex in the detail response.
        PERFORM mobile_bump_user_workout_details(ARRAY(
            SELECT id FROM user_workouts WHERE program_id = ANY(ARRAY[old_id, new_id])
        ));
    ELSIF TG_TABLE_NAME = 'exercises' THEN
        IF OLD.mobile_exercise_key IS DISTINCT FROM NEW.mobile_exercise_key OR
           (NEW.mobile_exercise_key IS NULL AND OLD.image_url IS DISTINCT FROM NEW.image_url) THEN
            PERFORM mobile_bump_workout_details(ARRAY(
                SELECT DISTINCT workout_id FROM workout_exercises WHERE exercise_id = NEW.id
            ));
        END IF;
    ELSIF TG_TABLE_NAME = 'exercise_translations' THEN
        IF TG_OP = 'UPDATE' AND ROW(OLD.exercise_id, OLD.language_id, OLD.name, OLD.description) IS NOT DISTINCT FROM
           ROW(NEW.exercise_id, NEW.language_id, NEW.name, NEW.description) THEN RETURN NEW; END IF;
        IF TG_OP <> 'INSERT' THEN old_id := OLD.exercise_id; END IF;
        IF TG_OP <> 'DELETE' THEN new_id := NEW.exercise_id; END IF;
        PERFORM mobile_bump_workout_details(ARRAY(
            SELECT DISTINCT we.workout_id FROM workout_exercises we
            JOIN exercises e ON e.id = we.exercise_id
            WHERE e.id = ANY(ARRAY[old_id, new_id]) AND e.mobile_exercise_key IS NULL
        ));
    END IF;
    IF TG_OP = 'DELETE' THEN RETURN OLD; END IF;
    RETURN NEW;
END;
$$;
CREATE TRIGGER trg_mobile_workout_metadata
BEFORE UPDATE OF duration_minutes, intensity_level ON workouts
FOR EACH ROW EXECUTE FUNCTION mobile_detail_metadata_changed();
CREATE TRIGGER trg_mobile_workout_translation
BEFORE INSERT OR UPDATE OR DELETE ON workout_translations
FOR EACH ROW EXECUTE FUNCTION mobile_detail_metadata_changed();
CREATE TRIGGER trg_mobile_program_workout
BEFORE INSERT OR UPDATE OR DELETE ON program_workouts
FOR EACH ROW EXECUTE FUNCTION mobile_detail_metadata_changed();
CREATE TRIGGER trg_mobile_exercise_metadata
BEFORE UPDATE OF mobile_exercise_key, image_url ON exercises
FOR EACH ROW EXECUTE FUNCTION mobile_detail_metadata_changed();
CREATE TRIGGER trg_mobile_exercise_translation
BEFORE INSERT OR UPDATE OR DELETE ON exercise_translations
FOR EACH ROW EXECUTE FUNCTION mobile_detail_metadata_changed();
