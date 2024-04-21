SELECT
	c.oid,
	c.relname,
	c.relpages,
	c.reltuples,
	v.*
FROM
	pg_class c,
	lateral verify_heapam(relation => c.oid, on_error_stop => false,
		check_toast => true,
		skip => 'none',
		startblock => NULL,
		endblock => NULL) AS v
WHERE relkind = 'r';
