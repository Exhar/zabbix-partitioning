#!/bin/bash
#
# This script will partition your zabbix database to improve the efficiency.
# It will also create stored procedures to do the necessary housekeeping,
# and create a cronjob to do this on a daily basis
#
# This script inspired by the following:
#       http://zabbixzone.com/zabbix/partitioning-tables/
#
# While the basic SQL is from the above page, this script both creates the necessary 
# SQL for the desired tables, and can create new partitions as the time goes on
# assuming that the cronjob has been properly entered.
#


function usage {
cat <<_EOF_

$0      [-h host][-u user][-p password][-d min_days][-y startyear]

        -h host         database host
        -u user         db user
        -p password     user password
        -d min_days     Minimum number of days of history to keep
        -m min_months   Minimum number of months to keep trends
        -y startyear    First year to set up with partitions


After running this script, don't forget to disable housekeeping if
you didn't have the script disable it, and add the following cronjob

        ### Option: DisableHousekeeping
        #       If set to 1, disables housekeeping.
        #
        # Mandatory: no
        # Range: 0-1
        ################### Uncomment and change the following line to 1 in 
        ################### Then restart the zabbix server
        DisableHousekeeping=1


Cron job

0 0 * * *  /etc/zabbix/cron.d/housekeeping.sh


_EOF_
        exit
}

SQL="/tmp/partition.sql"

#
# How long to keep the daily history
#
daily_history_min=90

#
# How long to keep the monthly history (months)
#
monthy_history_min=12

#
# Years to create the monthly partitions for
#
first_year=`date +"%Y"`
last_year=$first_year
cur_month=`date +"%m"`
if [ $cur_month -eq 12 ]; then
        last_year=$((first_year+1))
        cur_month=1
fi

y=`date +"%Y"`

DUMP_FILE=/tmp/zabbix.sql
DBHOST=localhost
DBUSER=root
DBPASS=
while getopts "m:h:u:p:d:y:?h" flag; do
        case $flag in
                h)      DBHOST=$OPTARG ;;
                u)      DBUSER=$OPTARG ;;
                p)      DBPASS=$OPTARG ;;
                d)      h=$OPTARG
                        if [ $h -gt 0 ] 2>/dev/null; then
                                daily_history_min=$h
                        else
                                echo "Invalid daily history min, exiting"
                                exit 1
                        fi
                        ;;
                m)      h=$OPTARG
                        if [ $h -gt 0 ] 2>/dev/null; then
                                monthy_history_min=$h
                        else
                                echo "Invalid monthly history min, exiting"
                                exit 1
                        fi
                        ;;

                y)      yy=$OPTARG
                        if [ $yy -lt $y -a $yy -gt 2000 ] 2>/dev/null; then
                                first_year=$yy
                        else
                                echo "Invalid year, exiting"
                                exit 1
                        fi
                        ;;
                ?|h)    usage ;;
        esac
done
shift $((OPTIND-1))

echo "Ready to partition tables."

echo -e "\nReady to update permissions of Zabbix user to create routines\n"
echo -n "Enter root DB user: "
read DBADMINUSER
echo -n "Enter $DBADMINUSER password: "
read DBADMINPASS
mysql -B -h localhost -u $DBADMINUSER -p$DBADMINPASS -e "GRANT CREATE ROUTINE ON zabbix.* TO 'zabbix'@'localhost';"
echo -e "\n"

        DUMP_FILE=$df

        #
        # Lock tables is needed for a good mysqldump
        #
        echo "GRANT LOCK TABLES ON zabbix.* TO '${DBUSER}'@'${DBHOST}' IDENTIFIED BY '${DBPASS}';" | mysql -h${DBHOST} -u${DBADMINUSER} --password=${DBADMINPASS}

        mysqldump --opt -h ${DBHOST} -u ${DBUSER} -p${DBPASS} zabbix --result-file=${DUMP_FILE}
        rc=$?
        if [ $rc -ne 0 ]; then
                echo "Error during mysqldump, rc: $rc"
                echo "Do you wish to continue (y/N): "
                read yn
                [ "yn" != "y" -a "$yn" != "Y" ] && exit
        else
                echo "Mysqldump succeeded!, proceeding with upgrade..."
        fi
echo -e "\n\nReady to proceed:"

echo -e "\nStarting yearly partioning at: $first_year"
echo "and ending at: $last_year"
echo "With $daily_history_min days of daily history"


DAILY="history history_log history_str history_text history_uint"
DAILY_IDS="itemid id itemid id itemid"

