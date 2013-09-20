		RHS-Ambari Installation Script 

== Overview ==

  The install.sh script (and the companion data/prep_node.sh script) sets up
  Red Hat Storage (RHS) for Hadoop workloads. It is expected that the Red Hat
  Storage installation guide was followed to set up RHS. The storage (brick)
  partition(usually /dev/sdb) should be configured as RAID 6.
 
  A tarball named "rhs-ambari-install-<version>.tar.gz" is downloaded to one of
  the cluster nodes or to the user's localhost. The download directory is
  arbitrary. install.sh requires password-less ssh from the node hosting the
  rhs install tarball (the "install-from" node) to all nodes in the cluster. In
  addition, Ambari requires password-less ssh from the Ambari server
  "management node" to all storage/agent nodes in the cluster. To simplify
  password-less ssh set up, the install-from node can be the same as the Ambari
  management node. The --mgmt-node option is available to specify the Ambari
  management node if the default is not suitable. The default Ambari server
  (management) node is the first host defined in the local "hosts" file,
  described below.
 
  The RHS tarball contains the following:
   - install.sh: this script, executed by the root user.
   - README.txt: this file.
   - hosts.example: sample "hosts" config file.
   - data/: directory containing:
     - prep_node.sh: companion script, not to be executed directly.
     - gluster-hadoop-<version>.jar: Gluster-Hadoop plug-in.
     - fuse-patch.tar.gz: FUSE patch RPMs.
     - ambari-<version>.rpms.tar.gz: Ambari server and agent RPMs.
     - ambari.repo: Ambari's repo file.
 
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
  1) Assuming the RHS volume is created with replica 2 (which is the only
     configuration supported for RHS) then each pair of lines in hosts
     represents replica pairs. For example, the first 2 lines in hosts are
     replica pairs, as are the next two lines, etc.
  2) If the --mgmt-node option is not specified then the default Ambari server
     "management" node is the *first* hostname listed in the "hosts" file. In
     this case the first node in the hosts file is both a storge node and the
     management node.

  Red Hat Network Registering (RHN):
  install.sh will automatically register each node in the "hosts" file with the
  Red Hat Network (RHN) when the --rhn-user and --rhn-pw options are used. RHN
  registration is required for the Ambari installation. If the --rhn-* options
  are not specified, it is assumed that the servers have been manually registered
  prior to running install.sh. If not, the installation will fail.

  Also:
  - passwordless SSH is required between the installation node and each storage
    node. See the Addendum at the end of this document if you would like to see 
    instructions on how to do this.
  - the correct version of RHS has been installed on each node per RHS
    guidelines. Essentially, the RHS 2.0.5 ISO just needs to be installed with the  
    hostname configured with a static IP address. Do not create a gluster volume.
  - a RAID 6 data partition has been created for use as the storage brick within 
    gluster. This is usually created as /dev/sdb
  - the order of the nodes in the "hosts" file is in replica order

== Installation ==

Instructions:
 0) upload rhs-ambari-install-<version> tarball to the deployment directory on
    the "install-from" node. It is usually convenient if the "install-from"
    node is also the Ambari server (management) node, but this is not required
 1) extract tarball to the local directory:
    $ tar xvzf rhs-ambari-install-<version>.tar.gz
 2) cd to the extracted rhs-ambari-install directory:
    $ cd rhs-ambari-install-<version>
 3) execute "install.sh" from the install directory:
    $ ./install.sh [options (see --help)] <brick-dev> (note: brick_dev is 
                                                       required)
    For example: ./install.sh /dev/sdb

    Output is displayed on STDOUT and is also written to /var/log/RHS-install 
    on both the delpoyment node and on each data node in the cluster.
 4) The script should complete at which point the rest of the installation 
    process is completed via the browser using the Ambari Installation 
    Instructions below.

