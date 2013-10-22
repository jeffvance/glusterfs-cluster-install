#
# Assumptions:
#
# See the usage() function for arguments and their definitions.

# set global variables
SCRIPT=$(/bin/basename $0)
SCRIPT_VERS='0.2' # self version
INSTALL_DIR=$PWD  # name of deployment (install-from) dir
INSTALL_FROM_IP=$(hostname -i)
LOGFILE='/var/log/pwdless-ssh.log'


# display: Write the message to stdlist and append it to localhost's logfile.
#
function display(){  # $1 is the message
  echo "$1" >> $LOGFILE
  echo -e "$1"
}

# bugout: Write out a debugging message
#
function bugout (){ # $1 is the message
   
  local output_string="DEBUG: "

  if [[ $DEBUG == true ]] ; then 
    output_string+=$1
    display "$output_string"
  fi
}

# short_usage: write short usage to stdout.
#
function short_usage(){

  cat <<EOF

Syntax:

$SCRIPT [-v|--version] | [-h|--help]
$SCRIPT [--hosts <path>]
        [--sethostname | [--noset|--nosethostname]
        [--verbose]

EOF
}

# usage: write full usage/help text to stdout.
#
function usage(){

  cat <<EOF

$SCRIPT (version $SCRIPT_VERS)

Usage:

Sets up password-less SSH as required for a GlusterFS cluster. A local "hosts"
file of ip-address<space>hostname pairs contains the list of hosts for which
password-less SSH is configured. Additionally, the first host in this file
will be able to password-less SSH to all other hosts in the file. Thus,
after running this script the user will be able to password-less SSH from
localhost to all hosts in the hosts file, and from the first host to all
other hosts defined in the file.

"host" file format:
   IP-address   simple-hostname
   IP-address   simple-hostname ...
EOF
  short_usage
  cat <<EOF
  --hosts     <path> : path to "hosts" file. This file contains a list of
                       "IP-addr hostname" pairs for each node in the cluster.
                       Default: "./hosts"
  -v|--version       : Version of the script
  -h|--help          : help text (this)
  --sethostname      : sethostname=hostname on each node (default)
  --noset|nosethostname: do not set the hostname on each node (override default)
  --verbose          : causes more output. Default is semi-quiet

EOF
}

# parse_cmd: getopt used to do general parsing. The brick-dev arg is required.
# The remaining parms are optional. See usage function for syntax.
#
function parse_cmd(){

  local OPTIONS='vh'
  local LONG_OPTS='hosts:,help,version,noset,nosethostnamem,verbose'

  # defaults (global variables)
  REPLICA_CNT=2
  SETHOSTNAME=true
  DEBUG=false

  # "hosts" file concontains hostname ip-addr for all nodes in cluster
  HOSTS_FILE="$INSTALL_DIR/hosts"

  local args=$(getopt -n "$SCRIPT" -o $OPTIONS --long $LONG_OPTS -- $@)
  (( $? == 0 )) || { echo "$SCRIPT syntax error"; exit -1; }

  eval set -- "$args" # set up $1... positional args
  while true ; do
      case "$1" in
	-h|--help)
	    usage; exit 0
	;;
	-v|--version)
	    echo "$SCRIPT version: $SCRIPT_VERS"; exit 0
	;;
	--hosts)
	    HOSTS_FILE=$2; shift 2; continue
	;;
	--verbose)
           DEBUG=true; shift; continue
	;;
	--noset|--nosethostname)
	   SETHOSTNAME=false; shift; continue
	;;
	--sethostname)
	   SETHOSTNAME=true; shift; continue
	;;
	--)  # no more args to parse
	    shift; break
	;;
	*) echo "Error: Unknown option: \"$1\""; exit -1
	;;
      esac
  done

  eval set -- "$@" # move arg pointer so $1 points to next arg past last opt

  if [[ $DEBUG == true ]] ; then 
     display "DEBUGGING ON"
  fi
}

