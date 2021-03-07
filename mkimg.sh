#!/bin/bash

set -ex

print_usage() {
    cat <<EOF
usage: $0 [remote=<host:path>] [rebuild] [prepare|build|package] \\
                [dist=<xenial|bionic>] [dist-ver=<ubuntu version>] \\
                [docker|conda ...]

remote: copy this repository through ssh to host:path, and then run the script
        on remote host, copy back built output image, and delete the image on
        remote host.

rebuild: delete any previously built source and binary package, and rebuild

prepare|build|package:

    prepare: prepare the building env and source tree without compiling

    build: compile only without packaging

    package: package only without compiling

If no [prepare|build|package] specified, the default behavior is to make sure
repo is up to date, compile if updated, and then make the package.

If everything runs fine, the final result will be located in build/out

dist: when doing linux build, this specifies the target distribution, currently
      only support xenial or bionic, default to bionic

dist-ver: specify the exact distribution version, only used when building linux
          AppImage using docker, for pulling the exact docker image.

docker[=<docker_image_name>]: specify building linux AppImage using docker. You
                              can optional set a customized name for the docker
                              image, e.g. docker=my-docker. If not given the
                              default docker image name is <dist>-fc-dev. So
                              for bionic distribution, the name is bionic-fc-dev.
                              When building docker with docker, the following
                              optional arguments are supported,

    dockerfile=<path to Dockfile>: optional customized docker image recipe.

    sudo: use sudo to run docker command

    run[=<path_to_app_image>]: instead of building, run an AppImage using the
                               docker image.  If no path to image is given, it
                               launches the docker container with the bash
                               shell. The home directory is mapped into the
                               container as /shared.

    podman: use podman instead of docker to run container

conda[=<conda_docker_name>]: build and package using conda-build. On linux, the
                             conda envionment runs inside a docker container.
                             And you can supply an optional docker image name
                             for that, default to 'conda-fc-dev'. On MacOSX,
                             conda is used natively. 
                             
                             The following additional arguments are supported,

    conda-recipes=<path_to_recipes>: conda recipes to build. If more than one
                                      recipe is given, separate them with space
                                      and use quote. If no recipes is given, it
                                      builds all recipes in 'conda' directory.

    sudo: in case of running conda inside docker, you may have to launch the
          docker container using sudo.

    podman: use podman instead of docker to run container

    fetch: sync conda build working copy of FreeCAD source using git fetch

py3: specify building FreeCAD python3. This argument is only used when building
     windows package, which uses the newer Libpack 12 with Visual Studio 2017.
EOF
}

mkdir -p build/out

docker=
docker_exe=docker
docker_run="$docker_exe run"
dockerfile=
dist=bionic
dist_ver=
conda=
conda_recipes=../../../conda
build=2
args=
run=
sudo=
rebuild=
py3=
gitfetch=
daily=
forcedaily=
sudopass="$FMK_SUDOPASS"
while test $1; do
    arg=$1
    case "$arg" in
        remote=*)
            remote=${arg#*=}
            shift
            continue
            ;;
        py3)
            py3=1
            ;;
        sudo)
            sudo=sudo
            ;;
        sudofile=*)
            sudopass=`cat ${arg#*=} | base64`
            shift
            continue
            ;;
        fetch)
            gitfetch=1
            ;;
        conda)
            conda=${arg#*=}
            if [ $conda = conda ]; then
                conda=conda-fc-dev
            fi
            ;;
        conda-recipes=*)
            conda_recipes=${arg#*=}
            ;;
        dockerfile=*)
            dockerfile=${arg#*=}
            if which readlink; then
                dockerfile=`readlink -e "$dockerfile"`
            fi
            ;;
        docker|docker=*)
            docker=${arg#*=}
            ;;
        podman)
            docker_exe=podman
            docker_run="podman run --userns=keep-id --security-opt label=disable"
            ;;
        dist=*)
            dist=${arg#*=}
            ;;
        dist-ver=*)
            dist_ver=${arg#*=}
            ;;
        run*)
            run=${arg#*=}
            ;;
        rebuild)
            rebuild=1
            ;;
        build)
            build=1
            ;;
        prepare)
            build=0
            ;;
        package)
            build=3
            ;;
        daily)
            daily="-Daily"
            ;;
        forcedaily)
            daily="-Daily"
            forcedaily=1
            ;;
        help)
            print_usage
            exit
            ;;
        *)
            echo unknown argument $arg
            print_usage
            exit 1
    esac
    args+=" $arg"
    shift
