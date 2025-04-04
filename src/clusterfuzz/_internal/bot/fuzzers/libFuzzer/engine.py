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
"""libFuzzer engine interface."""

import os
import re
import tempfile

from clusterfuzz._internal.base import utils
from clusterfuzz._internal.bot.fuzzers import dictionary_manager
from clusterfuzz._internal.bot.fuzzers import engine_common
from clusterfuzz._internal.bot.fuzzers import libfuzzer
from clusterfuzz._internal.bot.fuzzers import options as fuzzer_options
from clusterfuzz._internal.bot.fuzzers import strategy_selection
from clusterfuzz._internal.bot.fuzzers import utils as fuzzer_utils
from clusterfuzz._internal.bot.fuzzers.libFuzzer import constants
from clusterfuzz._internal.bot.fuzzers.libFuzzer import fuzzer
from clusterfuzz._internal.bot.fuzzers.libFuzzer import stats
from clusterfuzz._internal.fuzzing import strategy
from clusterfuzz._internal.metrics import logs
from clusterfuzz._internal.system import environment
from clusterfuzz._internal.system import shell
from clusterfuzz.fuzz import engine

ENGINE_ERROR_MESSAGE = 'libFuzzer: engine encountered an error'
DICT_PARSING_FAILED_REGEX = re.compile(
    r'ParseDictionaryFile: error in line (\d+)')
MULTISTEP_MERGE_SUPPORT_TOKEN = b'fuzz target overwrites its const input'


def _is_multistep_merge_supported(target_path):
  """Checks whether a particular binary support multistep merge."""
  # TODO(Dor1s): implementation below a temporary workaround, do not tell any
  # body that we are doing this. The real solution would be to execute a
  # fuzz target with '-help=1' and check the output for the presence of
  # multistep merge support added in https://reviews.llvm.org/D71423.
  # The temporary implementation checks that the version of libFuzzer is at
  # least https://github.com/llvm/llvm-project/commit/da3cf61, which supports
  # multi step merge: https://github.com/llvm/llvm-project/commit/f054067.
  if os.path.exists(target_path):
    with open(target_path, 'rb') as file_handle:
      return utils.search_bytes_in_file(MULTISTEP_MERGE_SUPPORT_TOKEN,
                                        file_handle)

  return False


class MergeError(engine.Error):
  """Merge error."""


class LibFuzzerOptions(engine.FuzzOptions):
  """LibFuzzer engine options."""

  def __init__(self, corpus_dir, arguments, strategies, fuzz_corpus_dirs,
               extra_env, is_mutations_run):
    super().__init__(corpus_dir, arguments, strategies)
    self.fuzz_corpus_dirs = fuzz_corpus_dirs
    self.extra_env = extra_env
    self.is_mutations_run = is_mutations_run
    self.merge_back_new_testcases = True


