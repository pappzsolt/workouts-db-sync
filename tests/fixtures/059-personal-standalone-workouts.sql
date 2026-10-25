-- Explicit marker: existing one-day programs retain their original semantics.
CREATE TABLE personal_standalone_workouts (
    program_id integer PRIMARY KEY REFERENCES personal_program_owners(program_id) ON DELETE CASCADE,
    source_program_id integer REFERENCES personal_program_owners(program_id) ON DELETE SET NULL,
    created_at timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP
);
CREATE INDEX idx_personal_standalone_source ON personal_standalone_workouts(source_program_id);