MONTHLY="acknowledges alerts auditlog events service_alarms"
MONTHLY_IDS="acknowledgeid alertid auditid eventid servicealarmid"

TABLES="$DAILY $MONTHLY"
IDS="$DAILY_IDS $MONTHLY_IDS"

CONSTRAINT_TABLES="acknowledges alerts auditlog service_alarms auditlog_details"
CONSTRAINTS="c_acknowledges_1/c_acknowledges_2 c_alerts_1/c_alerts_2/c_alerts_3/c_alerts_4 c_auditlog_1 c_service_alarms_1 c_auditlog_details_1"

echo "Use zabbix;  SELECT 'Altering tables';" >$SQL

cnt=0
for i in $CONSTRAINT_TABLES; do
        cnt=$(($cnt+1))
        for constraint in $(echo $CONSTRAINTS |cut -f$cnt -d" " |awk -F/ '{for (i=1; i <= NF; i++) {if ($i != "") {print $i}}}'); do
                echo "ALTER TABLE $i DROP FOREIGN KEY $constraint;" >>$SQL
        done
done

cnt=0
for i in $TABLES; do
        echo "Altering table: $i"
        echo "SELECT '$i';" >>$SQL
        cnt=$((cnt+1))
        case $i in
                history_log)
                        echo "ALTER TABLE $i DROP KEY history_log_2;" >>$SQL
                        echo "ALTER TABLE $i ADD KEY history_log_2(itemid, id);" >>$SQL
                        id=`echo $IDS | cut -f$cnt -d" "`
                        echo "ALTER TABLE $i DROP PRIMARY KEY, ADD KEY ${i}id ($id);" >>$SQL
                        ;;
                history_text)
                        echo "ALTER TABLE $i DROP KEY history_text_2;" >>$SQL
                        echo "ALTER TABLE $i ADD KEY history_text_2 (itemid, clock);" >>$SQL
                        id=`echo $IDS | cut -f$cnt -d" "`
                        echo "ALTER TABLE $i DROP PRIMARY KEY, ADD KEY ${i}id ($id);" >>$SQL
                        ;;

                acknowledges|alerts|auditlog|events|service_alarms)
                        id=`echo $IDS | cut -f$cnt -d" "`
                        echo "ALTER TABLE $i DROP PRIMARY KEY, ADD KEY ${i}id ($id);" >>$SQL
                        ;;
        esac
done
echo -en "\n"
echo -en "\n" >>$SQL
for i in $MONTHLY; do
        echo "Creating monthly partitions for table: $i"
        echo "SELECT '$i';" >>$SQL
        echo "ALTER TABLE $i PARTITION BY RANGE( clock ) (" >>$SQL
        for y in `seq $first_year $last_year`; do
                last_month=12
                [ $y -eq $last_year ] && last_month=$((cur_month+1))
                for m in `seq 1 $last_month`; do
                        [ $m -lt 10 ] && m="0$m"
                        pname="p${y}${m}"
                        echo -n "PARTITION $pname  VALUES LESS THAN (UNIX_TIMESTAMP(\"$y-$m-01 00:00:00\"))" >>$SQL
                        [ $m -ne $last_month -o $y -ne $last_year ] && echo -n "," >>$SQL
                        echo -ne "\n" >>$SQL
                done
        done
        echo ");" >>$SQL
done

echo -en "\n"
for i in $DAILY; do
        echo "Creating daily partitions for table: $i"
        echo "SELECT '$i';" >>$SQL
        echo "ALTER TABLE $i PARTITION BY RANGE( clock ) (" >>$SQL
        for d in `seq -$daily_history_min 2`; do
                ds=`date +"%Y-%m-%d" -d "$d day"`
                pname=`date +"%Y%m%d" -d "$d day"`
                echo -n "PARTITION p$pname  VALUES LESS THAN (UNIX_TIMESTAMP(\"$ds 00:00:00\"))" >>$SQL
                [ $d -ne 2 ] && echo -n "," >>$SQL
                echo -ne "\n" >>$SQL
        done
        echo ");" >>$SQL
done



###############################################################
cat >>$SQL <<_EOF_
SELECT "Installing procedures";

/**************************************************************
  MySQL Auto Partitioning Procedure for Zabbix 1.8
  http://zabbixzone.com/zabbix/partitioning-tables/

  Author:  Ricardo Santos (rsantos at gmail.com)
  Version: 20110518
**************************************************************/
DELIMITER //
DROP PROCEDURE IF EXISTS zabbix.create_zabbix_partitions; //
CREATE PROCEDURE zabbix.create_zabbix_partitions ()
BEGIN
_EOF_

###############################################################