Ambari Installation Instructions:

 1) Verify the Ambari processes started successfully

    After the ambari-server and ambari-agent(s) have successfully installed and 
    started,  use the Ambari Wizard tool to configure the cluster.

    Verify their status by issuing the following commands

    On the server node: ambari-server status
    On the agent node(s): ambari-agent status

    If the commands do not return a positive confirmation start the components 
    via the command line

    On the server node: ambari-server start
    On the agent node(s): ambari-agent start

 2) Wizard Install
 
    Note: If you wish to see a visual guide which includes screenshots for this 
    process, please refer to the Ambari_Configuration_Guide.pdf that was
    packaged with the rhs-ambari-install-<version> tar ball.

    Open a web browser and point the URL to the ambari-server hostname in the 
    following format

    http://<ambari-server hostname>:8080

    Once the login screen loads use admin/admin for the credentials and press 
    the Sign In button.

    Step 1: Welcome: Assign a name to your Cluster
    Step 2: Select Stack: Select the HDP 1.3.2 Stack
    Step 3: Install Options: 
    
    *** Target Hosts: Enter one host per line including the hosts used for 
        the install if it is part of the Storage Pool. 
        
    *** Host Registration Information: Select ‘Perform Manual Registration on 
        hosts, do not use SSH’.
	You will get a pop-up warning. The manual install of the agents was 
        completed by the install.sh script.  No addition action needs to take 
        place. Select OK and continue.

    *** Advanced Options: Do not select any values in this section.

    Select "Register and Confirm" to continue to the following screen.  You will 
    receive another pop-up about manually registering your Ambari-agents. This 
    has already been completed, select OK to continue

    Step 4:  Confirm Hosts: Confirm all the hosts you entered from the previous 
    page are present. The system will now register the hosts in the cluster.  
    Select Next once the registration process is complete.

    Step 5: Choose Services: First press the minimum link to remove any 
    unnecessary services. Then select at minimum HCFS and MapReduce.  Then click 
    next.  Note, if you do not select Nagios and/or Ganglia you will receive a 
    pop-up warning of limited functionality.  Select OK to continue.

    Step 6: Assign Masters: Chose which services you want to run on each host.  
            Select Next when finished

    Step 7: Assign Slaves and Clients: Chose which components you want on each 
    hosts. Select the check box to put the HCFS client on all the nodes.

    Step 8: Customize Services: For the HCFS tab you can accept the defaults. 
    If you have chosen to install Nagios you will need to enter a password and 
    email for alerts.  Under the MapReduce tab, remove the current values for 
    mapred.local.dir and set it to /mnt/brick1/mapredlocal.  Select Next to continue.

    Step 9: Review: Make sure the services are what you selected in the previous 
    steps. Select Deploy to continue.  Hadoop is successfully deployed and configured 
   once the process completes!

    Step 10: Set the permissions in RHS for the mapped user
             Change directory to the /mnt/glusters: cd /mnt/glusterfs
             Set the permissions: chown -R mapred:hadoop user/

 3) Validate the Installation

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
  
   This provides information on how to setup password-less SSH from the Ambari 
   Management Server to all the servers in your RHS Cluster.

	On the Ambari Management Server, run the following command:

	ssh-keygen 

	(Hit Enter to accept all of the defaults)

	On the Ambari Management Server, run the following command for each server. 

	ssh-copy-id -i ~/.ssh/id_rsa.pub root@<hostname>

	For example, if you had four servers in your cluster with the hostnames svr1, 
        svr2, svr3 and svr4 and svr1 is your Ambari Management Server, then you would 
        run the following commands from svr1 after you had run ssh-keygen:

	ssh-copy-id -i ~/.ssh/id_rsa.pub root@svr1
	ssh-copy-id -i ~/.ssh/id_rsa.pub root@svr2
	ssh-copy-id -i ~/.ssh/id_rsa.pub root@svr3
	ssh-copy-id -i ~/.ssh/id_rsa.pub root@svr4
	
	Lastly, verify you can ssh from the Ambari Management Server to all the other 
        servers without being prompted for a password.

2) Installing Red Hat Storage 2.0.5

   The “Red Hat Storage 2.0 Installation Guide” describes the prerequisites and provides 
   step-by-instructions to install Red Hat Storage. It is available in HTML 
   (https://access.redhat.com/site/documentation/en-US/Red_Hat_Storage/2.0/html/Installation_Guide/index.html)  
   and is also available as a PDF.  

   The RHS 2.0 Administration Guide is available at: 
   https://access.redhat.com/site/documentation/en-US/Red_Hat_Storage/2.0/html/Installation_Guide/index.html 

   Additional RHS documentation, including release notes and installation instructions are available here: 
   https://access.redhat.com/site/documentation/Red_Hat_Storage/. 

   Exceptions to the RHS 2.0 Installation Guide:

     * 4.1.2 – set up static IP addresses, not DHCP.

     * 4.1.4 – chose a “custom layout” to create a dedicated storage partition. You want to have already set 
               up a RAID 6 device for this partition.

   Exceptions to the RHS 2.0 Administration Guide:

     * skip all of section 7 -- don't create a trusted storage pool.

     * skip all of section 8 – don't create volumes.

     * the RHS-HDP installation configures volumes for optimal performance with Hadoop workloads.

     * the rest of the above guide can be read but not acted upon.
