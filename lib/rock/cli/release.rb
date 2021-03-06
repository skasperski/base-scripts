require 'thor'
require 'autoproj'
require 'rock'
require 'rock/cli/release_admin'

module Rock
    module CLI
        # Management of releases from the point of view of the user
        #
        # The Rock scheme here is to store all release info in the common buildconf
        # repository. Each release has its own tag, and within the commit pointed-to
        # by the tag the files overrides.d/80-release.* contain the necessary
        # information:
        #    overrides.d/80-release.md: release notes (in markdown format)
        #    overrides.d/80-release.package_sets.yml: version information for the package sets
        #    overrides.d/80-release.packages.yml: version information for the packages
        #
        class Release < Thor
            class_option :verbose, type: :boolean, default: false

            # VCS information where the Rock release information is stored
            ROCK_RELEASE_INFO = Hash[
                'github' => 'rock-core/buildconf',
                'branch' => 'releases']

            RELEASE_NOTES    = "RELEASE_NOTES.md"
            RELEASE_VERSIONS = "overrides.d/25-release.yml"

            attr_reader :config
            attr_reader :package
            attr_reader :importer

            class InvalidReleaseName < Autobuild::PackageException; end

            no_commands do
                def config_dir
                    @ws.config_dir
                end

                def initialize(*args)
                    super

                    @ws = Autoproj::Workspace.from_environment
                    @ws.set_as_main_workspace
                    @ws.load_config
                    require 'autoproj/git_server_configuration'
                    vcs = Autoproj::VCSDefinition.from_raw(ROCK_RELEASE_INFO)
                    @package = Autoproj::Ops::Tools.
                        create_autobuild_package(vcs, "main configuration", config_dir)
                    @importer = package.importer
                    importer.remote_name = 'rock-core'
                end

                def fetch_release_notes(release_name)
                    verify_release_name(release_name)
                    importer.show(package, release_name, RELEASE_NOTES)
                end

                def fetch_version_file(release_name)
                    verify_release_name(release_name)
                    importer.show(package, release_name, RELEASE_VERSIONS)
                end
            
                def ensure_overrides_dir_present
                    FileUtils.mkdir_p @ws.overrides_dir
                end

                def verify_release_name(release_name, options = Hash.new)
                    Kernel.validate_options options,
                        only_local: false

                    importer.rev_parse(package, release_name)
                    importer.show(package, release_name, RELEASE_NOTES)
                rescue Autobuild::PackageException
                    if !options[:only_local]
                        # Try harder, fetch the remote branch
                        importer.tags(package)
                        return verify_release_name(release_name, only_local: true)
                    end
                    raise InvalidReleaseName.new(package, 'import'),
                        "#{release_name} does not look like a valid release name"
                end

                def ensure_autoproj_config_loaded
                    if !@autoproj_config_loaded
                        tool = Autoproj::CLI::InspectionTool.new(@ws)
                        tool.initialize_and_load
                        tool.finalize_setup
                        @autoproj_config_loaded = true
                    end
                end

                def match_names_to_packages_in_versions(names, versions, ignore_missing: false)
                    unmatched_pkg_name_to_entry = Hash.new
                    matched_pkg = Hash.new
                    matched_pkg_set = Array.new

                    names.each do |name|
                        entries = versions.find_all do |vcs|
                            key = vcs.keys.first
                            if key =~ /^pkg_set:/
                                pkg_set_name = $'
                                if (name === vcs['name']) || (name === key)
                                    matched_pkg_set << pkg_set_name
                                end
                            elsif name === key
                                matched_pkg[key] = vcs
                                true
                            else
                                unmatched_pkg_name_to_entry[key] = vcs
                                false
                            end
                        end

                        if entries.empty? && !ignore_missing
                            Autoproj.error "cannot find a package or package set matching #{name} in release #{release}"
                            return
                        end
                    end

                    if !matched_pkg_set.empty?
                        ensure_autoproj_config_loaded
                        matched_pkg_set.each do |pkg_set_name|
                            pkg_set = @ws.manifest.package_set(pkg_set_name)
                            pkg_set.each_package do |pkg|
                                if vcs = unmatched_pkg_name_to_entry[pkg.name]
                                    matched_pkg[vcs.keys.first] = vcs
                                end
                            end
                        end
                    end
                    matched_pkg
                end
            end

            default_command
            desc "list",
                "displays the list of known releases"
            option 'local', type: :boolean
            def list
                tags = importer.tags(package, only_local: options[:local])
                releases = tags.find_all do |tag_name, _|
                    begin verify_release_name(tag_name, only_local: true)
                    rescue InvalidReleaseName
                    end
                end
                puts releases.map(&:first).sort.join("\n")
            end

            desc "versions RELEASE_NAME",
                "displays the version file of the given release"
            def versions(release_name)
                puts fetch_version_file(release_name)
            end

            desc "notes RELEASE_NAME",
                "displays the release notes for the given release"
            def notes(release_name)
                puts fetch_release_notes(release_name)
            end

            desc 'switch RELEASE_NAME', 'switch to a release, master or stable'
            def switch(release_name)
                if release_name == "master"
                    FileUtils.rm_f File.join(config_dir, RELEASE_VERSIONS)
                    @ws.config.set("ROCK_SELECTED_FLAVOR", "master")
                    @ws.config.set('current_rock_release', false)
                    @ws.save_config
                    Autoproj.message "successfully setup flavor #{release_name}"
                elsif release_name == "stable"
                    FileUtils.rm_f File.join(config_dir, RELEASE_VERSIONS)
                    @ws.config.set("ROCK_SELECTED_FLAVOR", "stable")
                    @ws.config.set('current_rock_release', false)
                    @ws.save_config
                    Autoproj.message "successfully setup flavor #{release_name}"
                else
                    versions = fetch_version_file(release_name)
                    ensure_overrides_dir_present
                    File.open(File.join(config_dir, RELEASE_VERSIONS), 'w') do |io|
                        io.write versions
                    end
                    @ws.config.set("ROCK_SELECTED_FLAVOR", "stable")
                    @ws.config.set('current_rock_release', release_name)
                    @ws.save_config
                    Autoproj.message "successfully setup release #{release_name}"
                end

                Autoproj.message "  autoproj status will tell you what has changed"
                Autoproj.message "  aup --all will attempt to include the new release changes to your working copy"
                Autoproj.message "  aup --all --reset will (safely) reset your working copy to the release's state"
                Autoproj.message "  aup --all --force-reset will UNSAFELY reset your working copy to the release's state"
            end

            desc 'freeze NAMES', 'freeze the given package(s) or package set. If a package set is given, its packages are frozen'
            def freeze(*names)
                release_name = @ws.config.get('current_rock_release', false)
                if !release_name
                    Autoproj.error "currently not on any release, use rock-release switch first"
                    return
                end

                version_file = fetch_version_file(release_name)
                versions = YAML.load(version_file)

                pkgs = match_names_to_packages_in_versions(names, versions)
                ops = Autoproj::Ops::Snapshot.new(@ws.manifest)
                ops.save_versions(pkgs.values, File.join(config_dir, RELEASE_VERSIONS), replace: false)
            end

            desc 'unfreeze', 'Allow the given packages or package set to be updated.'
            def unfreeze(*names)
                release_name = @ws.config.get('current_rock_release', false)
                if !release_name
                    Autoproj.error "currently not on any release, use rock-release switch first"
                    return
                end

                release_versions_path = File.join(config_dir, RELEASE_VERSIONS)
                if !File.file?(release_versions_path)
                    Autoproj.error "#{release_versions_path} not present on disk, use autoproj switch to restore it first"
                    return
                end

                versions = YAML.load(File.read(release_versions_path))
                pkgs = match_names_to_packages_in_versions(names, versions, ignore_missing: true)
                versions.delete_if do |vcs|
                    pkgs.has_key?(vcs.keys.first)
                end

                ops = Autoproj::Ops::Snapshot.new(@ws.manifest)
                ops.save_versions(versions, release_versions_path, replace: true)
                Autoproj.message "updated #{release_versions_path}"
            end

            desc "admin", "commands to create releases"
            subcommand "admin", ReleaseAdmin
        end
    end
end

