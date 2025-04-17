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

# Create and activate virtual environment
VENV_DIR=".venv"

# Create virtual environment with uv and let it handle Python installation
source "$VENV_DIR/bin/activate"

# Run the full bootstrap script to prepare for ClusterFuzz development.
# Make sure PYTHONPATH points to the site-packages within the uv-managed venv
PYTHONPATH=$VIRTUAL_ENV/lib/python$(python -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')/site-packages $VIRTUAL_ENV/bin/python butler.py run_server --skip-install-deps "$@"