function read_verify_local_hosts_file(){

    local i; local host=''; local ip=''; local hosts_ary; local numTokens

    # regular expression to validate ip addresses
    local VALID_IP_RE='^(([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])\.){3}([0-9]|[1-9][0-9]|1[0-9]{2}|2[0-4][0-9]|25[0-5])$'

    # regular expression to validate hostnames (host is down-cased)
    local VALID_HOSTNAME_RE='^(([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])\.)*([a-z0-9]|[a-z0-9][a-z0-9\-]*[a-z0-9])$'

    # read hosts file, skip comments and blank lines, parse out hostname and ip
    read -a hosts_ary <<< $(sed '/^ *#/d;/^ *$/d;s/#.*//' $HOSTS_FILE)
    numTokens=${#hosts_ary[@]}
    HOSTS=(); HOST_IPS=() # global vars

    # hosts file format: ip-address  hostname  # one pair per line
    for (( i=0; i<$numTokens; i++ )); do
	# IP address:
	ip=${hosts_ary[$i]}
        bugout "ip = $ip"

	# validate basic ip-addr syntax
	if [[ ! $ip =~ $VALID_IP_RE ]] ; then
	  errmsg+=" * $HOSTS_FILE record $((i/2)):\n   Unexpected IP address syntax for \"$ip\"\n"
	  ((errcnt++))
	  break # exit loop
	fi
	HOST_IPS+=($ip)

	# hostname:
	((i++))
	host=${hosts_ary[$i]}
        bugout "host = $host"

        # down-case if any upper-case letters in host
        if [[ "$host" =~ [A-Z]+ ]] ; then
          bugout "   ...down-casing $host"
          host=${host,,} # down-case
        fi

	# validate basic hostname syntax
 	if [[ ! $host =~ $VALID_HOSTNAME_RE ]] ; then
	  errmsg+=" * $HOSTS_FILE record $((i/2)):\n   Unexpected hostname syntax for \"$host\"\n"
	  ((errcnt++))
	  break # exit loop
        fi
	HOSTS+=($host)

        # verify connectivity from localhost to data node
	# note: ip used since /etc/hosts may not be set up to map ip to hostname
        bugout "--->checking to see if we already have password-less SSH"
	ssh -q -oBatchMode=yes root@$ip exit
        if (( $? == 0 )) ; then
           bugout "yes...password-less SSH to $ip"
 	else
           bugout "nope...no password-less SSH to $ip"
	fi
    done

    (( errcnt != 0 )) && return # errors in hosts checking loop are fatal

    # validate the number of nodes in the hosts file
    NUMNODES=${#HOSTS[@]}
    bugout "Number of nodes found in hostfile = $NUMNODES"
    if (( NUMNODES < REPLICA_CNT )) ; then
      errmsg+=" * The $HOSTS_FILE file must contain at least $REPLICA_CNT nodes (replica count)\n"
      ((errcnt++))
    elif (( NUMNODES % REPLICA_CNT != 0 )) ; then
      errmsg+=" * The number of nodes in the $HOSTS_FILE file must be a multiple of the\n   replica count ($REPLICA_CNT)\n"
      ((errcnt++))
    fi
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
	bugout "---> $host appended to /etc/hosts"
        hosts_buf+="$ip $host"$'\n' # \n at end
  done
  if (( ${#hosts_buf} > 2 )) ; then
    hosts_buf=${hosts_buf:0:${#hosts_buf}-1} # remove \n for last host entry
    echo "$hosts_buf" >>/etc/hosts
  fi
}

function setup_passwordless_ssh {

   local i; local host=''; local ip=''; local sshOK='OK'
   local KNOWN_HOSTS=~/.ssh/known_hosts # note: cannot quote value!
   local PRIVATE_KEY_FILE=~/.ssh/id_rsa # note: cannot quote value!

   if [[ ! -f $PRIVATE_KEY_FILE ]] ; then # on localhost...
     display "Generating key: ssh-keygen -q -t rsa -f $PRIVATE_KEY_FILE -N ''"
     ssh-keygen -q -t rsa -f $PRIVATE_KEY_FILE -N ""
   fi

   # add hosts file's "hosts" to local /etc/hosts if not already there
   display "Potentially update /etc/hosts with hostnames from \"hosts\" file..."
   fixup_etc_hosts_file

   display "Copying keys to each node..."
   for (( i=0; i<$NUMNODES; i++ )); do
	ip=${HOST_IPS[$i]}
	host=${HOSTS[$i]}
	bugout "--> $host ($ip)"

	# remove host from known_hosts file, if present
	if [[ -f $KNOWN_HOSTS ]] ; then
	  bugout "delete \"$host\" and \"$ip\" from known_hosts file"
	  sed -i "/^$host/d;/^$ip/d" $KNOWN_HOSTS
	fi

	display "Copying SSH keyfile to $host"
	bugout "---> with 'sh-copy-id -i ~/.ssh/id_rsa.pub root@$host' command"
	display "** Answer \"yes\" to the '...continue connecting' prompt, and"
	display "   enter the password for each node..."
	ssh-copy-id -i ~/.ssh/id_rsa.pub root@$host # user will be prompted

	# test if passwordless SSH is working
	ssh -q -oBatchMode=yes root@$host exit
	if (( $? != 0 )) ; then
          sshOK='FAILED'
          display "ERROR: Can't ssh to $host"
          display "PASSWORDLESS SSH SETUP FAILED - FATAL!"
          exit 20
	fi

	if [[ $SETHOSTNAME == true ]] ; then 
          display "Setting hostname for $host"
          bugout "--> with 'ssh root@$ip hostname $host' command"
          ssh root@$ip hostname $host
	fi

	display "...Node: $host (IP: $ip), SSH=$sshOK"
        echo
   done

   # set up passwordless-ssh from 1st host in the hosts file to all the other
   # hosts in that file.
   firstHost=${HOSTS[0]}
   display "Last, set up passwordless-ssh from $firstHost to all other nodes"
   display "in the hosts file"
   bugout "---> with 'scp ~/.ssh/id_* $KNOWN_HOSTS root@$firstHost:/root/.ssh'"
   scp ~/.ssh/id_* $KNOWN_HOSTS root@$firstHost:/root/.ssh
   for (( i=1; i<$NUMNODES; i++ )); do
	ip=${HOST_IPS[$i]}; host=${HOSTS[$i]}
	# append ip/host to first-node's /etc/hosts file
	bugout "---> with 'ssh root@$firstHost echo \"$ip $host\" >>/etc/hosts'"
	ssh root@$firstHost "echo '$ip $host' >>/etc/hosts"
	# copy id
	bugout "---> with 'ssh root@$firstHost ssh-copy-id -i ~/.ssh/id_rsa.pub root@$host'"
	ssh root@$firstHost "ssh-copy-id -i ~/.ssh/id_rsa.pub root@$host"
   done
}


## ** main ** ##

parse_cmd $@

display "$(/bin/date). Begin: $SCRIPT -- version $SCRIPT_VERS ***"

display "Using host file: $HOSTS_FILE"
read_verify_local_hosts_file

display "Begin setup of passwordless SSH"
setup_passwordless_ssh

#
# end of script
