#!/bin/sh
#########################################
# Author: Heidi E. Schmidt hschmidt@patientping.com
#########################################
# Context: 
#  Script starting point: https://pastebin.com/f5ec2f70d
#  Blog Source: https://www.percona.com/blog/2009/04/15/how-to-decrease-innodb-shutdown-times/
# 
#  Python script source: https://pypi.org/project/automated-ebs-snapshots/
#			 git clone https://github.com/skymill/automated-ebs-snapshots.git
#  PIP Install method: pip install automated-ebs-snapshots
#
# Requirements: 
#  yum install -y jq 
#  pip install automated-ebs-snapshots 
#  git clone from our PP repo the fork made and modded 
#  mysql login path variable -- https://dev.mysql.com/doc/refman/5.7/en/mysql-config-editor.html
#  
#########################################


#########################################
#
# Settings for scripts, vars, and log files 
#
#########################################
HOME="/root"
MYSQL_TEST_LOGIN_FILE="/root/.mylogin.cnf"
filename=`basename $0`
mysql_login_path="mysql --login-path=local "
db_pwd=`grep THEMYSQLPASS /root/mysql.cfg | cut -f2 -d "="`
BINLOG_COORDS_FILE="/db1/mysql/log/ebs-snapshot-db1.log"
SNAPSHOT_LOG="/var/log/ebs-snapshot.log"
RELAY_FILE="/db1/mysql/data/relay-log.info"
DRAIN_FILE="/tmp/drainfile" 
MYSQL_PID_FILE="/var/run/mysqld/mysqld.pid"
MYSQL_ERROR_LOG="/db1/mysql/log/error.log"
python_esb_script="/files/scripts/automated-ebs-snapshots/automated-ebs-snapshots"
DRAIN_SQL="/files/scripts/drain-db.sql"
REPLICATION_STATUS_SQL="/files/scripts/replication_status.sql"
REPLICATION_STATUS_FILE="/files/scripts/replication_status.log"
REPLICATION_START_SQL="/files/scripts/replication_start.sql"
REPLICATION_START_LOG="/files/scripts/replication_start.log"

