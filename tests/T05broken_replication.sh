#!/bin/bash
#
# Test description
# 
# Test how broken replication affects the readable attribute

# global include files
. config
. functions

testdir=`dirname $0`


setup() {

./T01gracefulstart.sh setup

} 

runtest() {
    local master
    local readable_state

    build_assoc_uname_ssh
    master=`check_master`

    # Check rvip running on master (should not all be on master)
    check_slaves $master

    # create the table
    (cat <<EOF
create database if not exists test;
use test;
drop table if exists test_prm_broken_repl; 
create table test_prm_broken_repl (
    id int NOT NULL AUTO_INCREMENT,
    data int,
    primary key(id));
EOF
    ) | ${uname_ssh[$master]} $MYSQL 

    #Now we pick a slave and insert id = 1

    declare -a slaves=( `crm_slaves` )

    (cat <<EOF
use test;
insert into test_prm_broken_repl (id,data) values (1,1);
EOF
    ) | ${uname_ssh[${slave[0]}]} $MYSQL

    # now, insert the same row on the master
    (cat <<EOF
use test;
insert into test_prm_broken_repl (id,data) values (1,1);
EOF
    ) | ${uname_ssh[$master]} $MYSQL

    # Replication should be broken now, let's wait for the next
    # monitor op
    sleep 5

    readable_state=`runcmd ${uname_ssh[${slave[0]}]} crm_attribute -l reboot -n ${READER_ATTRIBUTE} --query -q`
    if [ "$readable_state" -ne 0 ]; then
        echo "Failed to detect broken replication on ${slave[0]}"
        print_result "$0" $PRM_FAIL
    fi

    # repair replication
    (cat <<EOF
use test;
delete from test_prm_broken_repl where id = 1;
start slave;
EOF
    ) | ${uname_ssh[${slave[0]}]} $MYSQL

    # Wait for monitor op
    sleep 5

    readable_state=`runcmd ${uname_ssh[${slave[0]}]} crm_attribute -l reboot -n ${READER_ATTRIBUTE} --query -q`

    #Before exiting, drop the table
    (cat <<EOF
use test;
drop table if exists test_prm_broken_repl; 
EOF
    ) | ${uname_ssh[$master]} $MYSQL 


    if [ "$readable_state" -ne 1 ]; then
        echo "Failed to detect repaired replication on ${slave[0]}"
        print_result "$0" $PRM_FAIL
    else 
        print_result "$0" $PRM_SUCCESS
    fi

}


cleanup() {

./T01gracefulstart.sh cleanup    

}


# What kind of method was invoked?
case "$1" in
  setup)    setup;;
  runtest)  runtest;;
  cleanup)  cleanup;;

 *)     echo 'Non implemented'
        exit 1
esac
