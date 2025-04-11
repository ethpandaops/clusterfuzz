#!/bin/bash -ex
#
# Copyright 2023 Google LLC
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

# Setup virtual environment and install python dependencies.
echo If this fails, you may need to build older Python from source

# Install uv if not present
if ! command -v uv &> /dev/null; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

# Create and activate virtual environment
VENV_DIR=".venv"
if [ -d "$VENV_DIR" ]; then
  rm -rf "$VENV_DIR"
fi

# Create virtual environment with Python 3.11
$PYTHON -m venv "$VENV_DIR"
source "$VENV_DIR/bin/activate"

# Verify Python version
if ! python --version | grep -q "3.11"; then
    echo "Error: Virtual environment is not using Python 3.11"
    exit 1
fi

# Install pip in virtual environment
curl https://bootstrap.pypa.io/get-pip.py -o get-pip.py
python get-pip.py

# Install pipenv
python -m pip install pipenv

# Generate requirements from root Pipfile
python -m pipenv requirements > root_requirements.txt

# Generate requirements from src Pipfile
cd src
python -m pipenv requirements > src_requirements.txt

# Install all requirements
cd ..
uv pip install -r root_requirements.txt
uv pip install --no-build-isolation -r src/src_requirements.txt
uv pip install gunicorn

# Install other dependencies (e.g. bower).
nodeenv -p --prebuilt
# Unsafe perm flag allows bower and polymer-bundler install for root users as well.
npm install --unsafe-perm -g bower polymer-bundler
bower --allow-root install

# Run the full bootstrap script to prepare for ClusterFuzz development.
python butler.py bootstrap

set +x
echo "

Installation succeeded!
Please load environment by running 'source $VENV_DIR/bin/activate'.

"