#########################################
#
#  Checks and balances 
#  IF we DO not have a VOLUME ID, then 
#  DO NOT PROCEED 
#
#########################################
	DATA_VOL_ID=$(aws ec2 --region us-east-1 describe-volumes --filters Name=attachment.instance-id,Values=`curl -s http://169.254.169.254/latest/meta-data/instance-id` Name=attachment.device,Values='/dev/xvdf' | jq '.Volumes[0].Attachments[0].VolumeId' | sed s/\"//g)

	if ! [ -x "$(command -v jq)" ]; then
		echo 'Error: jq is not installed.' >&2
		echo "Installing jq on server ${HOSTNAME} for script ${filename} dependencies"
		yum install -y jq 
        else 
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"FAILURE: JQ not installed ${HOSTNAME}.\"  }" 2>> ${SNAPSHOT_LOG}
		
	fi

	if [ -z ${DATA_VOL_ID} ]
	then 
		echo "No MySQL EBS data volume defined for the host. Exiting"
		echo "The command failed to return the data volume id : aws ec2 --region us-east-1 describe-volumes --filters Name=attachment.instance-id,Values=`curl -s http://169.254.169.254/latest/meta-data/instance-id` Name=attachment.device,Values='/dev/xvdf' | jq '.Volumes[0].Attachments[0].VolumeId' | sed s/\"//g" 
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"FAILURE: AWS EC2 volume id not found.\" }" >> ${SNAPSHOT_LOG}
		exit
	else 
		echo "Registered the ${DATA_VOL_ID} with the Automated EBS Snapshot Python script"
		python ${python_esb_script} --watch ${DATA_VOL_ID} --interval hourly --retention 7
		echo "MySQL data volume ${DATA_VOL_ID} is registered" 
	fi 

#########################################
#
# Call the given function wrapper to mysql client, 
#      require that it complete successfully, 
#      and then return the status if error.
#
#########################################
rcall() {

    echo -n '+'
    echo -n $@

    $@

    status=$?

    if [ ${status} != 0 ]; then
        echo "Script ${basename} FAILED - with: "
        exit ${status}
    fi

    echo

    return ${status}

}


#########################################
# 
# Functions to be called in CASE statement 
# These wrap the logic of steps to EBS snapshot 
#
#########################################

register_data_volume () {
	#########################################
	#  This is self setup/self discovery  
	#  If there are no volumes to watch, find it  
	#  and watch it aka register it with python script 
	#########################################
	python ${python_esb_script} --watch ${DATA_VOL_ID} --interval daily
}

do_relay_check () {
	if [ -e ${RELAY_FILE} ]
	then
		echo "Replica Relay Log File exists: "
		ls -ltra ${RELAY_FILE}
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Proceeding with snapshot backup for data volume ${DATA_VOL_ID}. The file ${RELAY_FILE} exists and ${HOSTNAME} is a replica\" }"  >> ${SNAPSHOT_LOG}
		echo "Proceeding with EBS snapshot for ${HOSTNAME}"
	else
		echo "${RELAY_FILE} does not exist. This server ${HOSTNAME} is a main, not a replica. Exiting"
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"This is a Main MySQL db server. The replication file ${RELAY_FILE} does not exist for ${HOSTNAME} and we DON'T want a db shutdown to create a quiesced filesystem snapshot\" }"  >> ${SNAPSHOT_LOG}
		exit 0
	fi
} 

do_drain_db () {
	#########################################
	# Tell mysql that we need to shutdown so start flushing dirty pages to disk.
	# Normally InnoDB does this by itself but only when port 3306 is closed which
	# prevents us from monitoring the box.
	#########################################
	
	echo "Stopping replication and setting global variables before any backup : "
	
	#########################################
	# Reset the binary log coordinates file so it is zero length 
	# So it can be populated and snapshot with current info for each snapshot
	#########################################
	cat /dev/null > ${BINLOG_COORDS_FILE}
	touch ${DRAIN_FILE}
        sleep 5
	rcall ${mysql_login_path} -vvv < ${DRAIN_SQL} > ${BINLOG_COORDS_FILE} 
	echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Replication stopped on ${HOSTNAME} and temp global settings for buffers set.\" }" >> ${SNAPSHOT_LOG}
}

do_db_shutdown () {
	#########################################
	# 
	# For determining if a server is a REPLICA
	# If the relay.info does not exist. 
	# DO NOT PROCEED WITH DB SHUTDOWN !!! 
	#
	#########################################

	echo "DB Shutdown & EBS Snapshot after flushing Innodb dirty pages : "
	if [ ${SNAPSHOT_LOG} -nt ${DRAIN_FILE} ]; then
		while [ true ]; do
			status=$(mysqladmin -u root -p${db_pwd}  ext  | grep dirty)
			Innodb_buffer_pool_pages_dirty=$(echo $status | grep Innodb_buffer_pool_pages_dirty | awk '{ print $4 }')  
			Innodb_buffer_pool_bytes_dirty=$(echo $status | grep Innodb_buffer_pool_bytes_dirty | awk '{ print $4 }')
			if [ ${Innodb_buffer_pool_pages_dirty} == "0" ] && [ ${Innodb_buffer_pool_bytes_dirty} == "0" ]; then
				echo "Modified db pages at 0 on `date` " >> ${BINLOG_COORDS_FILE}
				echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Replication stopped and innodb dirty buffers at 0 for db on ${HOSTNAME}.\" }"   >> ${SNAPSHOT_LOG}
				service mysqld stop
				wait 
				echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Stopping db on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
				sync 
				echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Freezing MySQL data filesystem on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
				fsfreeze -f /db1
				python ${python_esb_script} --run_one_vol ${DATA_VOL_ID}
				echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Snapshot created for ${DATA_VOL_ID} on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
				fsfreeze -u /db1
				echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Un-Freezing MySQL data filesystem on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
				break
			fi
			echo -ne "${status}\r";
			sleep 1
		done
		Master_Log_File=$(grep " Master_Log_File:" ${BINLOG_COORDS_FILE} | awk '{ print $2 }')
		Read_Master_Log_Pos=$(grep " Read_Master_Log_Pos:" ${BINLOG_COORDS_FILE} | awk '{ print $2 }')
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Binary log positions Master_Log_File position: ${Master_Log_File} and Read_Master_Log_Pos position: ${Read_Master_Log_Pos} for ${DATA_VOL_ID} on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Completed snapshot backup for data volume ${DATA_VOL_ID} on ${HOSTNAME}. \" }"  >> ${SNAPSHOT_LOG}
	fi
}

do_db_restart () {
	#########################################
	#  Mysql login path is needed to avoid having passwords in logs 
	#  Using mysql login path makes output into one line vs multi line 
	#  And passing it commands to execute -- they get mis parsed in script vs cmd line
	#  So each step of starting and checking replication is being passed as a script 
	#########################################
	#if [ -s /tmp/foople ]
	if [ -s ${MYSQL_PID_FILE} ]
	then 
		PID=$(cat ${MYSQL_PID_FILE})
		echo "MySQL db is running as process id : ${PID}"
	else	
		echo "Restart MySQL DB & replication after MySQL stop"
		service mysqld start 
		wait
            	rcall ${mysql_login_path} -vvv < ${REPLICATION_START_SQL} > ${REPLICATION_START_LOG} 
		echo "Replication status : "
		echo "====================="
		echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Restarting MySQL Replication on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
	    	rcall ${mysql_login_path} -vvv < ${REPLICATION_STATUS_SQL} > ${REPLICATION_STATUS_FILE} 
	    	Slave_IO_Running=$(grep "Slave_IO_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	    	Slave_SQL_Running=$(grep "Slave_SQL_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	    	Last_error=$(grep "Last_error:" ${REPLICATION_STATUS_FILE} | awk -F : '{ print $2 }')
            	echo "Statuses are: " 
	    	echo ${Slave_IO_Running}
	    	echo ${Slave_SQL_Running}
	    	echo ${Last_error}
	fi 
}

do_replication_check () {
	#########################################
	#  Mysql login path is needed to avoid having passwords in logs 
	#  Using mysql login path makes output into one line vs multi line 
	#  And passing it commands to execute -- they get mis parsed in script vs cmd line
	#  So each step of starting and checking replication is being passed as a script 
	#########################################
	rcall ${mysql_login_path} -vvv < ${REPLICATION_STATUS_SQL} > ${REPLICATION_STATUS_FILE} 

	Slave_IO_Running=$(grep "Slave_IO_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	Slave_SQL_Running=$(grep "Slave_SQL_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	Last_error=$(grep "Last_error:" ${REPLICATION_STATUS_FILE} | awk -F : '{ print $2 }')
	echo ${Slave_IO_Running}
	echo ${Slave_SQL_Running}
	echo ${Last_error}


	if [ ${Slave_SQL_Running} == 'No' ] || [ ${Slave_IO_Running} == 'No' ];
	then
	    echo "Replication status : "
	    echo "====================="
	    echo "Last Error:" ${Last_error} "Last Replication error on replica ${HOSTNAME} !!!"
	    echo "Slave_IO_Running: is  ${Slave_IO_Running}  on ${HOSTNAME} !!!"
	    echo "Slave_SQL_Running: is  ${Slave_SQL_Running}  on ${HOSTNAME} !!!"
            echo "Starting replication ====================================="
	    echo  "{ \"date\":\"$(date)\", \"script\":\"${filename}\", \"status\":\"Restarting MySQL Replication on ${HOSTNAME}.\" }"  >> ${SNAPSHOT_LOG}
            rcall ${mysql_login_path} -vvv < ${REPLICATION_START_SQL} > ${REPLICATION_START_LOG} 
	    sleep 5
	    rcall ${mysql_login_path} -vvv < ${REPLICATION_STATUS_SQL} > ${REPLICATION_STATUS_FILE} 
	    Slave_IO_Running=$(grep "Slave_IO_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	    Slave_SQL_Running=$(grep "Slave_SQL_Running:" ${REPLICATION_STATUS_FILE} | awk '{ print $2 }')
	    Last_error=$(grep "Last_error:" ${REPLICATION_STATUS_FILE} | awk -F : '{ print $2 }')
            echo "Statuses are: " 
	    echo ${Slave_IO_Running}
	    echo ${Slave_SQL_Running}
	    echo ${Last_error}
 	    break
	else
	    echo "Replication is running"
	    echo "Replication status is :" 
	    echo ${status}
            break
	fi
}

 
#########################################
#
# CASE statement with usage and main logic 
#
#########################################
 
option="${1}" 
case ${option} in 
'--drain_db') 
	do_relay_check
	do_drain_db
;; 
'--db_shutdown') 
	do_relay_check
	do_drain_db
	do_db_shutdown 
	do_db_restart 
;; 
'--restart_db')
	do_db_restart 
;;
'--check_repl_status')
	do_relay_check
	do_replication_check 
;;
*)
	echo "For script ${filename} : "
        echo "Usage: ${filename} [--drain_db ] | [--db_shutdown ] | [--restart_db ] | [--check_repl_status ]" 
	echo "		--drain_db          - Stops Replication, notes binlog positions, and sets temporarily the pct dirty buffers to 0 to allow innodb pages to flush to disk."
	echo "		--db_shutdown 	    - Waits until the dirty buffers and pages are at 0 before stopping db, issuing fs freeze, then snapshot and unfreeze; then restarts db and replication."
	echo "		--restart_db 	    - Starts up mysql db and restarts replication"
	echo "		--check_repl_status - Starts up mysql db and restarts replication, if both are not already started"
	exit 1 # Command to come out of the program with status 1
;; 
esac 
 
# Add binary log positions to the gray log 
# Add binary log positions to the snapshot tag 
