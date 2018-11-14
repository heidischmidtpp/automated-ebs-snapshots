select now();
STOP SLAVE;
SHOW MASTER STATUS;
SHOW SLAVE STATUS \G
SET GLOBAL innodb_max_dirty_pages_pct=0;
SET GLOBAL innodb_buffer_pool_dump_at_shutdown=OFF;
