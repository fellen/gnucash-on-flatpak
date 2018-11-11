function cleanup()
{
  if [[ -n "$host" ]]
  then
    upload_build_log
  fi
  exit
}

function usage()
{
  {
    echo "Usage: $0 [-r <revision>] [-u <remote>]"
    echo "       $0 -h"
    echo
    echo "-h          display this help message"
    echo
    echo "-r revision git revision to build. Can be a branch or a tag."
    echo "            Note this branch or tag should exist in both the gnucash"
    echo "            and the gnucash-docs repository used for this build."
    echo "            Default: 'maint'"
  } 1>&2
  exit 1
}

function upload_build_log()
{
  if [[ -n "$host" ]]
  then
    echo "Uploading log file '$log_file'"
    rsync -a "$log_file" "$host"/build-logs
  fi
}

function prepare_repo()
{
  pushd "${repodir}"
  echo "Update repository $repodir"
  git fetch
  git checkout $revision
  if git tag | grep -q "^$revision\$"
  then
    echo "Detected a tag (release) build"
    is_release="yes"
  else
    echo "No tag detected, assuming development build"
    git reset --hard origin/$revision
  fi
  popd
}

function get_versions()
{
  echo "Extracting version numbers for package $package"
  pushd "${repodir}"
  # code uses cmake, docs is still on autotools...
  #if [ -e CMakeLists.txt ]
  #then
  #  gc_version=$(grep '(PACKAGE_VERSION ' CMakeLists.txt | perl -pe 's/.*([0-9]+\.[0-9]+).*\)/$1/ge')
  #else
  #  gc_version=$(grep AC_INIT configure.ac | perl -pe 's/.*([0-9]+\.[0-9]+).*\)/$1/ge')
  #fi
  gc_commit=$(git reflog | head -n1 | awk '{print $1}')
  #gc_full_version=${gc_version}-nightly.git.${gc_commit}
  gc_full_version=$(git describe)
  popd
}

function get_checksums()
{
  wget "http://downloads.sourceforge.net/gnucash/gnucash (stable)/${revision}/README.txt" -O "${base_dir}"/README.txt
  code_checksum=$(awk "/gnucash-${revision}.tar.bz2/ { print \$1;}" "${base_dir}"/README.txt)
  docs_checksum=$(awk "/gnucash-docs-${revision}.tar.gz/ { print \$1;}" "${base_dir}"/README.txt)
}

function prepare_gpg()
{
  # gpg_parms will hold optional gpg parameters passed to flatpak commands later on
  gpg_parms=""
  if [[ -n "$gpg_key" ]]
  then
    gpg_parms="--gpg-sign=$gpg_key"
    if [[ -n "$gpg_dir" ]]
    then
      gpg_home="--homedir=$gpg_dir"
      gpg_parms="--gpg-homedir=$gpg_dir $gpg_parms"
    fi
    gpg2 "$gpg_home" --export $gpg_key > "$base_dir"/gnucash-flatpak.gpg

    if [[ -n "$host" ]]
    then
      echo "Uploading GPG public key 'gnucash-flatpak.gpg'"
      rsync -a "$base_dir"/gnucash-flatpak.gpg "$host"
    fi
    gpg_key64=$(base64 "$base_dir"/gnucash-flatpak.gpg | tr -d '\n')
  fi
}

function create_manifest()
{
  echo "Writing org.gnucash.GnuCash.json manifest file"

  # Export environment variables used in the templates in order for envsubst to find them
  export code_repodir docs_repodir code_checksum docs_checksum revision

  # In the functions below build_type selects the proper templates to initiate
  # a git or a tar build. build_type is determined earlier in build_package.sh
  extra_deps=
  if [[ -f "$fp_git_dir"/templates/extra-deps-${build_type}.json.tpl ]]; then
      extra_deps=$(cat "$fp_git_dir"/templates/extra-deps-${build_type}.json.tpl)
  fi
  gnucash_targets=
  if [[ -f "$fp_git_dir"/templates/gnucash-targets-${build_type}.json.tpl ]]; then
      # Note the variable names passed to envsubst:
      # this limits the set of variables envsubst will effectively substitute
      # We do this to prevent colisions with flatpak variables in the manifest
      gnucash_targets=$(envsubst '$code_repodir $docs_repodir $revision $code_checksum $docs_checksum' \
                        < "$fp_git_dir"/templates/gnucash-targets-${build_type}.json.tpl)
  fi
  export extra_deps gnucash_targets

  # Note the variable names passed to envsubst:
  # this limits the set of variables envsubst will effectively substitute
  # We do this to prevent colisions with flatpak variables in the manifest
  envsubst '$extra_deps $gnucash_targets' \
           < "$fp_git_dir"/templates/org.gnucash.GnuCash.json.tpl \
           > "$fp_git_dir"/org.gnucash.GnuCash.json
}

function setup_sdk()
{
    echo "Configuring flathub repository"
    flatpak remote-add --user --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo

    # Extract the required sdk from the config file
    runtime_base=$(perl -lne 'm|"runtime".*"(.*)"|g&&print "$1"' "$fp_git_dir"/org.gnucash.GnuCash.json)
    runtime_ver=$(perl -lne 'm|"runtime-version".*"(.*)"|g&&print "$1"' "$fp_git_dir"/org.gnucash.GnuCash.json)
    sdk_base=$(perl -lne 'm|"sdk".*"(.*)"|g&&print "$1"' "$fp_git_dir"/org.gnucash.GnuCash.json)
    runtime=$runtime_base//$runtime_ver
    sdk=$sdk_base//$runtime_ver
    flatpak install -y --user flathub $sdk $runtime
}

function create_flatpakref()
{
  fp_ref_file=gnucash-$fp_branch.flatpakref
  if [[ -n "$host_public" ]] || [[ -n "$gpg_key" ]]
  then
    echo "Writing $fp_ref_file"
    fp_ref_dir_local="$base_dir"/flatpakrefs
    mkdir -p "$fp_ref_dir_local"
    cp "$fp_git_dir"/templates/gnucash.flatpakref.tpl "$fp_ref_dir_local"/$fp_ref_file
    echo "Branch=$fp_branch"         >> "$fp_ref_dir_local"/$fp_ref_file
    echo "Url=$host_public/$fp_repo" >> "$fp_ref_dir_local"/$fp_ref_file
    echo "GPGKey=$gpg_key64" >> "$fp_ref_dir_local"/$fp_ref_file
  else
    echo "Mandatory variable 'host_public' or 'gpg_key' is not set."
    echo "Skipping generation of $fp_ref_file"
    fp_ref_file=""
  fi
}
