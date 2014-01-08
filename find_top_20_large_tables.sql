SELECT nspname || '.' || relname AS "relation",
    pg_size_pretty(pg_relation_size(C.oid)) AS "size"
  FROM pg_class C
  LEFT JOIN pg_namespace N ON (N.oid = C.relnamespace)
  WHERE 
   C.relkind='r' AND nspname NOT IN ('pg_catalog', 'information_schema')
    AND N.nspname NOT LIKE E'pg\\_temp\\_%'
  ORDER BY pg_relation_size(C.oid) DESC
  LIMIT 20;
