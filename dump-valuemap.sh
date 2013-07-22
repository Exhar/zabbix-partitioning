#!/bin/bash

/usr/bin/mysqldump -uroot -p`cat /etc/mysql.passwd` zabbix valuemaps > valuemaps.export.sql && 
/usr/bin/mysqldump -uroot -p`cat /etc/mysql.passwd` zabbix mappings > mappings.export.sql
