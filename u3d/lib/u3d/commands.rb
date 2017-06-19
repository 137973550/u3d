require 'u3d/unity_versions'
require 'u3d/downloader'
require 'u3d/installer'
require 'u3d/cache'
require 'u3d/utils'
require 'u3d/log_analyzer'
require 'u3d_core/command_executor'
require 'u3d_core/credentials'
require 'fileutils'

module U3d
  # API for U3d, redirecting calls to class they concern
  class Commands
    class << self
      def list_installed(options: {})
        list = Installer.create.installed
        if list.empty?
          UI.important 'No Unity version installed'
          return
        end
        list.each do |u|
          UI.message "Version #{u.version}\t(#{u.path})"
          if options[:packages] && u.packages && !u.packages.empty?
            UI.message 'Packages:'
            u.packages.each { |pack| UI.message " - #{pack}" }
          end
        end
      end

      def list_available(options: {})
        ver = options[:unity_version]
        os = options[:operating_system]
        if os
          if os == 'win' || os == 'mac' || os == 'linux'
            os = os.to_sym
          else
            raise "Specified OS (#{os}) is not recognized"
          end
        else
          os = U3dCore::Helper.operating_system
        end
        cache = Cache.new(force_os: os)
        versions = {}

        return UI.error "Version #{ver} is not in cache" if ver && cache[os.id2name]['versions'][ver].nil?

        if ver
          versions = { ver => cache[os.id2name]['versions'][ver] }
        else
          versions = cache[os.id2name]['versions']
        end

        versions.each do |k, v|
          UI.message "Version #{k}: " + v.to_s.cyan.underline
          if options[:packages]
            inif = nil
            begin
              inif = U3d::INIparser.load_ini(k, versions, os: os)
            rescue => e
              UI.error "Could not load packages for this version (#{e})"
            else
              UI.message 'Packages:'
              inif.keys.each { |pack| UI.message " - #{pack}" }
            end
          end
        end
      end

      def download(args: [], options: {})
        version = args[0]
        UI.user_error!('Please specify a Unity version to download') unless version

        packages = options[:packages] || ['Unity']
        packages.insert(0, 'Unity') if packages.delete('Unity')

        if !packages.include?('Unity')
          unity = check_unity_presence(version)
          return unless unity
          options[:installation_path] ||= unity.path if Helper.windows?
        end

        unless options[:no_install]
          UI.important 'Root privileges are required'
          raise 'Could not get administrative privileges' unless U3dCore::CommandExecutor.has_admin_privileges?
        end

        os = U3dCore::Helper.operating_system
        cache = Cache.new(force_os: os)
        files = []
        if os == :linux
          UI.important 'Option -a | --all not available for Linux' if options[:all]
          UI.important 'Option -p | --packages not available for Linux' if options[:packages]
          files << ["Unity #{version}", Downloader::LinuxDownloader.download(version, cache[os.id2name]['versions']), {}]
        else
          downloader = Downloader::MacDownloader if os == :mac
          downloader = Downloader::WindowsDownloader if os == :win
          if options[:all]
            files = downloader.download_all(version, cache[os.id2name]['versions'])
          else
            packages = options[:packages] || ['Unity']
            packages.insert(0, 'Unity') if packages.delete('Unity')
            packages.each do |package|
              result = downloader.download_specific(package, version, cache[os.id2name]['versions'])
              files << [package, result[0], result[1]] unless result.nil?
            end
          end
        end

        return if options[:no_install]
        files.each do |name, file, info|
          UI.verbose "Installing #{name}#{info['mandatory'] ? ' (mandatory package)' : ''}, with file #{file}"
          Installer.install_module(file, version, installation_path: options[:installation_path], info: info)
        end
      end

      def local_install(args: [], options: {})
        UI.user_error!('Please specify a version') if args.empty?
        version = args[0]

        packages = options[:packages] || ['Unity']
        packages.insert(0, 'Unity') if packages.delete('Unity')

        if !packages.include?('Unity')
          unity = check_unity_presence(version)
          return unless unity
          options[:installation_path] ||= unity.path if Helper.windows?
        end

        UI.important 'Root privileges are required'
        raise 'Could not get administrative privileges' unless U3dCore::CommandExecutor.has_admin_privileges?

        os = U3dCore::Helper.operating_system
        files = []
        if os == :linux
          UI.important 'Option -a | --all not available for Linux' if options[:all]
          UI.important 'Option -p | --packages not available for Linux' if options[:packages]
          files << ["Unity #{version}", Downloader::LinuxDownloader.local_file(version), {}]
        else
          downloader = Downloader::MacDownloader if os == :mac
          downloader = Downloader::WindowsDownloader if os == :win
          if options[:all]
            files = downloader.all_local_files(version)
          else
            packages.each do |package|
              result = downloader.local_file(package, version)
              files << [package, result[0], result[1]] unless result.nil?
            end
          end
        end

        files.each do |name, file, info|
          UI.verbose "Installing #{name}#{info['mandatory'] ? ' (mandatory package)' : ''}, with file #{file}"
          Installer.install_module(file, version, installation_path: options[:installation_path], info: info)
        end
      end

      def run(config: {}, run_args: [])
        version = config[:unity_version]

        runner = Runner.new
        pp = runner.find_projectpath_in_args(run_args)
        pp = Dir.pwd unless pp
        up = UnityProject.new(pp)

        if !version # fall back in project default if we are on a Unity project
          version = up.editor_version if up.exist?
          if !version
            UI.user_error!('Not sure which version of Unity to run. Are you in a project?')
          end
        end

        run_args = ['-projectpath', up.path] if run_args.empty? && up.exist?

        # we could
        # * support matching 5.3.6p3 if passed 5.3.6
        unity = Installer.create.installed.find { |u| u.version == version }
        UI.user_error! "Unity version '#{version}' not found" unless unity
        runner.run(unity, run_args)
      end

      def login(options: {})
        credentials = U3dCore::Credentials.new(user: options['user'])
        credentials.login
      end

      def local_analyze(args: [], options: {})
        raise ArgumentError, 'No files given' if args.empty?
        raise ArgumentError, "File #{args[0]} does not exist" unless File.exist? args[0]

        File.open(args[0], 'r') do |f|
          LogAnalyzer.pipe(f)
        end
      end

      private

      def check_unity_presence(version: nil)
        installed = Installer.create.installed
        unity = installed.find { |u| u.version == version }
        if unity.nil?
          UI.error "Version #{version} of Unity is not installed yet. Please install it first before installing any other module"
        else
          UI.verbose "Unity #{version} is installed at #{unity.path}"
          return unity
        end
        nil
      end
    end
  end
end
