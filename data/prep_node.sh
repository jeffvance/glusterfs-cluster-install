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
#   $1=self hostname*, $2=HOSTS(array)*, $3=HOST IP-addrs(array)*, $4=verbose
#   value*, $5=special logfile*, $6=working dir
# '*' means required argument, others are optional.
#
# Note on passing arrays: the caller (install.sh) needs to surround the array
# values with embedded double quotes, eg. "\"${ARRAY[@]}\""

# constants and args
NODE=$1
HOSTS=($2)
HOST_IPS=($3)
VERBOSE=$4
PREP_LOG=$5
DEPLOY_DIR=${6:-/tmp/gluster-hadoop-install/data/}
#echo -e "*** $(basename $0)\n 1=$NODE, 2=${HOSTS[@]}, 3=${HOST_IPS[@]}, 4=$VERBOSE, 5=$PREP_LOG, 6=$DEPLOY_DIR"

NUMNODES=${#HOSTS[@]}
# log threshold values (copied from install.sh)
LOG_DEBUG=0
LOG_INFO=1    # default for --verbose
LOG_SUMMARY=2 # default
LOG_REPORT=3  # suppress all output, other than final reporting
LOG_QUIET=9   # value for --quiet = suppress all output
LOG_FORCE=99  # force write regardless of VERBOSE setting


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

# install_plugin: copy the Hadoop-Gluster plug-in from the install files to
# the appropriate Hadoop directory. Fatal errors exit script.
#
function install_plugin(){

  local USR_JAVA_DIR='/usr/share/java'
  local HADOOP_JAVA_DIR='/usr/lib/hadoop/lib/'
  local jar=''; local out

  jar=$(ls glusterfs-hadoop*.jar)
  if [[ -z "$jar" ]] ; then
    display "  Gluster Hadoop plug-in missing in $DEPLOY_DIR" $LOG_FORCE
    exit 5
  fi

  display "-- Installing Gluster-Hadoop plug-in ($jar)..." $LOG_INFO
  # create target dirs if they does not exist
  [[ -d $USR_JAVA_DIR ]]    || /bin/mkdir -p $USR_JAVA_DIR
  [[ -d $HADOOP_JAVA_DIR ]] || /bin/mkdir -p $HADOOP_JAVA_DIR

  # copy jar and create symlink
  out=$(/bin/cp -uf $jar $USR_JAVA_DIR 2>&1)
  if (( $? != 0 )) ; then
    display "  Copy of plug-in failed" $LOG_FORCE
    exit 10
  fi
  display "$out" $LOG_DEBUG

  rm -f $HADOOP_JAVA_DIR/$jar
  out=$(ln -s $USR_JAVA_DIR/$jar $HADOOP_JAVA_DIR/$jar 2>&1)
  display "$out" $LOG_DEBUG

  display "   ... Gluster-Hadoop plug-in install successful" $LOG_SUMMARY
}

# install_epel: install the epel rpm. Note: epel package is not part of the
# install tarball and therefore must be installed over the internet via the
# ambari repo file. It is required that the ambari.repo file has been copied 
# to the correct dir prior to invoking this function.
#
function install_epel(){

  local out
 
  out=$(yum -y install epel-release 2>&1)
  display "$out" $LOG_DEBUG
}

# verify_java: verify the version of Java on NODE. Fatal errors exit script.
# NOTE: currenly not in use.
function verify_java(){

  local err
  local TEST_JAVA_VER="1.6"

  which java >&/dev/null
  err=$?
  if (( $err == 0 )) ; then
    JAVA_VER=$(java -version 2>&1 | head -n 1 | cut -d\" -f 2)
    if [[ ! ${JAVA_VER:0:${#TEST_JAVA_VER}} == $TEST_JAVA_VER ]] ; then
      display "   Current Java is $JAVA_VER, expected $TEST_JAVA_VER." \
	$LOG_FORCE
      display "   Download Java $TEST_JAVA_VER JRE from Oracle now." \
	$LOG_FORCE
      err=1
    else
      display "   ... Java version $JAVA_VER verified" $LOG_INFO
    fi
  else
    display "   Java is not installed. Download Java $TEST_JAVA_VER JRE from Oracle now." $LOG_FORCE
    err=35
  fi
  (( $err == 0 )) || exit $err
}

# verify_ntp: verify that ntp is installed and synchronized.
#
function verify_ntp(){

  local err

  which ntpstat >&/dev/null
  if (( $? == 0 )) ; then # ntp likely installed
    ntpstat >& /dev/null
    err=$?
    if (( err == 0 )) ; then 
      display "   NTP is synchronized..." $LOG_DEBUG
    elif (( $err == 1 )) ; then
      display "   NTP is NOT synchronized..." $LOG_INFO
    else
      display "   WARNING: NTP state is indeterminant..." $LOG_FORCE
    fi
  else
    display "   WARNING: NTP does not appear to be installed..." $LOG_FORCE
  fi
}

# verify_fuse: verify this node has the correct kernel FUSE patch installed. If
# not then it will be installed and a global variable is set to indicate that
# this node needs to be rebooted. There is no shell command/utility to report
# whether or not the FUSE patch has been installed (eg. uname -r doesn't), so
# a file is used for this test.
#
function verify_fuse(){

  local FUSE_TARBALL='fuse-*.tar.gz'; local out

  # if file exists then fuse patch installed
  local FUSE_INSTALLED='/tmp/FUSE_INSTALLED' # Note: deploy dir is rm'd

  if [[ -f "$FUSE_INSTALLED" ]]; then # file exists, assume installed
    display "   ... verified" $LOG_DEBUG
  else
    display "-- Installing FUSE patch which may take more than a few seconds..." $LOG_INFO
    echo
    /bin/rm -rf fusetmp  # scratch dir
    /bin/mkdir fusetmp
    if (( $(ls $FUSE_TARBALL|wc -l) != 1 )) ; then
      display "ERROR: missing or extra FUSE tarball" $LOG_FORCE
      exit 40
    fi

    out=$(/bin/tar -C fusetmp/ -xzf $FUSE_TARBALL 2>&1)
    if (( $? == 0 )) ; then
      display "$out" $LOG_DEBUG
    else
      display "ERROR: $out" $LOG_FORCE
      exit 45
    fi

    out=$(yum -y install fusetmp/*.rpm 2>&1)
    display "$out" $LOG_DEBUG

    # create kludgy fuse-has-been-installed file
    touch $FUSE_INSTALLED
    display "   A reboot of $NODE is required and will be done automatically" \
	$LOG_INFO
    echo
    REBOOT_REQUIRED=true
  fi
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

# install: perform all of the per-node installation steps.
#
function install(){

  local i #; local out

  # set this node's IP variable
  for (( i=0; i<$NUMNODES; i++ )); do
	[[ $NODE == ${HOSTS[$i]} ]] && break
  done
  IP=${HOST_IPS[$i]}

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
  verify_ntp

  # install epel
  echo
  display "-- Installing EPEL package" $LOG_SUMMARY
  install_epel

  # report Gluster version 
  display "-- Gluster version: $(gluster --version | head -n 1)" $LOG_SUMMARY

  # install Gluster-Hadoop plug-in on agent nodes
  install_plugin

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

install

display "$(/bin/date). End: prep_node" $LOG_REPORT

[[ -n "$REBOOT_REQUIRED" ]] && exit 99 # tell install.sh a reboot is needed
exit 0
#
# end of script
