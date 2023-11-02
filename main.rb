require 'pathname'
require 'xcodeproj'
require 'json'
require 'net/http'
require 'plist'
require 'digest'
require 'set'

def get_env_variable(key)
  ENV[key].nil? || ENV[key] == '' ? nil : ENV[key]
end

def run_command(command)
  unless system(command)
    puts "@@[error] Unexpected exit with code #{$CHILD_STATUS.exitstatus}. Check logs for details."
    exit 0
  end
end

def abort_with0(message)
  puts "@@[error] #{message}"
  exit 0
end

build_profile_id = get_env_variable('AC_BUILD_PROFILE_ID') || abort("Missing: AC_BUILD_PROFILE_ID")
git_branch = get_env_variable('AC_GIT_BRANCH') || abort("Missing: AC_GIT_BRANCH")
$output_path = get_env_variable('AC_OUTPUT_DIR') || abort("Missing: AC_OUTPUT_DIR")

if git_branch.include?("/")
  git_branch = git_branch.gsub("/","_")
end  

ac_referance_branch = get_env_variable('AC_REFERANCE_BRANCH') || abort("Missing: AC_REFERANCE_BRANCH")
ac_cache_included_paths = "#{$output_path}/permission_result_#{ac_referance_branch}.txt"

$ac_repository_path = get_env_variable('AC_REPOSITORY_DIR') 
$project_path = get_env_variable('AC_PROJECT_PATH')
ac_cache_label = "#{build_profile_id}/#{ac_referance_branch}/cache/permission"
ac_cache_pull_label = "#{build_profile_id}/#{ac_referance_branch}/cache/permission"
ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
ac_callback_url = get_env_variable('AC_CALLBACK_URL') || abort_with0('AC_CALLBACK_URL env variable must be set when build started.')
signed_url_api = "#{ac_callback_url}?action=getCacheUrls"

# .xcodeproj dosyasının yolunu al
def xcode_project_file
  project_path = (Pathname.new $ac_repository_path).join(Pathname.new($project_path))
  puts "Project path: #{project_path}"
  project_directory = File.dirname(project_path)
  puts "Project Direction: #{project_directory}"
  if File.extname(project_path) == '.xcworkspace' 
    Dir[File.join(project_directory, '*.xcodeproj')][0]
  else
    project_path
  end
end

def get_value_from_build_settings!(target, configuration = nil)
  values = {}
  variable = 'INFOPLIST_KEY_'
  target.build_configurations.each do |config|
    if configuration.nil? || config.name == configuration
      config.build_settings.each do |key, value|
        if key.start_with?(variable)
          values[key] = value
        end
      end
    end
  end
  values
end

def get_plist(params, target)
  scheme_name = params[:scheme]
  scheme_file = File.join(params[:xcodeproj], 'xcshareddata', 'xcschemes', "#{scheme_name}.xcscheme")
  if File.exist?(scheme_file) && params[:configuration].nil?
    scheme = Xcodeproj::XCScheme.new(scheme_file)
    puts "Archiving configuration: #{scheme.archive_action.build_configuration}"
    params[:configuration] = scheme.archive_action.build_configuration
  end

  if params[:configuration]
    build_config = target.build_configurations.detect { |c| c.name == params[:configuration] }
  else
    puts "Configuration  #{params[:configuration]} not found. Make sure scheme is shared and configuration is present."
    exit 0
  end
  project_path = (Pathname.new $ac_repository_path).join(Pathname.new($project_path))
  project_directory = File.dirname(project_path)
  info_plist = build_config.build_settings["INFOPLIST_FILE"]
  if info_plist.nil?
    return nil
  end
  info_plist_path = (Pathname.new project_directory).join(Pathname.new(info_plist))
  puts info_plist_path
  return info_plist_path
end

