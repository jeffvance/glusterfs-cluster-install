#!/bin/bash
#
# License: Apache License v2.0
# Author: Jeff Vance <jvance@redhat.com>
#
# THIS SCRIPT IS NOT MEANT TO BE RUN STAND-ALONE. IT IS A COMPANION SCRIPT TO
# INSTALL.SH
#
# This script is a companion script to install.sh and runs on a remote node. It
# does the following:
#  - reports the gluster version,
#  - installs the gluster-hadoop plug-in,
#  - checks if NTP is running and synchronized,
#  - yum installs the ambai agent and/or ambari-server rpms depending on passed
#    in arguments.
#  - installs the FUSE patch if it has not already been installed.
#
# Arguments (all positional):
#   $1=self hostname*, $2=install storage flag*, $3=install mgmt server flag*,
#   $4=HOSTS(array)*, $5=HOST IP-addrs(array)*, $6=management server hostname*,
#   $7=verbose value*, $8=special logfile*, $9=working dir
# '*' means required argument, others are optional.
#
# Note on passing arrays: the caller (install.sh) needs to surround the array
# values with embedded double quotes, eg. "\"${ARRAY[@]}\""

# constants and args
NODE=$1
STORAGE_INSTALL=$2 # true or false
MGMT_INSTALL=$3    # true or false
HOSTS=($4)
HOST_IPS=($5)
MGMT_NODE="$6" # note: this node can be inside or outside the storage cluster
VERBOSE=$7
PREP_LOG=$8
DEPLOY_DIR=${9:-/tmp/gluster-hadoop-install/data/}
#echo -e "*** $(basename $0)\n 1=$NODE, 2=$STORAGE_INSTALL, 3=$MGMT_INSTALL, 4=${HOSTS[@]}, 5=${HOST_IPS[@]}, 6=$MGMT_NODE, 7=$VERBOSE, 8=$PREP_LOG, 9=$DEPLOY_DIR"

