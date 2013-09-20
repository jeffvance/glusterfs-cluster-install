#! /bin/bash
#
# This script creates the install tarball package. Currently this includes the
# following files:
#  * rhs-ambari-install-<verison> directory whicn contains:
#  - install.sh
#  - README.txt
#  - hosts.example
#  - Ambari_Configuration_Guide.pdf (not .odt version)
#  - data/: directory containing:
#    - prep_node.sh
#    - gluster-hadoop-<version>.jar
#    - fuse-patch.tar.gz
#    - ambari.repo
#    - ambari-<version>.rpms.tar.gz
#
# The Ambari_Configuration_Guide.pdf file is exported from the git
# Ambari_Installation_Guide.odt file prior to creating the tarball.
#
# This script is expected to be run from a git repo so that source version
# info can be used in the tarball filename. The --source and --target-dir
# options support running the script elsewhere.
#
# There are no required command line args. All options are described in the
# usage() function.


# usage: echo the standard usage text with supported options.
#
function usage(){

  echo -e "\nThis script converts the install guide .odt document file to pdf (if the"
  echo "doc file is present) and creates the RHS-Ambari install tarball package. There"
  echo "are no required parameters."
  echo
  echo "SYNTAX:"
  echo
  echo "  --source     : the directory containing the source files used to create the"
  echo "                 tarball (including the .odt doc file). It is expected that a"
  echo "                 git clone or git pull has been done into the SOURCE directory."
  echo "                 Default is the current working directory."
  echo "  --target-dir : the produced tarball will reside in this directory. Default is"
  echo "                 the SOURCE directory."
  echo "  --odt-doc    : the name of the  install guide .odt doc file. Default is"
  echo "                 \"Ambari_Configuration_Guide\""
  echo "  --pkg-version: the version string to be used as part of the tarball filename."
  echo "                 Default is the most recent git version in the SOURCE dir."
  echo
}

# parse_cmd: getopt used to do general parsing. See usage function for syntax.
#
function parse_cmd(){

  local OPTIONS='h'
  local LONG_OPTS='source:,target-dir:,pkg-version:,odt-doc:,help'

  # defaults (global variables)
  SOURCE=$PWD
  TARGET=$SOURCE
  PKG_VERSION=''
  ODT_DOC='Ambari_Configuration_Guide'

  local args=$(getopt -n "$(basename $0)" -o $OPTIONS --long $LONG_OPTS -- $@)
  (( $? == 0 )) || { echo "$SCRIPT syntax error"; exit -1; }

  eval set -- "$args" # set up $1... positional args
  while true ; do
      case "$1" in
        -h|--help)
	   usage; exit 0
	;;
	--source)
	   SOURCE=$2; shift 2; continue
	;;
	--target-dir)
	   TARGET=$2; shift 2; continue
	;;
	--pkg-version)
	   PKG_VERSION=$2; shift 2; continue
	;;
	--odt-doc)
	   ODT_DOC=$2; shift 2; continue
	;;
        --)  # no more args to parse
	   shift; break
        ;;
        *) echo "Error: Unknown option: \"$1\""; exit -1
        ;;
      esac
  done

  # note: supplied version arg trumps git tag/versison
  [[ -z "$PKG_VERSION" && -d ".git" ]] && \
	PKG_VERSION=$(git describe --abbrev=0 --tag)
  [[ -n "$PKG_VERSION" ]] && PKG_VERSION=${PKG_VERSION//./_} # x.y -> x_y
  [[ -z "$PKG_VERSION" ]] && { \
	echo "ERROR: package version not supplied and no git environment present.";
	exit -1; }

  # verify source and target dirs
  [[ -d "$SOURCE" ]] || { \
	echo "ERROR: \"$SOURCE\" source directory missing."; exit -1; }
  [[ -d "$TARGET" ]] || { \
	echo "ERROR: \"$TARGET\" target directory missing."; exit -1; }
}

# convert_odt_2_pdf: if possible convert the .odt doc file in the user's cwd
# to a pdf file using libreoffice. Report warning if this can't be done.
#
function convert_odt_2_pdf(){

  # user can provide docfile.odt or just docfile w/o .odt
  ODT_DOC=${ODT_DOC%.odt} # remove .odt extension if present

  local ODT_FILE="$ODT_DOC.odt"
  local PDF_FILE="$ODT_DOC.pdf"
  local f

  echo -e "\n  - Converting \"$ODT_FILE\" to pdf..."

  f=$(ls $ODT_FILE)
  if [[ -z "$f" ]] ; then
    echo "WARN: $ODT_FILE file does not exist, skipping this step."
  else
    libreoffice --headless --invisible --convert-to pdf $ODT_FILE	
    if [[ $? != 0 || $(ls $PDF_FILE|wc -l) != 1 ]] ; then
      echo "WARN: $ODT_FILE not converted to pdf."
    fi
  fi
}

# create_tarball: create a versioned directory in the user's cwd, copy the
# target contents to that dir, create the tarball, and finally rm the
# versioned dir.
#
function create_tarball(){

  # tarball contains the rhs-ambari-install-<version> dir, thus we have to copy
  # target files under this dir, create the tarball and then rm the dir
  local TARBALL_PREFIX="rhs-ambari-install-$PKG_VERSION"
  local TARBALL="$TARBALL_PREFIX.tar.gz"
  local TARBALL_DIR="$TARBALL_PREFIX" # scratch dir not TARGET dir
  local TARBALL_PATH="$TARBALL_DIR/$TARBALL"
  local FILES_TO_TAR=(install.sh README.txt hosts.example '*.pdf' data/)
  local f

  echo -e "\n  - Creating $TARBALL tarball in $TARGET"
  [[ -e $TARBALL ]] && /bin/rm $TARBALL

  # create temp tarball dir and copy subset of content there
  [[ -d $TARBALL_DIR ]] && /bin/rm -rf $TARBALL_DIR
  /bin/mkdir $TARBALL_DIR
  for f in "${FILES_TO_TAR[@]}" ; do
    /bin/cp -R $f $TARBALL_DIR
  done

  /bin/tar cvzf $TARBALL $TARBALL_DIR
  if [[ $? != 0 || $(ls $TARBALL|wc -l) != 1 ]] ; then
    echo "ERROR: creation of tarball failed."
    exit 1
  fi
  /bin/rm -rf $TARBALL_DIR

  # move tarball file to TARGET dir
  [[ "$TARGET" == "$PWD" ]] || mv $TARBALL $TARGET
}


## main ##
##
parse_cmd $@

echo -e "This script converts the existing .odt doc file to pdf and then creates"
echo "a tarball containing the install package."
echo
echo "  Source dir:  $SOURCE"
echo "  Target dir:  $TARGET"

convert_odt_2_pdf
create_tarball

echo
#
# end of script
