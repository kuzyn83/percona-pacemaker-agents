============================================================================
Percona replication manager (PRM) geographical disaster recovery setup guide
============================================================================

Author: Yves Trudeau, Percona

State: first draft completed

May 2013

.. contents::


--------
Overview
--------

Once you have built a Percona replication manager (PRM) cluster, you can add geographical disaster recovery (Geo-DR).  The goal of this guide is to help you link two disctinct PRM cluster so that they act as a single unit under the paxos protocol.  In order to have a funcationnal Geo-DR setup, you need 3 distinct and independent data centers.  The booth arbitrator resource (site 3) is very lightweight, the tiniest EC2 instance will be more than enough to handle it. 


Site 1
======

::

   Network: 10.3.1.0/24
   pacemaker-1-1, database node, IP: 10.3.1.1
   pacemaker-1-2, database node, IP: 10.3.1.2
   booth-vip, 10.3.1.10
   writer-vip, 10.3.1.20
   reader-vips, 10.3.1.21, 10.3.1.22

Site 2
======

::

   Network: 10.3.2.0/24
   pacemaker-2-1, database node, IP: 10.3.2.1
   pacemaker-2-2, database node, IP: 10.3.2.2
   booth-vip, 10.3.2.10
   writer-vip, 10.3.2.20
   reader-vips, 10.3.2.21, 10.3.2.22

Site 3
======

::

   pacemaker-3-1, arbitrator, IP: 10.3.3.1

All nodes are defined in the /etc/hosts file of all the nodes.

-----------
Booth Setup
-----------

Package install
===============

The installation of booth is tricky there're 2 versions of the ``crm_ticket`` script from the pacemaker install out there.  One, there oldest is a bash shell (el6, ubuntu pre-13.04) and the newest form is a binary (Debian7, Ubuntu 13.04+).  Furthermore, the packages are not always available.  To know which type of ``crm_ticket`` you have, do::

    root@pacemaker-2-2:~# file `which crm_ticket`
    /usr/sbin/crm_ticket: ELF 32-bit LSB executable, Intel 80386, version 1 (SYSV), dynamically linked (uses shared libs), for GNU/Linux 2.6.26, BuildID[sha1]=0x129825ea4fefbc290483780f7b0f3c5825126bf3, stripped
    
You'll get a result similar to this (maybe 64bits) if you have the new binary.  For the old tool you'll get::

    root@CENTOS-1-1:~# file `which crm_ticket`
    /usr/sbin/crm_ticket: Bourne-Again shell script, ASCII text executable
        

Ubuntu/Debian
-------------

For recent Ubuntu (13.04+) and Debian (7+) installs, the booth packages are available in the repository, simply do::

    apt-get install booth booth-pacemaker
    
The packages will be compatible with the ``crm_ticket`` version in use. The story is a bit different for older versions since there's no package available.  If your installation uses the newest version of the tool, simply grab a recent source tree from git::

    git clone git://github.com/jjzhang/booth.git

If your install the old ``crm_ticket`` you can try from here::

    git clone git@github.com:percona/percona-pacemaker-agents.git
    
and compile what's under tools/booth/src/booth-0.1.0_old_crm_ticket_no_force with "autogen.sh; ./configure; make; make install".  You'll find an init.d startup script for the arbitrator and a pacemaker resource agent in tools/booth/support-files.

Booth Configuration
===================