done

if test $sudo && test "$sudopass"; then
    sudo="echo "$sudopass" | base64 -d | sudo -S -k"
fi

img_name=${FMK_IMG_NAME:=img}

repo_url=${FMK_REPO_URL:=https://github.com/FreeCAD/FreeCAD}
repo_branch=${FMK_REPO_BRANCH:=master}

dpkg_url=${FMK_DPKG_URL:=https://github.com/realthunder/fcad-packaging.git}
dpkg_branch=${FMK_DPKG_BRANCH:=$dist}

aimg_url=${FMK_AIMG_URL:=https://github.com/realthunder/AppImages.git}
aimg_branch=${FMK_AIMG_BRANCH:=master}
aimg_recipe=${FMK_AIMG_RECIPE:=recipe-$dist.yml}

prepare_remote() {
    # copy Version.h header and make sure it works for local and remote build
    if test "$FMK_VERSION_HEADER"; then
        if ! test -f "$FMK_VERSION_HEADER"; then
            echo "Cannot find version header: $FMK_VERSION_HEADER"
            exit 1
        fi
        cp -f "$FMK_VERSION_HEADER" ./Version.h
        if test $conda; then
            export FMK_VERSION_HEADER="../../../Version.h"
        else
            export FMK_VERSION_HEADER="../../Version.h"
        fi
    fi

    # create a temperary script and export all the environment variables, this is
    # to prepare for either remote (ssh) build or docker build

    echo "#!/bin/bash" > tmp.sh
    chmod +x tmp.sh
    set +x
    if test -z "$FMK_CONDA_IMG_NAME"; then
        date=$(date +%Y%m%d)
        export FMK_CONDA_IMG_NAME=FreeCAD-$img_name$daily-Conda-Py3-Qt5-$date.glibc2.12-x86_64
    fi
    env | while read -r line; do
        if [ "${line:0:4}" = FMK_ ]; then
            name=${line%=*}
            if [ "$name" != "FMK_SUDOPASS" ]; then
                echo "export $name=\"${line#*=}\"" >> tmp.sh
            fi
        fi
    done
    set -x
    echo "./mkimg.sh $args" >> tmp.sh
}

if test "$docker"; then
    if ! test -f docker/${dist}_deps.sh; then
        echo unknown build dependency for dist $dist
        exit 1
    fi
    if [ "$docker" = docker ]; then
        docker="${dist}-fc-dev"
    fi
    if test -z "$dist_ver"; then
        case $dist in
        bionic)
            dist_ver=18.04
            ;;
        xenial)
            dist_ver=16.04
            ;;
        *)
            echo unknown dist version for $dist
            exit 1
        esac
    fi
    if test "$dockerfile"; then
        bash -c "$sudo $docker_exe build -t $docker -f $dockerfile $(dirname $dockerfile)"
    else
        cat << EOS > tmp.dockfile
FROM ubuntu:$dist_ver

COPY ${dist}_deps.sh .
COPY setup.sh .
RUN /setup.sh ${dist}_deps.sh $UID

USER freecad
WORKDIR /home/freecad

