SELECT (SELECT count(*) FROM public.users),
       (SELECT count(*) FROM public.workouts),
       (SELECT count(*) FROM public.exercises),
       (SELECT count(*) FROM public.databasechangelog);
