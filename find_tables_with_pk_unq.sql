SELECT R.oid::regclass AS relname,
         PK.indexrelid::regclass AS pkid
 FROM pg_class R
         LEFT JOIN pg_class T ON R.reltoastrelid = T.oid
         LEFT JOIN 
( SELECT indrelid, indexrelid FROM pg_index
   WHERE indisunique
     AND indisvalid
     AND indpred IS NULL
     AND 0 <> ALL(indkey)
     AND NOT EXISTS(
           SELECT 1 FROM pg_attribute
            WHERE attrelid = indrelid
              AND attnum = ANY(indkey)
              AND NOT attnotnull) 
  ) as PK ON R.oid = PK.indrelid
 LEFT JOIN pg_namespace N ON N.oid = R.relnamespace
 WHERE R.relkind = 'r'
     AND N.nspname NOT IN ('pg_catalog', 'information_schema')
     AND N.nspname NOT LIKE E'pg\\_temp\\_%';