CMD ["/bin/bash"]
EOS
        bash -c "$sudo $docker_exe build -t $docker -f $tmp.dockfile ./docker"
    fi

    if test "$run"; then
        if [ "$run" != run ] && which readlink; then
            run=`readlink -e "$run"`
        fi
        if which xhost; then
            IP=$(ifconfig en0 | grep inet | awk '$1=="inet" {print $2}')
            xhost + $IP
            run_cmd="$docker_run --rm -it -e DISPLAY=${IP}:0 -v /tmp/.X11-unix:/tmp/.X11-unix \
                    -v "$run":/AppImage -v "$HOME":/shared --security-opt seccomp:unconfined ${docker} "
        else
            run_cmd="$docker_run --rm -it -v "$run":/AppImage -v "$HOME":/shared ${docker} "
        fi
        if [ "$run" = run ]; then
            bash -c "$sudo $run_cmd bash"
        else
            bash -c "$sudo $run_cmd bash -c \"/AppImage --appimage-extract && squashfs-root/AppRun\""
        fi
        exit
    fi

    prepare_remote
    mkdir -p ./build/out
    mkdir -p ./build/docker
    cd build/docker
    mkdir -p $docker
    find ../../ -maxdepth 1 -type f | xargs -I {} cp {} $docker/
    bash -c "$sudo $docker_run --rm -ti -v $PWD/$docker:/home/freecad/works -w /home/freecad/works \
        $docker bash -c ./tmp.sh"
    mv $docker/build/out/* ../out/
    exit
fi

if test $remote; then
    prepare_remote
    host=${remote%:*}
    path=${remote#*:}
    if test -z $host || [ "$path" = "$host" ]; then
        echo "invalid remote host or path"
        exit 1
    fi

    # cd to the directory containing this script
    dir="`dirname "${BASH_SOURCE[0]}"`"
    cd $dir

    # obtain the base directory name of this script, and
    # append it to remote <path>
    base=`basename "$PWD"`
    if test $path; then
        path=$path/$base
    else
        path=$base
    fi

    if test "$sudopass"; then
        sshcmd="FMK_SUDOPASS=${sudopass} ./tmp.sh"
    else
        sshcmd="./tmp.sh"
    fi


    # pipe current directory (excluding the build directory) through
    # tar -> ssh -> remote tar, and then run the script remotely
    #
    tar --exclude='./.git' --exclude='./build' -c . |
        ssh $host -C "mkdir -p $path;cd $path;tar xvf -;$sshcmd"

    [ $build -gt 1 ] || exit

    # tar pipe back the result and clean the remote computer
    ssh $host "cd $path/build/out && tar cf - . && rm -rf *" | tar xvf - -C ./build/out
    exit
fi

git_fetch() {
    local dir=$1
    local url=$2
    local branch=$3
    if ! test -d $dir; then
        git clone -b $branch --depth 1 --single-branch $url $dir
        pushd $dir
    else
        pushd $dir
        hash=$(git show -s --format=%H)
        remote_hash=$(git ls-remote $url $branch | awk '{ print $1 }')
        if [ "$hash" != "$remote_hash" ]; then
            git fetch --depth=1 origin $branch
            git checkout -qf FETCH_HEAD
        elif test -z $forcedaily && test $daily; then
            echo No new commits for daily build
            exit
        fi
    fi
    hash=$(git show -s --format=%H)
    popd
}

if test $conda; then
    build_dir=conda/$img_name
else
    build_dir=$img_name

    if test $rebuild; then
        rm -rf build/$build_dir
    fi
fi

mkdir -p build/$build_dir
cd build/$build_dir

# prepare freecad repo
git_fetch repo $repo_url $repo_branch

if test "$FMK_VERSION_HEADER"; then
    if ! test -f "$FMK_VERSION_HEADER"; then
        echo "Cannot find version header: $FMK_VERSION_HEADER"
        exit 1
    fi
    if ! cmp -s "$FMK_VERSION_HEADER" repo/src/Build/Version.h; then
        cp -f $FMK_VERSION_HEADER repo/src/Build/Version.h
    fi
else
    rm -f repo/src/Build/Version.h
fi

# save the last commit hash
repo_hash=$hash
# export shortend repo hash for later use during installation
export FMK_REPO_HASH=${hash:0:8}

# check for windows building
if [ "$PROGRAMFILES" != "" ]; then 

    pushd ../
    if [ "$PROCESSOR_ARCHITECTURE" != "AMD64" ]; then
        echo "only support building on Windows x64"
        exit 1
    fi

    # cmake=${FMK_CMAKE_EXE:=`echo /cygdrive/c/program\ files/*/bin/cmake.exe`}
    # if ! test -e "$cmake"; then
    #     echo "CMAKE_EXE not set properly"
    #     exit 1
    # fi

    echo 'building for windows...'

    get_cmake() {
        mkdir -p tools
        cmake_ver=$1
        cmake_name=cmake-$cmake_ver-win64-x64
        cmake=$PWD/tools/$cmake_name/bin/cmake.exe
        if ! test -e $cmake; then
            rm -rf tools/$cmake_name
            wget -c https://github.com/Kitware/CMake/releases/download/v$cmake_ver/$cmake_name.zip
            (cd tools && 7z x ../$cmake_name.zip)
        fi
    }

    if test $py3; then

        get_cmake "3.14.5"

        # url=${FMK_LIBPACK_URL:=https://github.com/FreeCAD/FreeCAD/releases/download/0.19_pre/FreeCADLibs_12.1.2_x64_VC15.7z}
        # vs=15
        # vs_name="15 2017"
        url=${FMK_LIBPACK_URL:=https://github.com/apeltauer/FreeCAD/releases/download/LibPack_12.4.2/FreeCADLibs_12.4.2_x64_VC17.7z}
        vs=17
        vs_name="16 2019"

        if ! test -d libpack$vs; then
            wget -c $url -O libpack$vs.7z
            mkdir -p libpack$vs
            (cd libpack$vs && 7z x ../libpack$vs.7z)
        fi

        build_name="Py3-Qt5"
    else
        get_cmake "3.10.3"

        # url=${FMK_LIBPACK_URL:=https://github.com/sgrogan/FreeCAD/releases/download/0.17-med-test/FreeCADLibs_11.5.3_x64_VC12.7z}
        url=${FMK_LIBPACK_URL:=https://github.com/FreeCAD/FreeCAD-ports-cache/releases/download/v0.18/FreeCADLibs_11.11_x64_VC12.7z}
        vs=
        vs_name="12 2013"
        if ! test -d libpack; then
            wget -c $url -O libpack.7z
            7z x libpack.7z
            mv FreeCADLibs* libpack
        fi

        build_name="Py2-Qt4"
    fi

    libpack=$(cygpath -w $PWD/libpack$vs)
    echo $libpack

    popd

    branding=$PWD/../../conda/branding
    mkdir -p repo/build$vs
    pushd repo/build$vs

    if ! test -f FreeCAD_trunk.sln; then
        export FREECAD_LIBPACK_DIR=$libpack
        "$cmake" \
            -G "Visual Studio $vs_name" -A x64 \
            -DFREECAD_LIBPACK_DIR=$libpack \
            -DOCC_INCLUDE_DIR=$libpack/include/opencascade \
            -DPYTHON_EXECUTABLE=$libpack/bin/python.exe \
            ..
    fi

    [ $build -gt 0 ] || exit
    
    if [ $build -ne 3 ]; then
        if test -f ../src/Build/Version.h && \
            ! cmp -s ../src/Build/Version.h src/Build/Version.h; then
            rm -rf src/Build/*
            mkdir -p src/Build
            cp ../src/Build/Version.h src/Build
        fi

        if test $FMK_BRANDING && test -f $branding/$FMK_BRANDING/build-setup.sh; then
            $branding/$FMK_BRANDING/build-setup.sh $branding/$FMK_BRANDING/ .
        fi


        # get cpu core count
        ncpu=$(grep -c ^processor /proc/cpuinfo)

        # start building
        "$cmake" --build . --config Release -- /maxcpucount:$ncpu
    fi

    [ $build -gt 1 ] || exit

    tmpdir=$PWD/../../tmp
    mkdir -p $tmpdir
    rm -rf $tmpdir/* ../../FreeCAD-$img_name*

    # copy `bin` folder from libpack

    pushd $libpack/bin
    exclude=bin_exclude.lst
    rm -f $exclude
    echo "generate exclude file list..."

    set +x
    find . -name '*.*' -print0 |
    while IFS= read -r -d '' file; do
        # filter <prefix>d.<ext> if <prefix>.<ext> exists
        #    or <prefix>_d.<ext> if <prefix>.<ext> exists
        #
        # TODO: this two conditions should be able to shorten using
        # optional character matching in regex, e.g. ${file%%?(_)d.dll}.
        # Strangely, it works only in terminal but not in script! Why??!!

        ext="${file: -3}"
        if [ "${file%-g*d-*\.dll}" != "$file" ] || \
            [ -f "${file%[Dd]\.$ext}.$ext" ] || \
            [ -f "${file%_[Dd]\.$ext}.$ext" ];
        then
            echo "$file" >> $exclude
        fi
    done
    echo "copying bin directory..."
    mkdir -p $tmpdir/bin
    tar --exclude 'h5*.exe' --exclude 'swig*' --exclude "*.pyc" \
        --exclude 'Qt*d4.dll' --exclude 'Qt*d5.dll' --exclude "*.pdb" \
        -X $exclude -cf - . | (cd $tmpdir/bin && tar xvBf -)
    set -x
    popd

    extra_dirs="plugins resources qml"
    for p in $extra_dirs; do
        if test -d $libpack/$p; then
            cp -a $libpack/$p $tmpdir
        fi
    done

    # copy out the result to tmp directory
    tar --exclude '*.pyc' --exclude '*.pdb' -cf - bin Mod Ext data | (cd $tmpdir && tar xvBf -)

    date=$(date +%Y%m%d)
    export FMK_BUILD_DATE=$date
    if test $FMK_BRANDING; then
        $branding/$FMK_BRANDING/install.sh $branding/$FMK_BRANDING/ $tmpdir
    fi

    cd $tmpdir

    # install personal workbench. This script will write version string to
    # ../VERSION file
    ../../../installwb.sh
    cd ..
    name=FreeCAD-$img_name$daily-Win64-$build_name-$date

    # archive the result
    mv tmp $name
    7z a ../out/$name.7z $name

    exit
fi

# building for mac
if [ $(uname) = 'Darwin' ]; then

    if test $conda; then
        rm -rf ./recipes
        cp -a $conda_recipes ./recipes
        conda_host=MacOSX
        conda_path=env
        . ./recipes/setup.sh

        repo_path=`ls -t env/conda-bld/freecad*/work/CMakeLists.txt 2> /dev/null | head -1`
        if test "$repo_path" && test -f "$repo_path"; then
            repo_path=`dirname $repo_path`
            version_file=repo/src/Build/Version.h
            if test -f $version_file; then
                build_ver=`ls -t env/conda-bld/freecad*/work/src/Build/Version.h 2> /dev/null | head -1`
                if ! cmp -s "$build_ver" $version_file; then
                    git_fetch $repo_path $repo_url $repo_branch
                    cp $version_file $repo_path/src/Build/Version.h
                fi
            elif test $gitfetch; then
                git_fetch $repo_path $repo_url $repo_branch
            fi
        fi

        # if test $FMK_BRANDING && test -f recipes/branding/$FMK_BRANDING/build-setup.sh; then
        #     build_dir=`ls -t conda-bld/*/work/ 2> /dev/null | head -1`
        #     build_dir=${build_dir%:}
        #     if test $build_dir; then
        #         recipes/branding/$FMK_BRANDING/build-setup.sh recipes/branding/$FMK_BRANDING/ $build_dir
        #     fi
        # fi

        if test -z $rebuild; then
            conda_cmd+=" --dirty "
        fi

        if [ $build -ne 3 ]; then
            $conda_cmd --no-remove-work-dir --keep-old-work ./recipes
        fi
        if [ $build -gt 0 ]; then
            date=$(date +%Y%m%d)
            app_path=FreeCAD-$img_name$daily-OSX-Conda-Py3-Qt5-$date-x86_64
            cd recipes
            cp -a MacBundle $app_path
            base_path=$app_path/FreeCAD.app/Contents/Resources
            export FMK_BUILD_DATE=$date
            ./install.sh $base_path
            if test $FMK_BRANDING; then
                branding/$FMK_BRANDING/install.sh branding/$FMK_BRANDING $base_path
            fi

            export FMK_WB_BASE_PATH=$base_path
            export FMK_REPO_VER_PATH="$base_path/VERSION"
            ../../../../installwb.sh

            # ver=$(conda run -p $base_path python get_freecad_version.py)

            out=../../../out/$app_path
            rm -f $out
            hdiutil create -fs HFS+ -srcfolder $app_path $out
        fi
        exit
    fi

    export CXX=clang++
    export CC=clang
    export PATH=/usr/lib/ccache:/usr/local/bin:$PATH

    mkdir -p repo/build
    pushd repo/build

    QT5_CMAKE_PREFIX=$(ls -d $(brew --cellar)/qt/*/lib/cmake)
    QT5_WEBKIT_CMAKE_PREFIX=$(ls -d $(brew --cellar)/qtwebkit/*/lib/cmake)
    INSTALL_PREFIX="../../tmp"
    mkdir -p "$INSTALL_PREFIX"

   if ! read rhash &>/dev/null < .configure.hash || [ "$rhash" != $repo_hash ]; then
        cmake \
        -DCMAKE_BUILD_TYPE="Release"   \
        -DBUILD_QT5=1                  \
        -DCMAKE_PREFIX_PATH="${QT5_CMAKE_PREFIX};${QT5_WEBKIT_CMAKE_PREFIX}"  \
        -DFREECAD_USE_EXTERNAL_KDL=1   \
        -DBUILD_FEM_NETGEN=1           \
        -DFREECAD_CREATE_MAC_APP=1     \
        -DCMAKE_INSTALL_PREFIX="$INSTALL_PREFIX"  \
        ../

        echo "$repo_hash" > .configure.hash
    fi

    [ $build -gt 0 ] || exit

    ncpu=$(sysctl hw.ncpu | awk '{print $2}')
    [ "$ncpu" != "1" ] || ncpu=2

    do_build=
    if ! read rhash &>/dev/null < .build.hash || [ "$rhash" != $repo_hash ]; then
        do_build=1
    fi
    if test $do_build; then
        if test -f ../src/Build/Version.h && \
            ! cmp -s ../src/Build/Version.h src/Build/Version.h; then
            rm -rf src/Build/*
            mkdir -p src/Build
            cp ../src/Build/Version.h src/Build
        fi
        make -j$ncpu
        echo "$repo_hash" > .build.hash
    fi

    [ $build -gt 1 ] || exit

    do_install=
    if ! read rhash &>/dev/null < .install.hash || [ "$rhash" != $repo_hash ]; then
        do_install=1
    fi
    test -z $do_install || make -j$ncpu install
    echo "$repo_hash" > .install.hash

    APP_PATH="$INSTALL_PREFIX/FreeCAD.app"
    export FMK_WB_BASE_PATH="$APP_PATH/Contents"
    export FMK_REPO_VER_PATH="$INSTALL_PREFIX/VERSION"

    ../../../../installwb.sh

    # name=FreeCAD-`cat $INSTALL_PREFIX/VERSION`-OSX-x86_64-Qt5
    date=$(date +%Y%m%d)
    name=FreeCAD-$img_name-OSX-Py2-Qt5-$date-x86_64
    echo $name
    rm -f ../../../out/$name.dmg
    hdiutil create -fs HFS+ -srcfolder "$APP_PATH" ../../../out/$name.dmg
    exit
fi

# building for linux

if test $conda; then
    docker_name=$conda
    date=$(date +%Y%m%d)
    conda_img_name="FreeCAD-$img_name$daily-Conda-Py3-Qt5-$date-glibc2.12-x86_64"

cat << EOS > tmp.dockfile 
FROM condaforge/linux-anvil-comp7

RUN yum install -y mesa-libGL-devel \
    && useradd -u $UID -ms /bin/bash conda \
    && echo 'conda:conda' |chpasswd
EOS
    bash -c "$sudo $docker_exe build -t $conda -f tmp.dockfile ."

    rm -rf recipes
    cp -a $conda_recipes recipes
    mkdir -p conda-bld cache

    repo_path=`ls -t conda-bld/freecad*/work/CMakeLists.txt 2> /dev/null | head -1`
    if test "$repo_path" && test -f $repo_path; then
        repo_path=`dirname $repo_path`
        version_file=repo/src/Build/Version.h
        if test -f $version_file; then
            build_ver=`ls -t conda-bld/freecad*/work/src/Build/Version.h 2> /dev/null | head -1`
            if ! cmp -s "$build_ver" $version_file; then
                git_fetch $repo_path $repo_url $repo_branch
                cp $version_file $repo_path/src/Build/Version.h
            fi
        elif test $gitfetch; then
            git_fetch $repo_path $repo_url $repo_branch
        fi
    fi

    # if test $FMK_BRANDING && test -f recipes/branding/$FMK_BRANDING/build-setup.sh; then
    #     build_dir=`ls -t conda-bld/*/work/ 2> /dev/null | head -1`
    #     build_dir=${build_dir%:}
    #     if test $build_dir; then
    #         recipes/branding/$FMK_BRANDING/build-setup.sh recipes/branding/$FMK_BRANDING/ $build_dir
    #     fi
    # fi

    if test "$run"; then
        if which xhost; then
            IP=$(ifconfig en0 | grep inet | awk '$1=="inet" {print $2}')
            xhost + $IP
            bash -c "$sudo $docker_run --rm -ti -v $PWD:/home/conda -e DISPLAY=${IP}:0 \
                -v /tmp/.X11-unix:/tmp/.X11-unix -v "$HOME":/shared \
                --security-opt seccomp:unconfined ${conda} bash"
        else
            bash -c "$sudo $docker_run --rm -ti -v $PWD:/home/conda -v "$HOME":/shared ${conda} bash"
        fi
        exit
    fi

    cat << EOS > tmp_build.sh
#/bin/bash
set -ex
export CONDA_BLD_PATH=/home/conda/conda-bld
export CONDA_PKGS_DIRS=/home/conda/pkgs
EOS
    chmod +x tmp_build.sh

    if [ $build -ne 3 ]; then
        echo 
        cmd="conda build --no-remove-work-dir --keep-old-work --cache-dir ./cache "
        if test -z $rebuild; then
            cmd+=" --dirty "
        fi
        cmd+="./recipes"
        echo "$cmd" >> tmp_build.sh
    fi
    if [ $build -gt 1 ]; then
        appdir=${FMK_CONDA_APPDIR:="AppDir_asm3"}
        rm -rf wb/*
        mkdir -p wb
        FMK_WB_BASE_PATH=wb ../../../installwb.sh

        cat << EOS >> tmp_build.sh
export FMK_CONDA_IMG_NAME=$conda_img_name
export FMK_CONDA_FC_EXTRA=/home/conda/wb
export FMK_BUILD_DATE=$date
export FMK_BRANDING=$FMK_BRANDING
export FMK_CONDA_REQUIRMENTS=$FMK_CONDA_REQUIRMENTS
rm -rf $appdir 
mkdir -p $appdir/usr
cp -a recipes/AppDir/* $appdir/
recipes/install.sh $appdir/usr appimage
EOS
    fi

    bash -c "$sudo $docker_run --rm -ti -v $PWD:/home/conda $conda ./tmp_build.sh"

    if [ $build -gt 1 ]; then
        mv ${conda_img_name}.AppImage* ../../out/
    fi

    exit
fi

if [ $build -ne 3 ]; then
    # prepare debain packaging repo
    rm -rf packaging
    git_fetch packaging $dpkg_url $dpkg_branch
    # obtain packaging repo last commit hash
    pkg_hash=$hash

    # copy packaging directory to freecad repo
    cp -a packaging/debian repo/

    pushd repo
    ncpu=$(grep -c ^processor /proc/cpuinfo)
    DEB_BUILD_OPTIONS="parallel=$ncpu" debuild -b -us -uc
    popd
fi

if [ $build -gt 1 ]; then
    # copy the recipe, and customize the name
    cp ../../$aimg_recipe .
    sed -i "s/#NAME#/$img_name/g" $aimg_recipe

    # prepare AppImages repo
    git_fetch AppImages $aimg_url $aimg_branch
    cd AppImages
    # now generate the AppImage using the recipe
    DEBDIR="$PWD/.." ARCH=x86_64 ./pkg2appimage ../$aimg_recipe

    date=$(date +%Y%m%d)
    if [ $dist = bionic ]; then
        build_name=Bionic-Py3n2-Qt5
    else
        build_name=Xenial-Py2-Qt4
    fi
    name=$(echo out/FreeCAD-$img_name*.AppImage)
    ext=${name#*glibc}
    mv $name ../../out/FreeCAD-$img_name-$build_name-$date.glibc$ext
fi