The configuration file identifies all the booth nodes. On each data center, only one node will run boothd at any given time so it must have its own virtual IP (can't be the writer-vip).  On all servers, the booth configuration (/etc/booth/booth.conf) must be the same.  Here's the configuration I was using::

   transport="UDP"
   port="6666"
   arbitrator="10.3.3.1"
   site="10.3.1.10"
   site="10.3.2.10"
   ticket="ticketMaster;120"

You'll need to adjust the IP/VIP to what you have.  Between all of these IPs, communication on port 6666/UDP must be allowed.  You can change the port if needed.  Once done, start the booth process on the arbitrator, the "booth client list" command on the arbitrator should give the following output::

   [root@localhost x86_64]# booth client list
   ticket: ticketMaster, owner: None, expires: INF
   
In this configuration, the ticket timeout is set to two minutes (120s), that means if a datacenter goes completely offline, it may take up to two minutes before a failover is initiated.  This timeout can be lowered but be warned that setting it too low may cause cluster instability.  For geo-DR, I doubt going under 30s makes sense.


-------------
Pre-requisite
-------------

The following assumes you have two working PRM clusters in separate datacenters.  Those are regular setups, see the ``PRM-setup-guide`` for more information.

---
ssh
---

From every database node to every other database node, ssh from user root must be key based and the initial host key acceptance must have been made for the writer_vip.  What I suggest is to do something like::

   On site 1, node 1, ip addr add writer_vipValueOfSite1/cidr_netmask_value dev eth0
   On site 2, nodes 1 and 2,  ssh writer_vipValueOfSite1  and accept the host key
   On site 1, node 2, ip addr del writer_vipValueOfSite1/cidr_netmask_value dev eth0

and repeat for all hosts, adapting for site 2.  Currently the agent doesn't support a custom ssh key but that would be an easy hack. Finally, set the ssh timeout to a short value by editing /root/.ssh/config and putting a setting like::

   Host *
        ConnectTimeout=2

This is extremely important, without a short connectTimeout, Pacemaker will likely timeout befor ssh and nothing will work. Normally even over a WAN, ssh can open a connection is about or less than 1s.  If it is not the case, look at the cypher configuration and reverse DNS, there might be a mismatch or a misconfiguration.  If you have to grow the timeout, do it like if you were losing a finger for every second you add.

---------
New agent
---------

You need to make sure the mysql agent you have supports geo DR.  Best is to download from git like::

   cd /tmp
   rm -f mysql
   wget https://github.com/percona/percona-pacemaker-agents/raw/master/agents/mysql_prm -O mysql
   chmod u+x mysql
   mv mysql /usr/lib/ocf/resource.d/percona/
   
-----------------------
Pacemaker configuration
-----------------------

Assuming all databases initially have the same dataset and the two PRM cluster are up and running, we can begin building the configuration, starting by the booth configuration.  Using "crm configure edit" add the following configuration, adjusting the IP to correspond to each datacenter booth-vip::

   primitive booth ocf:pacemaker:booth-site \
         meta resource-stickiness="INFINITY" target-role="Started" \
         op monitor interval="10s" timeout="20s"
   primitive booth-ip ocf:heartbeat:IPaddr2 \
         params ip="10.3.1.10" nic="eth0"
   group g-booth booth-ip booth
   order order-booth-ms_MySQL inf: g-booth ms_MySQL:promote
   
Here, it is assumed that the MySQL master-slave clonset is named ``ms_MySQL``.  If it is not the case, adjust accordingly.  Now, another tricky part, we must create an entry in pacemaker and a constraint for the "ticketMaster" token obtained from booth.  

The "crm" tool doesn't support these options yet, so we must edit the xml.  The first step is to dump the current cib in xml format with the local pacemaker cluster in standby::

   crm node standby pacemaker-1-1
   crm node standby pacemaker-1-2
   cibadmin -Q > /tmp/cib.xml

Then, use a text editor and add to the "<constraint></constraint>" section::

   <rsc_ticket id="ms_MySQL-req-ticketMaster" loss-policy="demote" rsc="ms_MySQL" rsc-role="Master" ticket="ticketMaster"/>

In my case, after the edition, the section of interest of the file looked like::

   ...
   <constraints>
   <rsc_ticket id="ms_MySQL-req-ticketMaster" loss-policy="demote" rsc="ms_MySQL" rsc-role="Master" ticket="ticketMaster"/>
   <rsc_location id="No-reader-vip-1-loc" rsc="reader_vip1">
      <rule id="No-reader-vip-1-rule" score="-INFINITY">
   ...
   
Then load the file back::

   cibadmin --replace --xml-file /tmp/cib.xml

And repeat for the other site.  The last step we need to do is enable the geo-redundant behavior of the agent by adding the parameters "geo_remote_IP" and "booth_master_ticket" to the MySQL primitive using "crm configure edit".  The "geo_remote_IP" is where ssh will connect to get the pacemaker info of the master side.  I strongly suggest you use the writer_vip of the remote site for that so the setting will be different on both sides.  The "booth_master_ticket" we have defined is ticketMaster and the same value needs to be used on both sides.  After these addition, the primitive line for the MySQL primitive will look like (for site 1)::

Noticed the the slave monitor operation interval has been increased to 10s, this is because an ssh may be done. 

   primitive p_mysql ocf:percona:mysql \
         params config="/etc/mysql/my.cnf" pid="/var/lib/mysql/mysqld.pid" \
         socket="/var/run/mysqld/mysqld.sock"replication_user="repl_user" \
         replication_passwd="WhatAPassword" max_slave_lag="15" \
         evict_outdated_slaves="false" binary="/usr/sbin/mysqld" test_user="test_user" \
         test_passwd="test_pass" geo_remote_IP="10.3.2.20" \
         booth_master_ticket="ticketMaster" \
         op monitor interval="5s" role="Master" timeout="30s" OCF_CHECK_LEVEL="1" \
         op monitor interval="10s" role="Slave" timeout="30s" OCF_CHECK_LEVEL="1" \
         op start interval="0" timeout="900s" \
         op stop interval="0" timeout="900s"

and put the nodes back online::

   on site 1

   crm node online pacemaker-1-1
   crm node online pacemaker-1-2

   on site 2
   
   crm node online pacemaker-2-1
   crm node online pacemaker-2-2

At this point, all the nodes should be defined as slaves and no reader or writer vip should be defined because the ticket has not been granted.  To grant site 1 the master role, go n the arbitrator or on any of the nodes running the booth-site resource and do::

   booth client grant -t ticketMaster -s 10.3.1.10

If everything goes well, the command will promote a node on site 1 to the master role. 

-----------
Limitations
-----------

It is important to keep in mind that a site with the master role will realized it lost communication to the other 2 sites only at the expiration of the token which we have set to 120s, 2 minutes.  At that point, the surviving 2 nodes will agree to move the token to the surviving database site which will then take over the master role.  It is possible, that writes, from application internal to the original master site will have continue to send write requests to the local databases.  Then when the communication will be reestablished between the 2 sites, you'll have a split brain.  You can experiment with lower renewal time but there will always be a window of time where dataset will be diverging. 

---------------
Troubleshooting
---------------

If no master exists, the first thing to look at is the presence of a ticket.  To check if the ticket has been granted go to the arbitrator or a node running the booth-site resource and type "booth client list".  The output should be like this::

   root@pacemaker-3-1:~# booth client list
   ticket: ticketMaster, owner: 10.3.1.10, expires: 2013/01/25 14:56:07

If there's no owner you'll need to regrant it like above.  That will happens if both sites are down with no booth-site resource running.

