#!/bin/bash -ex
#
# Copyright 2019 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

# Process command line arguments.
while [ "$1" != "" ]; do
  case $1 in
    --install-android-emulator)
      install_android_emulator=1
      ;;
  esac
  shift
done

# Check for lsb_release command in $PATH.
if ! which lsb_release > /dev/null; then
  echo "ERROR: lsb_release not found in \$PATH" >&2
  exit 1;
fi

# Check if the distro is supported.
distro_codename=$(lsb_release --codename --short)
distro_id=$(lsb_release --id --short)
supported_codenames="(xenial|artful|bionic|cosmic|focal|bookworm)"
supported_ids="(Debian|Ubuntu)"
if [[ ! $distro_codename =~ $supported_codenames &&
      ! $distro_id =~ $supported_ids ]]; then
  echo -e "ERROR: The only supported distros are\n" \
    "\tUbuntu 16.04 LTS (xenial)\n" \
    "\tUbuntu 17.10 (artful)\n" \
    "\tUbuntu 18.04 LTS (bionic)\n" \
    "\tUbuntu 18.10 LTS (cosmic)\n" \
    "\tUbuntu 20.04 LTS (focal)\n" \
    "\tDebian 12 (bookworm)\n" \
    "\tDebian 8 (jessie) or later" >&2
  exit 1
fi

# Check if the architecture is supported.
if ! uname -m | egrep -q "i686|x86_64"; then
  echo "Only x86 architectures are currently supported" >&2
  exit
fi

# Add deadsnakes PPA for Python 3.11 on Debian
if [ "$distro_id" == "Debian" ]; then
    sudo apt-get update
    sudo apt-get install -y software-properties-common
    sudo add-apt-repository -y ppa:deadsnakes/ppa
fi

# Install base system dependencies
sudo apt-get update
sudo apt-get install -y \
    blackbox \
    curl \
    unzip \
    xvfb \
    apt-transport-https \
    software-properties-common \
    python3.11 \
    python3.11-dev \
    python3-distutils \
    python3.11-venv \
    python3-yaml \
    g++ \
    make \
    cmake \
    libssl-dev \
    zlib1g-dev \
    libffi-dev \
    pipenv

# Add unstable repository and pinning for openjdk-11-jdk
sudo bash -c 'cat > /etc/apt/preferences.d/openjdk-11-jdk << EOF
Package: openjdk-11-jdk
Pin: release a=unstable
Pin-Priority: 1001
EOF'

sudo bash -c 'cat > /etc/apt/sources.list.d/unstable.list << EOF
deb http://deb.debian.org/debian unstable main non-free contrib
EOF'

if [ "$distro_codename" == "rodete" ]; then
  glogin
  sudo glinux-add-repo docker-ce-"$distro_codename"
else
  # Remove existing key file if it exists
  sudo rm -f /usr/share/keyrings/docker-archive-keyring.gpg
  
  curl -fsSL https://download.docker.com/linux/${distro_id,,}/gpg | \
      sudo gpg --dearmor -o /usr/share/keyrings/docker-archive-keyring.gpg

  sudo bash -c "cat > /etc/apt/sources.list.d/docker.list << EOF
deb [arch=amd64 signed-by=/usr/share/keyrings/docker-archive-keyring.gpg] https://download.docker.com/linux/${distro_id,,} $distro_codename stable
EOF"

  export CLOUD_SDK_REPO="cloud-sdk"
  export APT_FILE=/etc/apt/sources.list.d/google-cloud-sdk.list
  export APT_LINE="deb [signed-by=/usr/share/keyrings/google-cloud-sdk.gpg] https://packages.cloud.google.com/apt $CLOUD_SDK_REPO main"
  sudo bash -c "grep -x \"$APT_LINE\" $APT_FILE || (echo $APT_LINE | tee -a $APT_FILE)"

  # Only download and install key if it doesn't exist
  if [ ! -f "/usr/share/keyrings/google-cloud-sdk.gpg" ]; then
    curl -fsSL https://packages.cloud.google.com/apt/doc/apt-key.gpg | \
        sudo gpg --dearmor -o /usr/share/keyrings/google-cloud-sdk.gpg
  fi
fi

# Install apt-get packages.
sudo apt-get update
sudo apt-get install -y \
    docker-ce \
    google-cloud-cli \
    google-cloud-cli-app-engine-go \
    google-cloud-cli-app-engine-python \
    google-cloud-cli-app-engine-python-extras \
    google-cloud-cli-datastore-emulator \
    google-cloud-cli-pubsub-emulator \
    openjdk-11-jdk \
    liblzma-dev \
    patchelf

# Set Python version
export PYTHON='python3.11'

dir=$(dirname "$0")
"$dir"/install_python_deps_linux.bash $*
