-- Preserve the source snapshot after INSERT triggers bump versions during bulk import.
-- UPDATE of detail_version alone does not fire reference/prescription triggers.
SELECT format('UPDATE public.user_workouts SET detail_version = %L::bigint WHERE id = %L::integer;', detail_version, id)
FROM public.user_workouts
ORDER BY id;
