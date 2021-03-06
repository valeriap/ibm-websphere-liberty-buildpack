# Encoding: utf-8
# IBM WebSphere Application Server Liberty Buildpack
# Copyright 2013 the original author or authors.
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

require 'fileutils'
require 'liberty_buildpack/diagnostics/common'
require 'liberty_buildpack/jre'
require 'liberty_buildpack/repository/configured_item'
require 'liberty_buildpack/util/application_cache'
require 'liberty_buildpack/util/format_duration'
require 'liberty_buildpack/util/tokenized_version'
require 'liberty_buildpack/jre/memory/memory_limit'
require 'liberty_buildpack/jre/memory/memory_size'

module LibertyBuildpack::Jre

  # Encapsulates the detect, compile, and release functionality for selecting an OpenJDK JRE.
  class IBMJdk

    # Filename of killjava script used to kill the JVM on OOM.
    KILLJAVA_FILE_NAME = 'killjava'

    # The ratio of heap reservation to total reserved memory
    HEAP_SIZE_RATIO = 0.75

    # Creates an instance, passing in an arbitrary collection of options.
    #
    # @param [Hash] context the context that is provided to the instance
    # @option context [String] :app_dir the directory that the application exists in
    # @option context [String] :java_home the directory that acts as +JAVA_HOME+
    # @option context [Array<String>] :java_opts an array that Java options can be added to
    # @option context [Hash] :configuration the properties provided by the user
    def initialize(context)
      @app_dir = context[:app_dir]
      @java_opts = context[:java_opts]
      @configuration = context[:configuration]
      @version, @uri = IBMJdk.find_ibmjdk(@configuration)

      context[:java_home].concat JAVA_HOME
    end

    # Detects which version of Java this application should use.  *NOTE:* This method will always return _some_ value,
    # so it should only be used once that application has already been established to be a Java application.
    #
    # @return [String, nil] returns +ibmjdk-<version>+.
    def detect
      id @version
    end

    # Downloads and unpacks a JRE
    #
    # @return [void]
    def compile
      download_start_time = Time.now
      print "-----> Downloading IBM #{@version} JRE from #{@uri} "

      LibertyBuildpack::Util::ApplicationCache.new.get(@uri) do |file|  # TODO: Use global cache
        puts "(#{(Time.now - download_start_time).duration})"
        expand file
      end
      copy_killjava_script
    end

    # Build Java memory options and places then in +context[:java_opts]+
    #
    # @return [void]
    def release
      @java_opts << "-XX:OnOutOfMemoryError=./#{LibertyBuildpack::Diagnostics::DIAGNOSTICS_DIRECTORY}/#{KILLJAVA_FILE_NAME}"
      @java_opts.concat memory(@configuration)
    end

    private

    RESOURCES = '../../../resources/openjdk/diagnostics'.freeze

    JAVA_HOME = '.java'.freeze

    KEY_MEMORY_HEURISTICS = 'memory_heuristics'

    KEY_MEMORY_SIZES = 'memory_sizes'

    def expand(file)
      expand_start_time = Time.now
      print "       Expanding JRE to #{JAVA_HOME} "

      system "rm -rf #{java_home}"
      system "mkdir -p #{java_home}"
      system "tar xzf #{file.path} -C #{java_home} --strip 1 2>&1"

      puts "(#{(Time.now - expand_start_time).duration})"
    end

    def self.find_ibmjdk(configuration)
      LibertyBuildpack::Repository::ConfiguredItem.find_item(configuration)
    rescue => e
      raise RuntimeError, "IBM JRE error: #{e.message}", e.backtrace
    end

    def id(version)
      "ibmjdk-#{version}"
    end

    def java_home
      File.join @app_dir, JAVA_HOME
    end

    def memory(configuration)
      mem = MemoryLimit.memory_limit
      if mem.nil?
        ## if no memory option has been set by cloudfoundry, we just assume defaults
        ## except for no compressed refs.
        java_memory_opts = []
        java_memory_opts.push '-Xnocompressedrefs'
        java_memory_opts.push '-Xtune:virtualized'

        java_memory_opts
      else
        java_memory_opts = []

        if mem < MemorySize.new('512M')
          java_memory_opts.push '-Xnocompressedrefs'
        end

        new_heap_size = mem * HEAP_SIZE_RATIO

        java_memory_opts.push '-Xtune:virtualized'
        java_memory_opts.push "-Xmx#{new_heap_size}"

        java_memory_opts
      end
    end

    def pre_8
      @version < LibertyBuildpack::Util::TokenizedVersion.new('1.8.0')
    end

    def copy_killjava_script
      resources = File.expand_path(RESOURCES, File.dirname(__FILE__))
      killjava_file_content = File.read(File.join resources, KILLJAVA_FILE_NAME)
      updated_content = killjava_file_content.gsub(/@@LOG_FILE_NAME@@/, LibertyBuildpack::Diagnostics::LOG_FILE_NAME)
      diagnostic_dir = LibertyBuildpack::Diagnostics.get_diagnostic_directory @app_dir
      FileUtils.mkdir_p diagnostic_dir
      File.open(File.join(diagnostic_dir, KILLJAVA_FILE_NAME), 'w', 0755) do |file|
        file.write updated_content
      end
    end

  end

end