NUMNODES=${#HOSTS[@]}
# log threshold values (copied from install.sh)
LOG_DEBUG=0
LOG_INFO=1    # default for --verbose
LOG_SUMMARY=2 # default
LOG_REPORT=3  # suppress all output, other than final reporting
LOG_QUIET=9   # value for --quiet = suppress all output
LOG_FORCE=99  # force write regardless of VERBOSE setting

# s3 variables
AMBARI_S3_RPM_URL='https://s3-us-west-1.amazonaws.com/rhbd/glusterfs-ambari/'


# display: write all messages to the special logfile which will be copied to 
# the "install-from" host, and potentially write the message to stdout. 
# $1=msg, $2=msg prioriy (optional, default=summary)
#
function display(){

  local pri=${2:-$LOG_SUMMARY} 

  echo "$1" >> $PREP_LOG
  (( pri >= VERBOSE )) && echo -e "$1"
}

# fixup_etc_host_file: append all ips + hostnames to /etc/hosts, unless the
# hostnames already exist.
#
function fixup_etc_hosts_file(){ 

  local host=; local ip=; local hosts_buf=''; local i

  for (( i=0; i<$NUMNODES; i++ )); do
        host="${HOSTS[$i]}"
        ip="${HOST_IPS[$i]}"
	# skip if host already present in /etc/hosts
        if /bin/grep -qs "$host" /etc/hosts; then # found self node
          continue # skip to next node
        fi
        hosts_buf+="$ip $host"$'\n' # \n at end
  done
  if (( ${#hosts_buf} > 2 )) ; then
    hosts_buf=${hosts_buf:0:${#hosts_buf}-1} # remove \n for last host entry
    display "  appending \"$hosts_buf\" to /etc/hosts" $LOG_DEBUG
    echo "$hosts_buf" >>/etc/hosts
  fi
}

# install_plugin: wget the most recent gluster-hadoop plug-in from archiva or
# s3 (moving off of archiva soon). This is done by scraping the main gluster-
# hadoop index page and getting the last href for the jar URL. Then copy the
# plug-in to the /usr/share directory and create a symlink point to the Hadoop
# directory. Fatal errors exit script.
#
function install_plugin(){

  local USR_JAVA_DIR='/usr/share/java'
  local HADOOP_JAVA_DIR='/usr/lib/hadoop/lib/'
  local HTTP='http://23.23.239.119'
  local INDEX_URL="$HTTP/archiva/browse/org.apache.hadoop.fs.glusterfs/glusterfs-hadoop" # note: will change when move to s3
  local JAR_URL="$HTTP/archiva/repository/internal/org/apache/hadoop/fs/glusterfs/glusterfs-hadoop"
  local JAR_SEARCH='<li><a href=\"/archiva/browse/org.apache.hadoop.fs.glusterfs'
  local SCRAPE_FILE='plugin-index.txt'
  local jar=''; local jar_ver; local out

  # get plugin index page and find the most current version, which is the last
  # list element (<li><a href=...) on the index page
  wget -q -O $SCRAPE_FILE $INDEX_URL
  jar_ver=$(/bin/grep "$JAR_SEARCH" $SCRAPE_FILE | tail -n 1)
  jar_ver=${jar_ver%;*}        # delete trailing ';jsessionid...</a></li>'
  jar_ver=${jar_ver##*hadoop/} # delete from beginning to last "hadoop/"
  # now jar_ver contains the most recent plugin jar version string
  wget $JAR_URL/$jar_ver/glusterfs-hadoop-$jar_ver.jar

  jar=$(ls glusterfs-hadoop*.jar 2> /dev/null)
  if [[ -z "$jar" ]] ; then
    display "ERROR: gluster-hadoop plug-in missing in $DEPLOY_DIR" $LOG_FORCE
    display "       attemped to retrieve JAR from $INDEX_URL/$jar_ver/" \
	$LOG_FORCE
    exit 3
  fi

  display "-- Installing gluster-hadoop plug-in from $jar..." $LOG_INFO
  # create target dirs if they does not exist
  [[ -d $USR_JAVA_DIR ]]    || /bin/mkdir -p $USR_JAVA_DIR
  [[ -d $HADOOP_JAVA_DIR ]] || /bin/mkdir -p $HADOOP_JAVA_DIR

  # copy jar and create symlink
  out=$(/bin/cp -uf $jar $USR_JAVA_DIR 2>&1)
  if (( $? != 0 )) ; then
    display "  Copy of plug-in failed" $LOG_FORCE
    exit 5
  fi
  display "cp: $out" $LOG_DEBUG

  rm -f $HADOOP_JAVA_DIR/$jar
  out=$(ln -s $USR_JAVA_DIR/$jar $HADOOP_JAVA_DIR/$jar 2>&1)
  display "symlink: $out" $LOG_DEBUG

  display "   ... Gluster-Hadoop plug-in install successful" $LOG_SUMMARY
}

# get_ambari_repo: wget the ambari.repo file.
#
function get_ambari_repo(){

  local REPO='ambari.repo'; local REPO_DIR='/etc/yum.repos.d'
  local REPO_PATH="$REPO_DIR/$REPO"
  local REPO_URL="http://public-repo-1.hortonworks.com/ambari/centos6/1.x/updates/1.2.3.7/$REPO"
  local out; local err

  [[ -d $REPO_DIR ]] || /bin/mkdir -p $REPO_DIR

  out=$(wget $REPO_URL -O $REPO_PATH)
  err=$?
  display "$REPO wget: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: wget $REPO error $err" $LOG_FORCE
    exit 8
  fi

  if [[ ! -f $REPO_PATH ]] ; then
    display "ERROR: $REPO_PATH missing" $LOG_FORCE
    exit 10
  fi 
}

# install_epel: install the epel rpm. Note: epel package is not part of the
# install tarball and therefore must be installed over the internet via the
# ambari repo file. It is required that the ambari.repo file has been copied 
# to the correct dir prior to invoking this function.
# NOTE: not currently used.
#
function install_epel(){

  local out; local err
 
  out=$(yum -y install epel-release 2>&1)
  err=$?
  display "epel install: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: epel install error $err" $LOG_FORCE
    exit 12
  fi
}

# install_ambari_agent: retrieve and install the ambari agent rpm, modify the
# .ini file to point to the ambari server, start the agent, and set up agent to
# start automatically after a reboot.
# Note: in a future version we may want to do 1 wget from s3 to the install-from
#   host, and then scp the rpm to each agent node in parallel...
#
function install_ambari_agent(){

  local out; local err
  local RPM_FILE='ambari-agent-1.3.0-SNAPSHOT20130904172112.x86_64.rpm'
  local RPM_URL="$AMBARI_S3_RPM_URL$RPM_FILE"
  local ambari_ini='/etc/ambari-agent/conf/ambari-agent.ini'
  local SERVER_SECTION='server'; SERVER_KEY='hostname='
  local KEY_VALUE="$MGMT_NODE"
  local AMBARI_AGENT_PID='/var/run/ambari-agent/ambari-agent.pid'

  # stop agent if running
  if [[ -f $AMBARI_AGENT_PID ]] ; then
    display "   stopping ambari-agent" $LOG_INFO
    out=$(ambari-agent stop 2>&1)
    display "stop: $out" $LOG_DEBUG
  fi

  # get agent rpm
  out=$(wget -nv $RPM_URL 2>&1)
  err=$?
  display "ambari agent rpm wget: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: wget agent error $err" $LOG_FORCE
    exit 14
  fi

  # install agent rpm
  if [[ ! -f "$RPM_FILE" ]] ; then
    display "ERROR: Ambari agent RPM \"$RPM_FILE\" missing" $LOG_FORCE
    exit 16
  fi
  out=$(yum -y install $RPM_FILE 2>&1)
  err=$?
  display "agent install: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: agent install error $err" $LOG_FORCE
    ##exit 18 # uncomment this after ambari rpm works!
  fi

  # modify the agent's .ini file's server hostname value
  display "  modifying $ambari_ini file" $LOG_DEBUG
  sed -i -e "/\[${SERVER_SECTION}\]/,/${SERVER_KEY}/s/=.*$/=${KEY_VALUE}/" $ambari_ini

  # start the agent
  out=$(ambari-agent start 2>&1)
  display "agent start: $out" $LOG_DEBUG

  # start agent after reboot
  out=$(chkconfig ambari-agent on 2>&1)
  display "agent chkconfig: $out" $LOG_DEBUG
}

# install_ambari_server: yum install the ambari server rpm, setup start the
# server, start ambari server, and start the server after a reboot.
#
function install_ambari_server(){

  local out; local err
  local RPM_FILE='ambari-server-1.3.0-SNAPSHOT20130904172038.noarch.rpm'
  local RPM_URL="$AMBARI_S3_RPM_URL$RPM_FILE"
  local AMBARI_SERVER_PID='/var/run/ambari-server/ambari-server.pid'

  # stop and reset server if running
  if [[ -f $AMBARI_SERVER_PID ]] ; then
    display "   stopping ambari-server" $LOG_INFO
    out=$(ambari-server stop 2>&1)
    display "server stop: $out" $LOG_DEBUG
    out=$(ambari-server reset -s 2>&1)
    display "server reset: $out" $LOG_DEBUG
  fi

  # get server rpm
  out=$(wget -nv $RPM_URL 2>&1)
  err=$?
  display "ambari server rpm wget: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: wget server error $err" $LOG_FORCE
    exit 20
  fi

  # install server rpm
  if [[ ! -f "$RPM_FILE" ]] ; then
    display "ERROR: Ambari server RPM \"$RPM_FILE\" missing" $LOG_FORCE
    exit 22
  fi
  # Note: the Oracle Java install takes a fair amount of time and yum does
  # thousands of progress updates. On a terminal this is fine but when output
  # is redirected to disk you get a *very* long record. The invoking script will
  # delete this one very long record in order to make the logfile more usable.
  out=$(yum -y install $RPM_FILE 2>&1)
  err=$?
  display "server install: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: server install error $err" $LOG_FORCE
    exit 24
  fi

  # setup the ambari-server
  # note: -s accepts all defaults with no prompting
  out=$(ambari-server setup -s 2>&1)
  err=$?
  display "server setup: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: server install error $err" $LOG_FORCE
    exit 26
  fi

  # start the server
  out=$(ambari-server start 2>&1)
  display "server start: $out" $LOG_DEBUG

  # start the server after a reboot
  out=$(chkconfig ambari-server on 2>&1)
  display "chkconfig: $out" $LOG_DEBUG
}

# verify_install_java: verify the version of Java on NODE. Fatal errors exit
# the script.
# NOTE: not currently used.
function verify_install_java(){

  local err=0; local downloadJava=0; local out
  local TEST_JAVA_VER='2.6'; local JAVA_VER
  local JAVA_URL_PREFIX='http://www.oracle.com/technetwork/java/javase/downloads/jre6-downloads-1637595/'
  local JAVA_URL_FILE='jre-6u34-linux-x64-rpm.bin'

  which java >& /dev/null
  err=$?

  if (( $err == 0 )) ; then
    JAVA_VER=$(java -version 2>&1 | head -n 1 | cut -d\" -f 2)
    if [[ ${JAVA_VER:0:${#TEST_JAVA_VER}} == $TEST_JAVA_VER ]] ; then
      display "   ... Java version $JAVA_VER verified" $LOG_INFO
      return
    else
      display "   Current Java is $JAVA_VER, expected $TEST_JAVA_VER." \
	$LOG_DEBUG
      display "   Downloading Java $TEST_JAVA_VER JRE from Oracle now." \
	$LOG_DEBUG
      downloadJava=1
    fi
  else
    display "   Java is not installed.\nDownloading Java $TEST_JAVA_VER JRE from Oracle now." $LOG_DEBUG
    downloadJava=1
  fi
  
  if (( downloadJava == 1 )) ; then
    out=$(wget $JAVA_URL_PREFIX$JAVA_URL_FILE)
    display "java wget: $out" $LOG_DEBUG
  fi
}

# verify_install_ntp: verify that ntp is installed and synchronized.
#
function verify_install_ntp(){

  local err; local out

  rpm -q ntp >& /dev/null
  if (( $? != 0 )) ; then
    display "   Installing NTP" $LOG_INFO
    out=$(yum install -y ntp)
    display "yum install ntp: $out" $LOG_DEBUG
  fi

  # start ntpd if not running
  ps -C ntpd >& /dev/null
  if (( $? != 0 )) ; then
    display "   Starting ntpd" $LOG_DEBUG
    ntpd -qg
    chkconfig ntpd on 2>&1  # run on reboot
    sleep 2
  fi

  ntpstat >& /dev/null
  err=$?
  if (( err == 0 )) ; then 
    display "   NTP is synchronized..." $LOG_DEBUG
  elif (( $err == 1 )) ; then
    display "   NTP is NOT synchronized..." $LOG_INFO
  else
    display "   WARNING: NTP state is indeterminant..." $LOG_FORCE
  fi
}

# verify_fuse: verify this node has the correct kernel FUSE patch installed. If
# not then it will be installed and a global variable is set to indicate that
# this node needs to be rebooted.
#
function verify_fuse(){

  local FUSE_REPO='/etc/yum.repos.d/fedora-fuse.repo'
  local REPO_URL='http://fedora-fuse.s3.amazonaws.com/'
  local FEDORA_FUSE='fedora-fuse'
  local out; local err

  # if the fuse repo file exists and contains the "fedora-fuse" then assume
  # that the fuse patch has already been installed
  [[ -f "$FUSE_REPO" && -n "$(/bin/grep -s '$FEDORA_FUSE' $FUSE_REPO)" ]] && {
    display "   ... verified" $LOG_DEBUG;
    return;
  }

  display "-- Installing FUSE patch..." $LOG_INFO
  echo
  [[ -f "$FUSE_REPO" ]] || display "   Creating \"$FUSE_REPO\" file" $LOG_DEBUG

  cat <<EOF >>$FUSE_REPO
[$FEDORA_FUSE]
name=$FEDORA_FUSE
baseurl=$REPO_URL
enabled=1
EOF
 
  out=$(yum -y install perl)  # perl is a dependency
  err=$?
  display "install perl: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: perl install error $err" $LOG_FORCE
    exit 27
  fi

  #out=$(yum --disablerepo="*" --enablerepo="$FEDORA_FUSE" --nogpgcheck \
	#-y  install p* k*)

### TRIAL AND ERROR FOR NOW... per Daniel QE:
  # see if installing elfutils-libs helps with fedora reboot issue...
  out=$(yum install -y elfutils-libs)
  err=$?
  display "elfutils-lib install: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: install elfutils error $err" $LOG_FORCE
### exit 28
  fi
### END TRIAL AND ERROR...

  out=$(yum -y --disablerepo='*' --enablerepo="$FEDORA_FUSE" --nogpgcheck \
	install kernel kernel-devel perf python-perf)
  display "install fuse: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: install FUSE error $err" $LOG_FORCE
    exit 29
  fi
  out=$(yum -y --disablerepo='*' --enablerepo='fedora-fuse' --nogpgcheck \
	downgrade kernel-headers)
  err=$?
  display "downgrade fuse: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: downgrade FUSE error $err" $LOG_FORCE
    exit 30
  fi
  echo
  REBOOT_REQUIRED=true
}

# sudoers: create the /etc/sudoers.d/20_gluster file if not present, add the
# mapred and yarn users to it (if not present) and set its permissions.
#
function sudoers(){

  local SUDOER_DIR='/etc/sudoers.d'
  local SUDOER_PATH="$SUDOER_DIR/20_gluster" # 20 is somewhat arbitrary
  local SUDOER_PERM='440'
  local SUDOER_ACC='ALL= NOPASSWD: /usr/bin/getfattr'
  local mapred='mapred'; local yarn='yarn'
  local MAPRED_SUDOER="$mapred $SUDOER_ACC"
  local YARN_SUDOER="$yarn $SUDOER_ACC"
  local out

  echo
  display "-- Prepping $SUDOER_PATH for user access exceptions..." $LOG_SUMMARY

  if [[ ! -d "$SUDOER_DIR" ]] ; then
    display "   Creating $SUDOER_DIR..." $LOG_DEBUG
    /bin/mkdir -p $SUDOER_DIR
  fi

  if ! /bin/grep -qs $mapred $SUDOER_PATH ; then
    display "   Appending \"$MAPRED_SUDOER\" to $SUDOER_PATH" $LOG_INFO
    echo "$MAPRED_SUDOER" >> $SUDOER_PATH
  fi
  if ! /bin/grep -qs $yarn $SUDOER_PATH ; then
    display "   Appending \"$YARN_SUDOER\" to $SUDOER_PATH" $LOG_INFO
    echo "$YARN_SUDOER"  >> $SUDOER_PATH
  fi

  out=$(/bin/chmod $SUDOER_PERM $SUDOER_PATH 2>&1)
  display "$out" $LOG_DEBUG
}

# install_gluster: install and start glusterfs.
#
function install_gluster(){

  local out; local err

  # install gluster
  out=$(yum -y install glusterfs glusterfs-server glusterfs-fuse 2>&1)
  err=$?
  display "gluster install: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: gluster install error $err" $LOG_FORCE
    exit 32
  fi

  # start gluster
  # note: glusterd start fails below (not known why). The work-around is to
  # invoke /usr/sbin/glusterd directly
  #out=$(systemctl start glusterd.service) 
  #err=$?
  #display "gluster start: $out" $LOG_INFO
  #if (( err != 0 )) ; then
    #display "ERROR: gluster start error $err" $LOG_FORCE
    #exit 34
  #fi
  # fedora 19 work-around...
  /usr/sbin/glusterd  # remove when systemctl start glusterd.service works
  out=$(ps -e|grep glusterd|grep -v grep)
  if [[ -z "$out" ]] ; then
    display "ERROR: glusterd not started" $LOG_FORCE
    exit 35
  fi

  display "   Gluster version: $(gluster --version | head -n 1) started" \
	$LOG_SUMMARY
}

# disable_firewall: use iptables to disable the firewall, needed by Ambari and
# for gluster peer probes.
#
function disable_firewall(){

  local out; local err

  #out=$(systemctl stop firewalld.service) # redundant with below?
  #display "systemctl stop: $out" $LOG_DEBUG
  #out=$(service iptables stop)  # redundant with above?
  out=$(iptables -F) # sure fire way to disable iptables
  err=$?
  display "iptables: $out" $LOG_DEBUG
  if (( err != 0 )) ; then
    display "ERROR: iptables error $err" $LOG_FORCE
    exit 36
  fi

  out=$(chkconfig iptables off) # preserve after reboot
  display "chkconfig off: $out" $LOG_DEBUG
}

# install_common: perform node installation steps independent of whether or not
# the node is to be the ambari-server or an ambari-agent.
#
function install_common(){

  local out; local err

  # install wget
  rpm -q wget >& /dev/null
  if (( $? != 0 )) ; then
    out=$(yum -y install wget)
    err=$?
    display "install wget: $out" $LOG_DEBUG
    if (( err != 0 )) ; then
      display "ERROR: wget install error $err" $LOG_FORCE
      exit 38
    fi
  fi

  # set up /etc/hosts to map ip -> hostname
  echo
  display "-- Setting up IP -> hostname mapping" $LOG_SUMMARY
  fixup_etc_hosts_file
  echo $NODE >/etc/hostname
  /bin/hostname $NODE

  # set up sudoers file for mapred and yarn users
  sudoers

  # verify NTP setup and sync clock
  echo
  display "-- Verifying NTP is running" $LOG_SUMMARY
  verify_install_ntp

  # get Ambari repo file
  echo
  display "-- Downloading the Ambari repo file"
  get_ambari_repo

  ## install epel -- SKIP: not applicable with fedora
  #echo
  #display "-- Installing EPEL package" $LOG_SUMMARY
  #install_epel
}

# install_storage: perform the installation steps needed when the node is an
#  ambari agent.
#
function install_storage(){

  # install and start gluster
  echo
  display "-- Install Gluster" $LOG_SUMMARY
  install_gluster

  # disable firewall
  echo
  display "-- Disable firewall" $LOG_SUMMARY
  disable_firewall

  # install Gluster-Hadoop plug-in on agent nodes
  install_plugin

  # install Ambari agent rpm
  echo
  display "-- Installing Ambari agent" $LOG_SUMMARY
  install_ambari_agent

  # verify FUSE patch, if not installed yum install it.
  echo
  display "-- Verifying FUSE patch installation:" $LOG_SUMMARY
  verify_fuse

  # apply the tuned-admin rhs-high-throughput profile
  #echo
  #display "-- Applying the rhs-high-throughput profile using tuned-adm" \
	#$LOG_SUMMARY
  #out=$(tuned-adm profile rhs-high-throughput 2>&1)
  #display "$out" $LOG_DEBUG
}

# install_mgmt: perform the installations steps needed when the node is the
# ambari server.
#
function install_mgmt(){

  echo
  display "-- Installing Ambari server" $LOG_SUMMARY

  # verify/install Oracle Java (JRE)
  # NOTE: currently not in use. Using ambari to install correct Java
  #echo
  #display "-- Verifying Java (JRE)" $LOG_SUMMARY

  install_ambari_server
}


## ** main ** ##
echo
display "$(/bin/date). Begin: prep_node" $LOG_REPORT

if [[ ! -d $DEPLOY_DIR ]] ; then
  display "$NODE: Directory '$DEPLOY_DIR' missing on $(hostname)" $LOG_FORCE
  exit -1
fi

cd $DEPLOY_DIR
/bin/ls >/dev/null
if (( $? != 0 )) ; then
  display "$NODE: No files found in $DEPLOY_DIR" $LOG_FORCE 
  exit -1
fi

# remove special logfile, start "clean" each time script is invoked
rm -f $PREP_LOG

install_common

[[ $STORAGE_INSTALL == true ]] && install_storage
[[ $MGMT_INSTALL == true    ]] && install_mgmt

display "$(/bin/date). End: prep_node" $LOG_REPORT

[[ -n "$REBOOT_REQUIRED" ]] && exit 99 # tell install.sh a reboot is needed
exit 0
#
# end of script