for i in $DAILY; do
        echo "  CALL zabbix.create_next_partitions(\"zabbix\",\"$i\");" >>$SQL
        echo "  CALL zabbix.drop_old_partitions(\"zabbix\",\"$i\");" >>$SQL
done
echo -en "\n" >>$SQL
for i in $MONTHLY; do
        echo "  CALL zabbix.create_next_monthly_partitions(\"zabbix\",\"$i\");" >>$SQL
        echo "  CALL zabbix.drop_old_monthly_partitions(\"zabbix\",\"$i\");" >>$SQL
done

###############################################################
cat >>$SQL <<_EOF_
END //

DROP PROCEDURE IF EXISTS zabbix.create_next_partitions; //
CREATE PROCEDURE zabbix.create_next_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
        DECLARE NEXTCLOCK timestamp;
        DECLARE PARTITIONNAME varchar(16);
        DECLARE CLOCK int;
        SET @totaldays = 7;
        SET @i = 1;
        createloop: LOOP
                SET NEXTCLOCK = DATE_ADD(NOW(),INTERVAL @i DAY);
                SET PARTITIONNAME = DATE_FORMAT( NEXTCLOCK, 'p%Y%m%d' );
                SET CLOCK = UNIX_TIMESTAMP(DATE_FORMAT(DATE_ADD( NEXTCLOCK ,INTERVAL 1 DAY),'%Y-%m-%d 00:00:00'));
                CALL zabbix.create_partition( SCHEMANAME, TABLENAME, PARTITIONNAME, CLOCK );
                SET @i=@i+1;
                IF @i > @totaldays THEN
                        LEAVE createloop;
                END IF;
        END LOOP;
END //


DROP PROCEDURE IF EXISTS zabbix.drop_old_partitions; //
CREATE PROCEDURE zabbix.drop_old_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
        DECLARE OLDCLOCK timestamp;
        DECLARE PARTITIONNAME varchar(16);
        DECLARE CLOCK int;
        SET @mindays = $daily_history_min;
        SET @maxdays = @mindays+4;
        SET @i = @maxdays;
        droploop: LOOP
                SET OLDCLOCK = DATE_SUB(NOW(),INTERVAL @i DAY);
                SET PARTITIONNAME = DATE_FORMAT( OLDCLOCK, 'p%Y%m%d' );
                CALL zabbix.drop_partition( SCHEMANAME, TABLENAME, PARTITIONNAME );
                SET @i=@i-1;
                IF @i <= @mindays THEN
                        LEAVE droploop;
                END IF;
        END LOOP;
END //

DROP PROCEDURE IF EXISTS zabbix.create_next_monthly_partitions; //
CREATE PROCEDURE zabbix.create_next_monthly_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
        DECLARE NEXTCLOCK timestamp;
        DECLARE PARTITIONNAME varchar(16);
        DECLARE CLOCK int;
        SET NEXTCLOCK = DATE_ADD(NOW(),INTERVAL @i MONTH);
        SET PARTITIONNAME = DATE_FORMAT( NEXTCLOCK, 'p%Y%m' );
        SET CLOCK = UNIX_TIMESTAMP(DATE_FORMAT(DATE_ADD( NEXTCLOCK ,INTERVAL 1 MONTH),'%Y-%m-01 00:00:00'));
        CALL zabbix.create_partition( SCHEMANAME, TABLENAME, PARTITIONNAME, CLOCK );
END //

DROP PROCEDURE IF EXISTS zabbix.drop_old_monthly_partitions; //
CREATE PROCEDURE zabbix.drop_old_monthly_partitions (SCHEMANAME varchar(64), TABLENAME varchar(64))
BEGIN
        DECLARE OLDCLOCK timestamp;
        DECLARE PARTITIONNAME varchar(16);
        DECLARE CLOCK int;
        SET @minmonths = $monthy_history_min;
        SET @maxmonths = @minmonths+24;
        SET @i = @maxmonths;
        droploop: LOOP
                SET OLDCLOCK = DATE_SUB(NOW(),INTERVAL @i MONTH);
                SET PARTITIONNAME = DATE_FORMAT( OLDCLOCK, 'p%Y%m' );
                CALL zabbix.drop_partition( SCHEMANAME, TABLENAME, PARTITIONNAME );
                SET @i=@i-1;
                IF @i <= @minmonths THEN
                        LEAVE droploop;
                END IF;
        END LOOP;
END //