class Engine(engine.Engine):
  """LibFuzzer engine implementation."""

  def __init__(self, *args, **kwargs):
    super().__init__(*args, **kwargs)
    self._merge_control_file = None

  @property
  def name(self):
    return 'libFuzzer'

  def fuzz_additional_processing_timeout(self, options):
    """Return the maximum additional timeout in seconds for additional
    operations in fuzz() (e.g. merging back new items).

    Args:
      options: A FuzzOptions object.

    Returns:
      An int representing the number of seconds required.
    """
    fuzz_timeout = libfuzzer.get_fuzz_timeout(
        options.is_mutations_run, total_timeout=0)
    # get_fuzz_timeout returns a negative value.
    return -fuzz_timeout

  def prepare(self, corpus_dir, target_path, build_dir):
    """Prepare for a fuzzing session, by generating options. Returns a
    FuzzOptions object.

    Args:
      corpus_dir: The main corpus directory.
      target_path: Path to the target.
      build_dir: Path to the build directory.

    Returns:
      A FuzzOptions object.
    """
    del build_dir
    arguments = fuzzer.get_arguments(target_path)
    extra_env = fuzzer.get_extra_env(target_path)

    if self.do_strategies:
      strategy_pool = strategy_selection.generate_weighted_strategy_pool(
          strategy_list=strategy.LIBFUZZER_STRATEGY_LIST,
          use_generator=True,
          engine_name=self.name)
    else:
      strategy_pool = strategy_selection.StrategyPool()

    strategy_info = libfuzzer.pick_strategies(strategy_pool, target_path,
                                              corpus_dir, arguments)
    if (strategy.USE_EXTRA_SANITIZERS_STRATEGY.name in
        strategy_info.fuzzing_strategies):
      environment.set_value('USE_EXTRA_SANITIZERS', True)
      environment.disable_lsan()
    else:
      environment.set_value('USE_EXTRA_SANITIZERS', False)

    arguments.extend(strategy_info.arguments)
    # Update strategy info with environment variables from fuzzer's options.
    if extra_env is not None:
      for env_var_name, value in extra_env.items():
        if env_var_name not in strategy_info.extra_env:
          strategy_info.extra_env[env_var_name] = value

    # Check for seed corpus and add it into corpus directory.
    engine_common.unpack_seed_corpus_if_needed(target_path, corpus_dir)

    # Pick a few testcases from our corpus to use as the initial corpus.
    subset_size = engine_common.random_choice(
        engine_common.CORPUS_SUBSET_NUM_TESTCASES)

    if (strategy_pool.do_strategy(strategy.CORPUS_SUBSET_STRATEGY) and
        shell.get_directory_file_count(corpus_dir) > subset_size):
      # Copy |subset_size| testcases into 'subset' directory.
      corpus_subset_dir = engine_common.create_temp_fuzzing_dir('subset')
      libfuzzer.copy_from_corpus(corpus_subset_dir, corpus_dir, subset_size)
      strategy_info.fuzzing_strategies.append(
          strategy.CORPUS_SUBSET_STRATEGY.name + '_' + str(subset_size))
      strategy_info.additional_corpus_dirs.append(corpus_subset_dir)
    else:
      strategy_info.additional_corpus_dirs.append(corpus_dir)

    # Check dict argument to make sure that it's valid.
    dict_path = arguments.get(
        constants.DICT_FLAGNAME, default=None, constructor=str)
    if dict_path and not os.path.exists(dict_path):
      logs.error(f'Cannot find dict: {dict_path} for {target_path}.')
      del arguments[constants.DICT_FLAGNAME]

    # If there's no dict argument, check for %target_binary_name%.dict file.
    dict_path = arguments.get(
        constants.DICT_FLAGNAME, default=None, constructor=str)
    if not dict_path:
      dict_path = dictionary_manager.get_default_dictionary_path(target_path)
      if os.path.exists(dict_path):
        arguments[constants.DICT_FLAGNAME] = dict_path

    # If we have a dictionary, correct any items that are not formatted properly
    # (e.g. quote items that are missing them).
    dictionary_manager.correct_if_needed(dict_path)

    strategies = stats.process_strategies(
        strategy_info.fuzzing_strategies, name_modifier=lambda x: x)
    return LibFuzzerOptions(corpus_dir, arguments.list(), strategies,
                            strategy_info.additional_corpus_dirs,
                            strategy_info.extra_env,
                            strategy_info.is_mutations_run)

  def _create_empty_testcase_file(self, reproducers_dir):
    """Create an empty testcase file in temporary directory."""
    _, path = tempfile.mkstemp(dir=reproducers_dir)
    return path

  def _create_temp_dir(self, name):
    """Create a temporary directory suitable for putting into the TMPDIR
    environment variable, which practically speaking sometimes needs to be
    shortish."""
    new_temp_dir = os.path.join(
        fuzzer_utils.get_temp_dir(use_fuzz_inputs_disk=False), name)
    engine_common.recreate_directory(new_temp_dir)
    return new_temp_dir

  def _create_merge_corpus_dir(self):
    """Create merge corpus directory."""
    return engine_common.create_temp_fuzzing_dir('merge-corpus')

  def _merge_new_units(self, target_path, corpus_dir, new_corpus_dir,
                       fuzz_corpus_dirs, arguments, stat_overrides):
    """Merge new units."""
    # Make a decision on whether merge step is needed at all. If there are no
    # new units added by libFuzzer run, then no need to do merge at all.
    new_units_added = shell.get_directory_file_count(new_corpus_dir)
    if not new_units_added:
      stat_overrides['new_units_added'] = 0
      logs.info('Skipped corpus merge since no new units added by fuzzing.')
      return

    # If this times out, it's possible that we will miss some units. However, if
    # we're taking >10 minutes to load/merge the corpus something is going very
    # wrong and we probably don't want to make things worse by adding units
    # anyway.
    merge_corpus = self._create_merge_corpus_dir()

    merge_dirs = fuzz_corpus_dirs[:]

    # Merge the new units with the initial corpus.
    if corpus_dir not in merge_dirs:
      merge_dirs.append(corpus_dir)

    old_corpus_len = shell.get_directory_file_count(corpus_dir)

    new_units_added = 0
    try:
      result = self._minimize_corpus_two_step(
          target_path=target_path,
          arguments=arguments,
          existing_corpus_dirs=merge_dirs,
          new_corpus_dir=new_corpus_dir,
          output_corpus_dir=merge_corpus,
          reproducers_dir=None,
          max_time=engine_common.get_merge_timeout(
              engine_common.DEFAULT_MERGE_TIMEOUT))

      engine_common.move_mergeable_units(merge_corpus, corpus_dir)
      new_corpus_len = shell.get_directory_file_count(corpus_dir)
      new_units_added = new_corpus_len - old_corpus_len

      stat_overrides.update(result.stats)
    except (MergeError, TimeoutError) as e:
      logs.warning('Merge failed.', error=repr(e))

    stat_overrides['new_units_added'] = new_units_added

    # Record the stats to make them easily searchable in stackdriver.
    logs.info('Stats calculated.', stats=stat_overrides)
    if new_units_added:
      logs.info(f'New units added to corpus: {new_units_added}.')
    else:
      logs.info('No new units found.')

  def _fuzz_output_contains_trusty_kernel_panic(self, log_lines):
    for line in log_lines:
      if 'panic notifier - trusty version' in line:
        return True
    return False

  def fuzz(self, target_path, options, reproducers_dir, max_time):
    """Run a fuzz session.

    Args:
      target_path: Path to the target.
      options: The FuzzOptions object returned by prepare().
      reproducers_dir: The directory to put reproducers in when crashes
          are found.
      max_time: Maximum allowed time for the fuzzing to run.

    Returns:
      A FuzzResult object.
    """
    libfuzzer.set_sanitizer_options(target_path)
    runner = libfuzzer.get_runner(target_path)

    # Directory to place new units.
    if options.merge_back_new_testcases:
      new_corpus_dir = engine_common.create_temp_fuzzing_dir('new')
      corpus_directories = [new_corpus_dir] + options.fuzz_corpus_dirs
    else:
      corpus_directories = options.fuzz_corpus_dirs

    fuzz_result = runner.fuzz(
        corpus_directories,
        fuzz_timeout=max_time,
        additional_args=options.arguments,
        artifact_prefix=reproducers_dir,
        extra_env=options.extra_env)

    project_qualified_fuzzer_name = (
        engine_common.get_project_qualified_fuzzer_name(target_path))
    dict_error_match = DICT_PARSING_FAILED_REGEX.search(fuzz_result.output)
    if dict_error_match:
      logs.error(
          'Dictionary parsing failed '
          f'(target={project_qualified_fuzzer_name}, '
          f'line={dict_error_match.group(1)}).',
          engine_output=fuzz_result.output)
    elif (not environment.get_value('USE_MINIJAIL') and
          fuzz_result.return_code == constants.LIBFUZZER_ERROR_EXITCODE):
      # Minijail returns 1 if the exit code is nonzero.
      # Otherwise: we can assume that a return code of 1 means that libFuzzer
      # itself ran into an error.
      logs.error(
          ENGINE_ERROR_MESSAGE + f' (target={project_qualified_fuzzer_name}).',
          engine_output=fuzz_result.output)

    log_lines = fuzz_result.output.splitlines()
    # Output can be large, so save some memory by removing reference to the
    # original output which is no longer needed.
    fuzz_result.output = None

    # Check if we crashed, and get the crash testcase path.
    crash_testcase_file_path = runner.get_testcase_path(log_lines)

    # If we exited with a non-zero return code with no crash file in output from
    # libFuzzer, this is most likely a startup crash. Alternatively, this case
    # may occur if Trusty fuzzing exited due to a kernel panic.
    # Use an empty testcase to store these exit types as a crash.
    if (not crash_testcase_file_path and
        fuzz_result.return_code not in constants.NONCRASH_RETURN_CODES
       ) or self._fuzz_output_contains_trusty_kernel_panic(log_lines):
      crash_testcase_file_path = self._create_empty_testcase_file(
          reproducers_dir)

    # Parse stats information based on libFuzzer output.
    parsed_stats = libfuzzer.parse_log_stats(log_lines)

    # Extend parsed stats by additional performance features.
    parsed_stats.update(
        stats.parse_performance_features(log_lines, options.strategies,
                                         options.arguments))

    args = fuzzer_options.FuzzerArguments.from_list(options.arguments)
    # Set some initial stat overrides.
    timeout_limit = args.get(
        constants.TIMEOUT_FLAGNAME, default=None, constructor=int)

    actual_duration = int(fuzz_result.time_executed)
    fuzzing_time_percent = 100 * actual_duration / float(max_time)
    parsed_stats.update({
        'timeout_limit': timeout_limit,
        'expected_duration': int(max_time),
        'actual_duration': actual_duration,
        'fuzzing_time_percent': fuzzing_time_percent,
    })

    # Remove fuzzing arguments before merge and dictionary analysis step.
    non_fuzz_arguments = libfuzzer.strip_fuzzing_arguments(
        args.list(), is_merge=True)

    if options.merge_back_new_testcases:
      self._merge_new_units(target_path, options.corpus_dir, new_corpus_dir,
                            options.fuzz_corpus_dirs, non_fuzz_arguments,
                            parsed_stats)

    fuzz_logs = '\n'.join(log_lines)
    crashes = []
    if crash_testcase_file_path:
      reproduce_arguments = libfuzzer.strip_fuzzing_arguments(options.arguments)

      # Use higher timeout for reproduction.
      reproduce_arguments = libfuzzer.fix_timeout_argument_for_reproduction(
          reproduce_arguments)

      # Write the new testcase.
      # Copy crash testcase contents into the main testcase path.
      crashes.append(
          engine.Crash(crash_testcase_file_path, fuzz_logs, reproduce_arguments,
                       actual_duration))

    return engine.FuzzResult(fuzz_logs, fuzz_result.command, crashes,
                             parsed_stats, fuzz_result.time_executed,
                             fuzz_result.timed_out)

  def reproduce(self, target_path, input_path, arguments, max_time):
    """Reproduce a crash given an input.

    Args:
      target_path: Path to the target.
      input_path: Path to the reproducer input.
      arguments: Additional arguments needed for reproduction.
      max_time: Maximum allowed time for the reproduction.

    Returns:
      A ReproduceResult.

    Raises:
      TimeoutError: If the reproduction exceeds max_time.
    """
    runner = libfuzzer.get_runner(target_path)
    libfuzzer.set_sanitizer_options(target_path)

    # Remove fuzzing specific arguments. This is only really needed for legacy
    # testcases, and can be removed in the distant future.
    arguments = libfuzzer.strip_fuzzing_arguments(arguments)
    arguments = fuzzer_options.FuzzerArguments.from_list(arguments)

    arguments[constants.RUNS_FLAGNAME] = int(constants.RUNS_TO_REPRODUCE)

    result = runner.run_single_testcase(
        input_path, timeout=max_time, additional_args=arguments.list())

    if result.timed_out:
      logs.warning('Reproducing timed out.', fuzzer_output=result.output)
      raise TimeoutError('Reproducing timed out.')

    return engine.ReproduceResult(result.command, result.return_code,
                                  result.time_executed, result.output)

  def _minimize_corpus_two_step(self, target_path, arguments,
                                existing_corpus_dirs, new_corpus_dir,
                                output_corpus_dir, reproducers_dir, max_time):
    """Optional (but recommended): run corpus minimization.

    Args:
      target_path: Path to the target.
      arguments: Additional arguments needed for corpus minimization.
      existing_corpus_dirs: Input corpora that existed before the fuzzing run.
      new_corpus_dir: Input corpus that was generated during the fuzzing run.
          Must have at least one new file.
      output_corpus_dir: Output directory to place minimized corpus.
      reproducers_dir: The directory to put reproducers in when crashes are
          found.
      max_time: Maximum allowed time for the minimization.

    Returns:
      A Result object.
    """
    if not _is_multistep_merge_supported(target_path):
      # Fallback to the old single step merge. It does not support incremental
      # stats and provides only `edge_coverage` and `feature_coverage` stats.
      logs.info('Old version of libFuzzer is used. Using single step merge.')
      return self.minimize_corpus(target_path, arguments,
                                  existing_corpus_dirs + [new_corpus_dir],
                                  output_corpus_dir, reproducers_dir, max_time)

    # The dir where merge control file is located must persist for both merge
    # steps. The second step re-uses the MCF produced during the first step.
    merge_control_file_dir = engine_common.create_temp_fuzzing_dir(
        'mcf_tmp_dir')
    self._merge_control_file = os.path.join(merge_control_file_dir, 'MCF')

    # Two step merge process to obtain accurate stats for the new corpus units.
    # See https://reviews.llvm.org/D66107 for a more detailed description.
    merge_stats = {}

    # Step 1. Use only existing corpus and collect "initial" stats.
    result_1 = self.minimize_corpus(target_path, arguments,
                                    existing_corpus_dirs, output_corpus_dir,
                                    reproducers_dir, max_time)
    merge_stats['initial_edge_coverage'] = result_1.stats['edge_coverage']
    merge_stats['initial_feature_coverage'] = result_1.stats['feature_coverage']

    # Clear the output dir as it does not have any new units at this point.
    engine_common.recreate_directory(output_corpus_dir)

    # Adjust the time limit for the time we spent on the first merge step.
    max_time -= result_1.time_executed
    if max_time <= 0:
      logs.error(
          'Merging new testcases timed out.', fuzzer_output=result_1.logs)
      raise TimeoutError('Merging new testcases timed out.')

    # Step 2. Process the new corpus units as well.
    result_2 = self.minimize_corpus(
        target_path, arguments, existing_corpus_dirs + [new_corpus_dir],
        output_corpus_dir, reproducers_dir, max_time)
    merge_stats['edge_coverage'] = result_2.stats['edge_coverage']
    merge_stats['feature_coverage'] = result_2.stats['feature_coverage']

    # Diff the stats to obtain accurate values for the new corpus units.
    merge_stats['new_edges'] = (
        merge_stats['edge_coverage'] - merge_stats['initial_edge_coverage'])
    merge_stats['new_features'] = (
        merge_stats['feature_coverage'] -
        merge_stats['initial_feature_coverage'])

    output = result_1.logs + '\n\n' + result_2.logs
    if (merge_stats['new_edges'] < 0 or merge_stats['new_features'] < 0):
      logs.error(
          'Two step merge failed.', merge_stats=merge_stats, output=output)
      merge_stats['new_edges'] = 0
      merge_stats['new_features'] = 0

    self._merge_control_file = None

    # TODO(ochang): Get crashes found during merge.
    return engine.FuzzResult(output, result_2.command, [], merge_stats,
                             result_1.time_executed + result_2.time_executed)

  def minimize_corpus(self, target_path, arguments, input_dirs, output_dir,
                      reproducers_dir, max_time):
    """Optional (but recommended): run corpus minimization.

    Args:
      target_path: Path to the target.
      arguments: Additional arguments needed for corpus minimization.
      input_dirs: Input corpora.
      output_dir: Output directory to place minimized corpus.
      reproducers_dir: The directory to put reproducers in when crashes are
          found.
      max_time: Maximum allowed time for the minimization.

    Returns:
      A Result object.

    Raises:
      TimeoutError: If the corpus minimization exceeds max_time.
      Error: If the merge failed in some other way.
    """
    runner = libfuzzer.get_runner(target_path)
    libfuzzer.set_sanitizer_options(target_path)
    merge_tmp_dir = self._create_temp_dir('merge-wd')
    logs.info(f'Starting merge with timeout {max_time}.')

    try:
      result = runner.merge(
          [output_dir] + input_dirs,
          merge_timeout=max_time,
          tmp_dir=merge_tmp_dir,
          additional_args=arguments,
          artifact_prefix=reproducers_dir,
          merge_control_file=getattr(self, '_merge_control_file', None))
    finally:
      # Deletes the directory to relinquish space
      engine_common.recreate_directory(merge_tmp_dir)

    logs.info('Merge completed.', fuzzer_output=result.output)
    if result.timed_out:
      logs.error(
          'Merging new testcases timed out.', fuzzer_output=result.output)
      raise TimeoutError('Merging new testcases timed out.')

    if result.return_code != 0:
      logs.error(
          f'Merging new testcases failed with error code {result.return_code}',
          fuzzer_output=result.output)
      raise MergeError('Merging new testcases failed.')

    merge_output = result.output
    merge_stats = stats.parse_stats_from_merge_log(merge_output.splitlines())

    return engine.FuzzResult(merge_output, result.command, [], merge_stats,
                             result.time_executed)

  def minimize_testcase(self, target_path, arguments, input_path, output_path,
                        max_time):
    """Optional (but recommended): Minimize a testcase.

    Args:
      target_path: Path to the target.
      arguments: Additional arguments needed for testcase minimization.
      input_path: Path to the reproducer input.
      output_path: Path to the minimized output.
      max_time: Maximum allowed time for the minimization.

    Returns:
      A ReproduceResult.

    Raises:
      TimeoutError: If the testcase minimization exceeds max_time.
    """
    runner = libfuzzer.get_runner(target_path)
    libfuzzer.set_sanitizer_options(target_path)

    minimize_tmp_dir = engine_common.create_temp_fuzzing_dir('minimize-workdir')
    result = runner.minimize_crash(
        input_path,
        output_path,
        max_time,
        artifact_prefix=minimize_tmp_dir,
        additional_args=arguments)

    if result.timed_out:
      logs.error('Minimization timed out.', fuzzer_output=result.output)
      raise TimeoutError('Minimization timed out.')

    return engine.ReproduceResult(result.command, result.return_code,
                                  result.time_executed, result.output)

  def cleanse(self, target_path, arguments, input_path, output_path, max_time):
    """Optional (but recommended): Cleanse a testcase.

    Args:
      target_path: Path to the target.
      arguments: Additional arguments needed for testcase cleanse.
      input_path: Path to the reproducer input.
      output_path: Path to the cleansed output.
      max_time: Maximum allowed time for the cleanse.

    Returns:
      A ReproduceResult.

    Raises:
      TimeoutError: If the cleanse exceeds max_time.
    """
    runner = libfuzzer.get_runner(target_path)
    libfuzzer.set_sanitizer_options(target_path)

    cleanse_tmp_dir = engine_common.create_temp_fuzzing_dir('cleanse-workdir')
    result = runner.cleanse_crash(
        input_path,
        output_path,
        max_time,
        artifact_prefix=cleanse_tmp_dir,
        additional_args=arguments)

    if result.timed_out:
      logs.error('Cleanse timed out.', fuzzer_output=result.output)
      raise TimeoutError('Cleanse timed out.')

    return engine.ReproduceResult(result.command, result.return_code,
                                  result.time_executed, result.output)
