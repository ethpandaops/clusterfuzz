#!/bin/bash -e
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

function run_bot () {
  serial=$1
  device_index=$2
  bot_directory=$INSTALL_DIRECTORY/bots/$(echo $serial | sed s/:/-/)

  # Recreate bot directory.
  rm -rf $bot_directory
  mkdir -p $bot_directory
  cp -r $INSTALL_DIRECTORY/clusterfuzz $bot_directory/clusterfuzz
  echo "Created bot directory $bot_directory."
  cd $bot_directory/clusterfuzz

  # Wait for device and run clusterfuzz indefinitely for this bot.
  while true; do
    $ADB_PATH/adb -s "$serial" wait-for-device

    echo "Running ClusterFuzz instance for bot $serial."
    OS_OVERRIDE="ANDROID" ANDROID_SERIAL="$serial" PATH="$PATH" GOOGLE_APPLICATION_CREDENTIALS="$GOOGLE_APPLICATION_CREDENTIALS" ROOT_DIR="$bot_directory/clusterfuzz" PYTHONPATH="$PYTHONPATH" GSUTIL_PATH="$GSUTIL_PATH" BOT_NAME="android-$(hostname)-$serial" HTTP_PORT_1="$((device_index+8000))" HTTP_PORT_2="$((device_index+8080))" python $bot_directory/clusterfuzz/src/python/bot/startup/run.py || true

    echo "ClusterFuzz instance for bot $serial quit unexpectedly. Waiting for device."
  done
}

if [ -z "$CLOUD_PROJECT_ID" ]; then
  echo "\$CLOUD_PROJECT_ID is not set."
  exit 1
fi

if [ -z "$GOOGLE_APPLICATION_CREDENTIALS" ]; then
  echo "\$GOOGLE_APPLICATION_CREDENTIALS is not set."
  exit 1
fi

GOOGLE_CLOUD_SDK=google-cloud-sdk
GOOGLE_CLOUD_SDK_ARCHIVE=google-cloud-sdk-232.0.0-linux-x86_64.tar.gz
INSTALL_DIRECTORY=${INSTALL_DIRECTORY:-${HOME}}
DEPLOYMENT_BUCKET=${DEPLOYMENT_BUCKET:-"$CLOUD_PROJECT_ID-deployment"}
DEPLOYMENT_ZIP="linux-3.zip"
GSUTIL_PATH="$INSTALL_DIRECTORY/$GOOGLE_CLOUD_SDK/bin"
ROOT_DIR="$INSTALL_DIRECTORY/clusterfuzz"
PYTHONPATH="$PYTHONPATH:$ROOT_DIR/src"
ADB_PATH="$ROOT_DIR/resources/platform/android"
PATH="$PATH:$ADB_PATH"

echo "Creating directory $INSTALL_DIRECTORY."
if [ ! -d "$INSTALL_DIRECTORY" ]; then
  mkdir -p "$INSTALL_DIRECTORY"
fi

cd $INSTALL_DIRECTORY

echo "Fetching Google Cloud SDK."
if [ ! -d "$INSTALL_DIRECTORY/$GOOGLE_CLOUD_SDK" ]; then
  curl -O "https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/$GOOGLE_CLOUD_SDK_ARCHIVE"
  tar -xzf $GOOGLE_CLOUD_SDK_ARCHIVE
  rm $GOOGLE_CLOUD_SDK_ARCHIVE
fi

echo "Activating credentials with the Google Cloud SDK."
$GSUTIL_PATH/gcloud auth activate-service-account --key-file=$GOOGLE_APPLICATION_CREDENTIALS

# Otherwise, gsutil will error out due to multiple types of configured
# credentials. For more information about this, see
# https://cloud.google.com/storage/docs/gsutil/commands/config#configuration-file-selection-procedure
echo "Specifying the proper Boto configuration file."
BOTO_CONFIG_PATH=$($GSUTIL_PATH/gsutil -D 2>&1 | grep "config_file_list" | egrep -o "/[^']+gserviceaccount\.com/\.boto") || true
if [ -f $BOTO_CONFIG_PATH ]; then
  export BOTO_CONFIG="$BOTO_CONFIG_PATH"
else
  echo "WARNING: failed to identify the Boto configuration file and specify BOTO_CONFIG env."
fi

echo "Downloading ClusterFuzz source code."
rm -rf clusterfuzz
$GSUTIL_PATH/gsutil cp gs://$DEPLOYMENT_BUCKET/$DEPLOYMENT_ZIP clusterfuzz-source.zip
unzip -q clusterfuzz-source.zip

echo "Installing ClusterFuzz package dependencies using pipenv."
cd clusterfuzz
if ! python3 -m pip > /dev/null ; then
  curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
  python3 get-pip.py
fi
python3 -m pip install --upgrade pipenv
pipenv --python 3.11
pipenv sync
source "$(pipenv --venv)/bin/activate"

if [ -z "$ANDROID_SERIAL" ]; then
  echo "No \$ANDROID_SERIAL set. Will automatically detect devices and start ClusterFuzz for each."
  device_index=0
  for serial in `$ADB_PATH/adb devices | awk -F' ' '{ print $1 }' | egrep -v '^(|List)$'`; do
    run_bot $serial $device_index &
    device_index=$((device_index+1))
  done
else
  run_bot $ANDROID_SERIAL &
fi