def read_permissions_from_info_plist(params)
  target = find_target(params)
  variable = 'INFOPLIST_KEY_'
  info_plist_path = get_plist(params, target)
  puts "Build Target: #{target}"
  if info_plist_path.nil?
    puts "Can't read plist file. Read from Xcode variable: #{variable}"
    permissions_from_build_settings = get_value_from_build_settings!(target, params[:configuration]) || get_value_from_build_settings!(project, params[:configuration])
    return permissions_from_build_settings
  end

  plist_data = Plist.parse_xml(info_plist_path)

  permissions = plist_data["UIApplicationSceneManifest"]
  if permissions
    puts "Permissions:"
    permissions.each do |key, value|
      puts "#{key}: #{value}"
    end
  else
    puts "UIApplicationSceneManifest permissions not found."
  end
end

def find_target(params)
  project = Xcodeproj::Project.open(params[:xcodeproj])
  target = project.targets.detect do |t|
    t.is_a?(Xcodeproj::Project::Object::PBXNativeTarget) &&
      t.product_type == 'com.apple.product-type.application'
  end
  target
end

# Write function to file all permissions [Key:Value]
def write_values_to_file(values, output_dir ,permission_result)
  output_path = File.join(output_dir, permission_result)
  File.open(output_path, 'w') do |file|
    values.each do |key, value|
      file.puts("#{key}: #{value}")
    end
  end
end

# Permission Diff Function
def compare_files(cached_permission, current_permission_result)
    
  puts "----------------"
  puts "Reference Branch Permissions:\n#{cached_permission}"
  puts "----------------"
  puts "New Permissions:\n#{current_permission_result}"
  
  seq1 = current_permission_result.split("\n")
  seq2 = cached_permission.split("\n")
  
  differance_new = seq1 - seq2
  differance_old = seq2 - seq1
  
  if differance_new.empty? && differance_old.empty?
      puts "NO PERMISSION CHANGES DETECTED"
      exit 0
  else
      puts "----------------"
      puts "Added Permissions:"

      differance_new.each do |line|
          puts line
      end
    
      puts "----------------"
      puts "Removed Permissions:"
      differance_old.each do |line|
          puts line
      end
      puts "----------------"
  end
  exit 1
end

#read func from .txt
def read_file_content(file_path)
  File.read(file_path)
end

def run_command_with_log(command)
  puts "@@[command] #{command}"
  s = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  run_command(command)
  e = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  puts "took #{(e - s).round(3)}s"
end

##Cache Push Functions
def add_includes(included_paths, zip)  
  included_paths.each do |f|
    next if ['.', '..'].include?(f)
    next if f.end_with?('.') || f.end_with?('..')

    zip += " #{f}"
  end
  zip
end

def add_log_file(folder, file, zip)
  if $output_path
    system("mkdir -p #{folder}")
    zip += " > #{folder}/#{file}"
  end
  zip
end

def run_zip(zip_file, zip)
  run_command_with_log(zip)
  run_command("ls -lh #{zip_file}")
end

def cache_path(base_path, included_path, env_dirs)
  puts "Include: #{included_path} in #{base_path}"

  unless Dir.exist?(base_path)
    puts "Warning: #{base_path} doesn't exist yet. Check folder is correct and available."
    return nil
  end

  cwd = Dir.pwd
  Dir.chdir(base_path)
  paths = Dir.glob(included_path.to_s, File::FNM_DOTMATCH)

  if paths.empty?
    Dir.chdir(cwd)
    return nil
  end

  base_path = "/#{env_dirs[base_path]}" if env_dirs.key?(base_path)
  zip_file = "#{cwd}/#{@cache}#{base_path}/#{included_path.gsub('/', '_')}.zip"
  system("mkdir -p #{cwd}/#{@cache}#{base_path}")
  zip = "zip -r -FS #{zip_file}"
  zip = add_includes(paths, zip)
  zip = add_log_file("#{$output_path}/#{@cache}#{base_path}", "#{included_path.gsub('/', '_')}.zip.log", zip)
  run_zip(zip_file, zip)

  Dir.chdir(cwd)
  zip_file
