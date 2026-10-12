-- Число строк в каждой пользовательской таблице базы: «таблица число» на
-- строку. Один источник для манифеста бэкапа (backup.sh) и для сверки
-- восстановленной базы с манифестом (restore.sh). Только имена таблиц и
-- числа — содержимое строк в вывод не попадает.
SELECT format('%I.%I', table_schema, table_name) AS table_name,
       (xpath('/row/c/text()',
              query_to_xml(format('SELECT count(*) AS c FROM %I.%I', table_schema, table_name),
                           false, true, '')))[1]::text AS row_count
FROM information_schema.tables
WHERE table_type = 'BASE TABLE'
  AND table_schema NOT IN ('pg_catalog', 'information_schema')
ORDER BY 1;
