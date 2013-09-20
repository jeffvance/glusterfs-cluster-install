#This script will copy the current git master to jenkins, to mock
#a proper jenkins build. And afterwards, it will copy the jenkins current
#build to s3 as a release. This entire process should actually run inside of
#jenkins, rather than as a manually run shell script.
 
#### First, define the build location. ####
# NOTE: this is an intermediate target tarball directory
BUILD_LOCATION=/var/lib/jenkins/workspace/Ambari
REPO=/root/archivainstall/apache-archiva-1.3.6/data/repositories/internal
SOURCE=$(pwd) #expected to be a git directory
S3='s3://rhbd/rhs-ambari-install'
TARBALL_PREFIX='rhs-ambari-install-'
TARBALL_SUFFIX='.tar.gz'

####### BUILD THE TAR/GZ FILE ~ THIS SHOULD RUN IN JENKINS (future) ####### 
cd $SOURCE
git pull

TAGNAME=$(git describe --abbrev=0 --tag)
TARBALL="$TARBALL_PREFIX${TAGNAME//./_}$TARBALL_SUFFIX" # s/./_/ in tag

#convert .odt to .pdf and create tarball
$SOURCE/devutils/mk_tarball.sh \
	--target-dir="$BUILD_LOCATION" \
	--pkg-version="$TAGNAME"

#git archive HEAD | gzip > $BUILD_LOCATION
cd /opt/JEFF/  ##why??

echo "Done archiving $TAGNAME to $BUILD_LOCATION..." 
ls -alth $BUILD_LOCATION 
echo
echo "Proceed? <ENTER>"
read 
#### NOW RUN SOME TESTS against the tar file (again, should run in jenkins) ##### 
/opt/JEFF/shelltest.sh ### <-- dummy script.
result=$?
echo "Test result = $result press any key to continue..."
if [[ ! $result == 0 ]]; then
      echo "Tests FAILED ! "
      exit 1
else
   echo "TEST PASSED !!!! DEPLOYING $TAGNAME !"
fi
 
### IF TESTS PASSED, we PROCEED WITH THE DEPLOYMENT !!! (yup - jenkins should run this to :) ### 

#First deploy into s3: This is the preferred (but new) place where we store binaries:

# Now, we deploy into archiva.
#TARBALL=$(ls -Rt $BUILD_LOCATION/rhs-ambari-*.tar.gz | head -1 | cut -f 9 -d' ')
#TARBALL=$(basename $TARBALL) #<-- doesnt work out of the box on some linux

echo
echo "Press a key to deploy to $TARBALL in $S3."
echo "Note that you need to run: \"s3cmd --configure\" the first time you do"
echo "this or pass the -c option."
echo "    build   -> $BUILD_LOCATION"
echo "    tarball -> $TARBALL"
echo "    s3      -> $S3"
echo "Proceed? <ENTER>"
read
s3cmd put $BUILD_LOCATION/$TARBALL $S3/$TARBALL
(( $? == 0 )) && echo "Your tarball is now deployed to : $S3/$TARBALL"
exit

#Not using mvn now since using s3, but may later...
#sudo mvn deploy:deploy-file \
#-Dfile=$BUILD_LOCATION/$TARBALL \
#-Durl=file:$REPO \
#-DgroupId=rhbd \
#-DartifactId=rhs-ambari-install \
#-Dversion=$TAGNAME 

#The artifact has been created here: (after stripping tar.gz extension)
#BASEARTIFACT=$REPO/rhbd/rhs-ambari-install/$TAGNAME/${TARBALL//.tar.gz/}
#BASEARTIFACT=${BASEARTIFACT//_/.} # change version "_" back to "."

#But since maven doesnt support the tar.gz, we must move it to be a tar.gz file
#sudo mv ${BASEARTIFACT_NOTARGZ}.gz $BASEARTIFACT
#sudo chmod -R 777 $BASEARTIFACT
#sudo ls -altrh $BASEARTIFACT
########################################

#echo "Done ! The file will now be in archiva at http://23.23.239.119/archiva/repository/internal/rhbd/rhs-ambari-install/"

