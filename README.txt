		Fedora-GlusterFS-Hadoop Installation Script 

== Overview ==

  The install.sh script (and the companion data/prep_node.sh script) sets up
  GlusterFS on Fedora for Hadoop workloads.  The storage (brick) partition
  (usually /dev/sdb) can be configured as RAID 6 or as JBODs.
 
  A tarball named "fedora-hadoop-install-<version>.tar.gz" is downloaded to one
  of the cluster nodes or to the user's localhost. The download directory is
  arbitrary. install.sh requires password-less ssh from the node hosting the
  rhs install tarball (the "install-from" node) to all nodes in the cluster.
  GlusterFS does not require password-less SSH.
 
  The tarball contains the following:
   - install.sh: the main install script, executed by the root user.
   - README.txt: this file.
   - hosts.example: sample "hosts" config file.
   - data/: directory containing:
     - prep_node.sh: companion script, not to be executed directly.
     - gluster-hadoop-<version>.jar: Gluster-Hadoop plug-in. ?? or wget??
     - fuse-patch.tar.gz: FUSE patch RPMs.?? or wget from s3?
 
  install.sh is the main script and should be run as the root user. It installs
  the files in the data/ directory to each node contained in the "hosts" file.
 
== Before you begin ==

  The "hosts" file must be created by the user. It is not part of the tarball
  but an example hosts file is provided. The "hosts" file is expected to be
  created in the same directory where the tarball has been downloaded. If a
  different location is required the "--hosts" option can be used to specify
  the "hosts" file path. The "hosts" file contains a list of IP adress followed
  by hostname (same format as /etc/hosts), one pair per line. Each line
  represents one node in the storage cluster (gluster trusted pool). Example:
     ip-for-node-1 hostname-for-node-1
     ip-for-node-3 hostname-for-node-3
     ip-for-node-2 hostname-for-node-2
     ip-for-node-4 hostname-for-node-4
 
  IMPORTANT: the node order in the hosts file is critical for two reasons:
  1) Assuming the Gluster volume is created with replica 2
     then each pair of lines in hosts
     represents replica pairs. For example, the first 2 lines in hosts are
     replica pairs, as are the next two lines, etc.

  Also:
  - passwordless SSH is required between the installation node and each storage
    node. See the Addendum at the end of this document if you would like to see 
    instructions on how to do this.
    Essentially, Fedora needs to be installed with the  
    hostname configured with a static IP address. Do not create a gluster
    volume.
  - the order of the nodes in the "hosts" file is in replica order

== Installation ==

Instructions:
 0) upload fedora-hadoop-install-<version> tarball to the deployment directory
    on the "install-from" node.

 1) extract tarball to the local directory:
    $ tar xvzf fedora-hadoop-install-<version>.tar.gz

 2) cd to the extracted fedora-hadoop-install directory:
    $ cd fedora-hadoop-install-<version>

 3) execute "install.sh" from the install directory:
    $ ./install.sh [options (see --help)] <brick-dev> (note: brick_dev is 
                                                       required)
    For example: ./install.sh /dev/sdb

    Output is displayed on STDOUT and is also written to /var/log/RHS-install 
    on both the delpoyment node and on each data node in the cluster.

 4) The script should complete at which ...

 5) Validate the Installation

    Open a terminal and navigate to the Hadoop Directory
    cd /usr/lib/hadoop
     
    Change user to the mapred user
    su mapred

    Submit a TeraGen Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-111.jar teragen 1000 in-dir
	
    Submit a TeraSort Hadoop job test
    bin/hadoop jar hadoop-examples-1.2.0.1.3.2.0-111.jar terasort in-dir out-dir


== Addendum ==

1) Setting up password-less SSH 

   There is a utility script (devutils/passwordless-ssh.sh) which will set up
   password-less SSH from localhost (or wherever you run the script from) to
   all hosts defined in the local "hosts" file. Use --help for more info.
  
