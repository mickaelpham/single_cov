module SingleCov
  COVERAGES = []
  MAX_OUTPUT = 40
  APP_FOLDERS = ["models", "serializers", "helpers", "controllers", "mailers", "views", "jobs"]

  class << self
    # optionally rewrite the file we guessed with a lambda
    def rewrite(&block)
      @rewrite = block
    end

    def not_covered!
    end

    def covered!(file: nil, uncovered: 0)
      file = guess_and_check_covered_file(file)
      COVERAGES << [file, uncovered]
    end

    def all_covered?(result)
      errors = COVERAGES.map do |file, expected_uncovered|
        if coverage = result["#{root}/#{file}"]
          uncovered_lines = coverage.each_with_index.map { |c, i| "#{file}:#{i+1}" if c == 0 }.compact
          next if uncovered_lines.size == expected_uncovered
          warn_about_bad_coverage(file, expected_uncovered, uncovered_lines)
        else
          warn_about_no_coverage(file)
        end
      end.compact

      return true if errors.empty?

      errors = errors.join("\n").split("\n") # unify arrays with multiline strings
      errors[MAX_OUTPUT..-1] = "... coverage output truncated" if errors.size >= MAX_OUTPUT
      warn errors

      errors.all? { |l| l.end_with?('?') } # ok if we just have warnings
    end

    def assert_used(tests: default_tests)
      bad = tests.select do |file|
        File.read(file) !~ /SingleCov.(not_)?covered\!/
      end
      unless bad.empty?
        raise bad.map { |f| "#{f}: needs to use SingleCov.covered!" }.join("\n")
      end
    end

    def assert_tested(files: glob('{app,lib}/**/*.rb'), tests: default_tests, untested: [])
      missing = files - tests.map { |t| file_under_test(t) }
      fixed = untested - missing
      missing -= untested

      if fixed.any?
        raise "Remove #{fixed.inspect} from untested!"
      elsif missing.any?
        raise missing.map { |f| "missing test for #{f}" }.join("\n")
      end
    end

    def setup(framework, root: nil)
      if defined?(SimpleCov)
        raise "Load SimpleCov after SingleCov"
      end

      @root = root if root

      case framework
      when :minitest
        minitest_should_not_be_running!
        return if minitest_running_subset_of_tests?
      when :rspec
        return if rspec_running_subset_of_tests?
      else
        raise "Unsupported framework #{framework.inspect}"
      end

      start_coverage_recording

      override_at_exit do |status, _exception|
        exit 1 if status == 0 && !SingleCov.all_covered?(coverage_results)
      end
    end

    private

    def default_tests
      glob("{test,spec}/**/*_{test,spec}.rb")
    end

    def glob(pattern)
      Dir["#{root}/#{pattern}"].map! { |f| f.sub("#{root}/", '') }
    end

    # do not ask for coverage when SimpleCov already does or it conflicts
    def coverage_results
      if defined?(SimpleCov)
        SimpleCov.instance_variable_get(:@result).original_result
      else
        Coverage.result
      end
    end

    # start recording before classes are loaded or nothing can be recorded
    # SimpleCov might start coverage again, but that does not hurt ...
    def start_coverage_recording
      require 'coverage'
      Coverage.start
    end

    # not running rake or a whole folder
    # TODO make this better ...
    def running_single_file?
      !defined?(Rake)
    end

    # we cannot insert our hooks when minitest is already running
    def minitest_should_not_be_running!
      if defined?(Minitest) && Minitest.class_variable_defined?(:@@installed_at_exit) && Minitest.class_variable_get(:@@installed_at_exit)
        raise "Load minitest after setting up SingleCov"
      end
    end

    # do not record or verify when only running selected tests since it would be missing data
    def minitest_running_subset_of_tests?
      (ARGV & ['-n', '--name', '-l', '--line']).any?
    end

    def rspec_running_subset_of_tests?
      (ARGV & ['-t', '--tag', '-e', '--example']).any? || ARGV.any? { |a| a =~ /\:\d+$/ }
    end

    # code stolen from SimpleCov
    def override_at_exit
      at_exit do
        exit_status = if $! # was an exception thrown?
          # if it was a SystemExit, use the accompanying status
          # otherwise set a non-zero status representing termination by
          # some other exception (see github issue 41)
          $!.is_a?(SystemExit) ? $!.status : 1
        else
          # Store the exit status of the test run since it goes away
          # after calling the at_exit proc...
          0
        end

        yield exit_status, $!

        # Force exit with stored status (see github issue #5)
        # unless it's nil or 0 (see github issue #281)
        Kernel.exit exit_status if exit_status && exit_status > 0
      end
    end

    def guess_and_check_covered_file(file)
      if file && file.start_with?("/")
        raise "Use paths relative to root."
      end

      if file
        raise "#{file} does not exist and cannot be covered." unless File.exist?("#{root}/#{file}")
      else
        file = file_under_test(caller[1])
        unless File.exist?("#{root}/#{file}")
          raise "Tried to guess covered file as #{file}, but it does not exist.\nUse `SingleCov.covered file: 'target_file.rb'` to set covered file location."
        end
      end

      file
    end

    def warn_about_bad_coverage(file, expected_uncovered, uncovered_lines)
      details = "(#{uncovered_lines.size} current vs #{expected_uncovered} configured)"
      if expected_uncovered > uncovered_lines.size
        if running_single_file?
          "#{file} has less uncovered lines #{details}, decrement configured uncovered?"
        end
      else
        [
          "#{file} new uncovered lines introduced #{details}",
          "Lines missing coverage:",
          *uncovered_lines
        ].join("\n")
      end
    end

    def warn_about_no_coverage(file)
      if $LOADED_FEATURES.include?("#{root}/#{file}")
        # we cannot enforce $LOADED_FEATURES during covered! since it would fail when multiple files are loaded
        "#{file} was expected to be covered, but already loaded before tests started."
      else
        "#{file} was expected to be covered, but never loaded."
      end
    end

    def file_under_test(file)
      file = file.dup

      # remove caller junk to get nice error messages when something fails
      file.sub!(/\.rb\b.*/, '.rb')

      # resolve all kinds of relativity
      file = File.expand_path(file)

      # remove project root
      file.sub!("#{root}/", '')

      # preserve subfolders like foobar/test/xxx_test.rb -> foobar/lib/xxx_test.rb
      subfolder, file_part = file.split(%r{(?:^|/)(?:test|spec)/}, 2)
      unless file_part
        raise "#{file} includes neither 'test' nor 'spec' folder ... unable to resolve"
      end

      # rails things live in app
      file_part[0...0] = if file_part =~ /^(?:#{APP_FOLDERS.map { |f| Regexp.escape(f) }.join('|')})\//
        "app/"
      elsif file_part.start_with?("lib/") # don't add lib twice
        ""
      else # everything else lives in lib
        "lib/"
      end

      # remove test extension
      unless file_part.sub!(/_(?:test|spec)\.rb\b.*/, '.rb')
        raise "Unable to remove test extension from #{file} ... _test.rb and _spec.rb are supported"
      end

      # put back the subfolder
      file_part[0...0] = "#{subfolder}/" unless subfolder.empty?

      file_part = @rewrite.call(file_part) if @rewrite

      file_part
    end

    def root
      @root ||= (defined?(Bundler) && Bundler.root.to_s) || Dir.pwd
    end
  end
end