end

def search_env_dirs(path, env_dirs)
  return path if env_dirs.key?(path)

  index_of_slash = path.rindex('/')
  return search_env_dirs(path[0..index_of_slash - 1], env_dirs) if index_of_slash.positive?

  nil
end

def find_base_path(path, env_dirs)
  base_path = ''
  parts = path.split('/')
  order = 1
  parts.each do |w|
    break if order == parts.length
    break if w.include?('*')

    base_path += "/#{w}" unless w.empty?
    order += 1
  end
  env_path = search_env_dirs(base_path, env_dirs)
  env_path || base_path
end


## Get necessary Parameters
scheme = get_env_variable('AC_SCHEME')
params = {}
params[:configuration] = get_env_variable('AC_IOS_CONFIGURATION_NAME')
params[:xcodeproj] = xcode_project_file
params[:scheme] = scheme
params[:targets] = get_env_variable("AC_TARGETS")


## Begin search, cache, read Permissions
begin
  xcode_permissions = read_permissions_from_info_plist(params)
  permission_result = "permission_result_#{git_branch}.txt"
  write_values_to_file(xcode_permissions, $output_path, permission_result)
  
  
# Run cache and permission dif
# Cache permission_result.txt according to referance branch
  if git_branch == ac_referance_branch
    # check dependencies
    run_command('zip -v |head -2')
    run_command('curl --version |head -1')

    @cache = "ac_cache/#{ac_cache_label}"
    zipped = "ac_cache/#{ac_cache_label.gsub('/', '_')}.zip"

    puts '--- Inputs:'
    puts "Cache Label: #{ac_cache_label}"
    puts "Cache Included: #{ac_cache_included_paths}"
    puts "Repository Path: #{$ac_repository_path}"
    puts '-----------'

    env_dirs = Hash.new('')
    ENV.each_pair do |k, v|
      env_dirs[v] = k if k.start_with?('AC_') && File.directory?(v)
    end

    uptodate_zips = Set.new([])

    ac_cache_included_paths.split(':').each do |included_path|
      next if included_path.empty?

      zip_file = nil
      if included_path.start_with?('~/')
        included_path = included_path[('~/'.length)..-1]
        zip_file = cache_path(ENV['HOME'], included_path, env_dirs)
      elsif included_path.start_with?('/')
        base_path = find_base_path(included_path, env_dirs)
        next unless base_path

        zip_file = cache_path(base_path, included_path[(base_path.length + 1)..-1], env_dirs)
      elsif $ac_repository_path
        zip_file = cache_path($ac_repository_path, included_path, env_dirs)
      else
        puts "Warning: #{included_path} is skipped. It can be used only after Git Clone workflow step."
      end

      uptodate_zips.add(zip_file.sub("#{Dir.pwd}/", '')) if zip_file
    end

    # remove dead zips (includes) from pulled zips if not in uptodate set
    Dir.glob("#{@cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
      unless uptodate_zips.include?(zip_file)
        system("rm -f #{zip_file}")
        puts "Info: #{zip_file} is not in uptodate includes. Removed."
      end
    end
    system("find #{@cache} -empty -type d -delete")

    run_command("[ -s #{zipped} ] || rm -f #{zipped}")
    run_command_with_log("zip -r -0 -FS #{zipped} #{@cache}")
    run_command("ls -lh #{zipped}")

    if File.exist?("#{zipped}.md5")
      pulled_md5sum = File.open("#{zipped}.md5", 'r', &:readline).strip
      pushed_md5sum = Digest::MD5.file(zipped).hexdigest
      puts "#{pulled_md5sum} =? #{pushed_md5sum}"
      if pulled_md5sum == pushed_md5sum
        puts 'Cache is the same as pulled one. No need to upload.'
        exit 0
      end
    end

    unless ac_token_id.empty?
      puts ''
        
      ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
      puts ws_signed_url
        
      uri = URI(ws_signed_url)
      response = Net::HTTP.get(uri)
      
      unless response.empty?
        puts 'Uploading cache...'
        
        signed = JSON.parse(response)
        ENV['AC_CACHE_PUT_URL'] = signed['putUrl']
          puts ENV['AC_CACHE_PUT_URL']
            
          if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
            curl = 'curl -0 --location --request PUT'
            run_command_with_log("#{curl} '#{ENV['AC_CACHE_PUT_URL']}' --form 'file=@\"#{zipped}\"'")
          else
            curl = 'curl -0 -X PUT -H "Content-Type: application/zip"'
            run_command_with_log("#{curl} --upload-file #{zipped} $AC_CACHE_PUT_URL")
          end
        end
      end
    puts "Permissions succesfully cached"
    exit 0

 ##Cache Pull
  else
    # check dependencies
    run_command('unzip -v |head -1')
    run_command('curl --version |head -1')
  
    cache = "ac_cache/#{ac_cache_pull_label}"
    zipped = "ac_cache/#{ac_cache_pull_label.gsub('/', '_')}.zip"
  
    puts '--- Inputs:'
    puts "Cache Pull Label: #{ac_cache_pull_label}"
    puts "Repository Path: #{$ac_repository_path}"
    puts '-----------'
  
    env_dirs = Hash.new('')
    ENV.each_pair do |k, v|
      next unless k.start_with?('AC_')
      next if v.include?('//') || v.include?(':')
  
      env_dirs[k] = v if File.directory?(v) || %r{^(.+)/([^/]+)$} =~ v
    end
  
    system("rm -rf #{cache}")
    system("mkdir -p #{cache}")
  
    unless ac_token_id.empty?
      puts ''
  
      ws_signed_url = "#{signed_url_api}&cacheKey=#{ac_cache_pull_label.gsub('/', '_')}&tokenId=#{ac_token_id}"
      puts ws_signed_url
  
      uri = URI(ws_signed_url)
      response = Net::HTTP.get(uri)
      unless response.empty?
        puts 'Downloading cache...'
  
        signed = JSON.parse(response)
        ENV['AC_CACHE_GET_URL'] = signed['getUrl']
        puts ENV['AC_CACHE_GET_URL']
        if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
          run_command_with_log("curl -X GET --fail -o #{zipped} '#{ENV['AC_CACHE_GET_URL']}'")
        else
          run_command_with_log("curl -X GET -H \"Content-Type: application/zip\" --fail -o #{zipped} $AC_CACHE_GET_URL")
        end
      end
    end
  
    exit 0 unless File.size?(zipped)
  
    md5sum = Digest::MD5.file(zipped).hexdigest
    puts "MD5: #{md5sum}"
    File.open("#{zipped}.md5", 'a') do |f|
      f.puts md5sum.to_s
    end
    run_command_with_log("unzip -qq -o #{zipped}")
  
    Dir.glob("#{cache}/**/*.zip", File::FNM_DOTMATCH).each do |zip_file|
      puts zip_file
  
      last_slash = zip_file.rindex('/')
      base_path = zip_file[cache.length..last_slash - 1]
      base_path = env_dirs[base_path[1..-1]] if env_dirs.key?(base_path[1..-1])
  
      puts base_path
      system("mkdir -p #{base_path}")
      run_command_with_log("unzip -qq -u -o #{zip_file} -d #{base_path}/")
    end
  end

  cached_permission_result = read_file_content("#{$output_path}/permission_result_#{ac_referance_branch}.txt")
  previous_permission_result = read_file_content("#{$output_path}/permission_result_#{git_branch}.txt")
  compare_files(cached_permission_result, previous_permission_result)

  exit 0
rescue StandardError => e
  puts "Your project is not compatible. Project is not updated. \nError: #{e} "
  exit 1
end