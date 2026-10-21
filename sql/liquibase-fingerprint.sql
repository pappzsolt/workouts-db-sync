SELECT md5(coalesce(string_agg(row_to_json(t)::text, E'\n'
                             ORDER BY t.orderexecuted, t.id, t.author), ''))
FROM public.databasechangelog t;