DROP PROCEDURE IF EXISTS zabbix.create_partition; //
CREATE PROCEDURE zabbix.create_partition (SCHEMANAME varchar(64), TABLENAME varchar(64), PARTITIONNAME varchar(64), CLOCK int)
BEGIN
        DECLARE RETROWS int;
        SELECT COUNT(1) INTO RETROWS
                FROM information_schema.partitions
                WHERE table_schema = SCHEMANAME AND table_name = TABLENAME AND partition_name = PARTITIONNAME;

        IF RETROWS = 0 THEN
                SELECT CONCAT( "create_partition(", SCHEMANAME, ",", TABLENAME, ",", PARTITIONNAME, ",", CLOCK, ")" ) AS msg;
                SET @sql = CONCAT( 'ALTER TABLE ', SCHEMANAME, '.', TABLENAME, 
                                ' ADD PARTITION (PARTITION ', PARTITIONNAME, ' VALUES LESS THAN (', CLOCK, '));' );
                PREPARE STMT FROM @sql;
                EXECUTE STMT;
                DEALLOCATE PREPARE STMT;
        END IF;
END //

DROP PROCEDURE IF EXISTS zabbix.drop_partition; //
CREATE PROCEDURE zabbix.drop_partition (SCHEMANAME varchar(64), TABLENAME varchar(64), PARTITIONNAME varchar(64))
BEGIN
        DECLARE RETROWS int;
        SELECT COUNT(1) INTO RETROWS
                FROM information_schema.partitions
                WHERE table_schema = SCHEMANAME AND table_name = TABLENAME AND partition_name = PARTITIONNAME;

        IF RETROWS = 1 THEN
                SELECT CONCAT( "drop_partition(", SCHEMANAME, ",", TABLENAME, ",", PARTITIONNAME, ")" ) AS msg;
                SET @sql = CONCAT( 'ALTER TABLE ', SCHEMANAME, '.', TABLENAME,
                                ' DROP PARTITION ', PARTITIONNAME, ';' );
                PREPARE STMT FROM @sql;
                EXECUTE STMT;
                DEALLOCATE PREPARE STMT;
        END IF;
END //
DELIMITER ;
_EOF_

        echo -en "\nProceeding, please wait.  This may take a while\n\n"
        mysql --skip-column-names -h ${DBHOST} -u ${DBUSER} -p${DBPASS} <$SQL

conf=/etc/zabbix/zabbix_server.conf
echo -e "\nDo you want to update the /etc/zabbix/zabbix_server.conf"
echo -n "to disable housekeeping (Y/n): "
        cp $conf ${conf}.bak
        sed  -i "s/^# DisableHousekeeping=0/DisableHousekeeping=1/" $conf
        sed  -i "s/^DisableHousekeeping=0/DisableHousekeeping=1/" $conf
        /etc/init.d/zabbix-server stop
        sleep 5
        /etc/init.d/zabbix-server start

tmpfile=/tmp/cron$$
        where=
        while [ "$where" = "" ]; do
                echo "The crontab entry can be either in /etc/cron.daily, or added"
                echo -e "to the crontab for root\n"
                echo -n "Do you want to add this to the /etc/cron.daily directory (Y/n): "
                read where
                [ "$where" = "" -o "$where" = "y" ] && where="Y"
                if [ "$where" != "y" -a "$where" != "Y" -a "$where" != "n" -a "$where" != "N" ]; then
                        where=""
                        echo "Response not recognized, please try again"
                fi
        done

        mailto=root
        mkdir -p /etc/zabbix/cron.d
        cat >/etc/zabbix/cron.d/housekeeping.sh <<_EOF_
#!/bin/bash

MAILTO=$mailto
tmpfile=/tmp/housekeeping\$\$

date >\$tmpfile
/usr/bin/mysql --skip-column-names -B -h localhost -u zabbix -pzabbix zabbix -e "CALL create_zabbix_partitions();" >>\$tmpfile 2>&1
/bin/mail -s "Zabbix MySql Partition Housekeeping" \$MAILTO <\$tmpfile
rm -f \$tmpfile
_EOF_
        chmod +x /etc/zabbix/cron.d/housekeeping.sh
        chown -R zabbix.zabbix /etc/zabbix
        if [ "$where" = "Y" ]; then
                cat >/etc/cron.daily/zabbix.housekeeping <<_EOF_
#!/bin/bash
/etc/zabbix/cron.d/housekeeping.sh
_EOF_
                chmod +x /etc/cron.daily/zabbix.housekeeping
        else
                crontab -l >$tmpfile
                cat >>$tmpfile <<_EOF_
0 0 * * *  /etc/zabbix/cron.d/housekeeping.sh
_EOF_
                crontab $tmpfile
                rm $tmpfile
        fi
fi
