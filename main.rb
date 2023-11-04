require 'pathname'
require 'xcodeproj'
require 'json'
require 'net/http'
require 'plist'
require 'digest'
require 'set'

def env_has_key(key)
  get_env_variable(key) || abort("Missing: #{key}")
end

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

build_profile_id = env_has_key('AC_BUILD_PROFILE_ID') 
$git_branch = env_has_key('AC_GIT_BRANCH') 
$output_path = env_has_key('AC_OUTPUT_DIR') 

if $git_branch.include?("/")
  $git_branch = $git_branch.gsub("/","_")
end  

$ac_referance_branch = env_has_key('AC_REFERANCE_BRANCH') 
$ac_cache_included_path = "#{$output_path}/permission_result_#{$ac_referance_branch}.txt"

$ac_repository_path = env_has_key('AC_REPOSITORY_DIR') 
$project_path = env_has_key('AC_PROJECT_PATH')
$ac_cache_label = "#{build_profile_id}/#{$ac_referance_branch}/cache/permission"
$ac_token_id = get_env_variable('AC_TOKEN_ID') || abort_with0('AC_TOKEN_ID env variable must be set when build started.')
$ac_callback_url = get_env_variable('AC_CALLBACK_URL') || abort_with0('AC_CALLBACK_URL env variable must be set when build started.')
signed_url_api = "#{$ac_callback_url}?action=getCacheUrls"

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

##Cache Push and Pull Functions
def cache_push_and_pull_file()
  @cache = "ac_cache/#{$ac_cache_label}"
  cache_file = "#{@cache}/#{File.basename($ac_cache_included_path)}"
  
  puts '--- Inputs:'
  puts "Cache Label: #{$ac_cache_label}"
  puts "Cache Included: #{$ac_cache_included_path}"
  puts "Repository Path: #{$ac_repository_path}"
  puts '-----------'

  if $git_branch == $ac_referance_branch

    unless File.exist?($ac_cache_included_path)
      abort_with0("File not found: #{$ac_cache_included_path}")
    end

    system("mkdir -p #{@cache}")

    system("cp #{$ac_cache_included_path} #{cache_file}")

    if File.exist?("#{cache_file}.md5")
      pulled_md5sum = File.open("#{cache_file}.md5", 'r', &:readline).strip
      pushed_md5sum = Digest::MD5.file(cache_file).hexdigest
      if pulled_md5sum == pushed_md5sum
        puts 'Cache is the same as the pulled one. No need to upload.'
        exit 0
      end
    end

    if !$ac_token_id.empty?
      puts ''

      signed_url_api = "#{$ac_callback_url}?action=getCacheUrls"
      ws_signed_url = "#{signed_url_api}&cacheKey=#{$ac_cache_label.gsub('/', '_')}&tokenId=#{$ac_token_id}"
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
          run_command_with_log("#{curl} '#{ENV['AC_CACHE_PUT_URL']}' --form 'file=@\"#{cache_file}\"'")
        else
          curl = 'curl -0 -X PUT -H "Content-Type: application/zip"'
          run_command_with_log("#{curl} --upload-file #{cache_file} $AC_CACHE_PUT_URL")
        end
      end
    end
    puts "Permissions succesfully cached"
    exit 0
##Cache Pull    
  else

    if File.exist?("#{@cache}/#{File.basename($ac_cache_included_path)}")
      puts 'File already cached. No need to pull.'
      exit 0
    end
    
    system("mkdir -p #{@cache}")

    if !$ac_token_id.empty?
      puts ''

      signed_url_api = "#{$ac_callback_url}?action=getCacheUrls"
      ws_signed_url = "#{signed_url_api}&cacheKey=#{$ac_cache_label.gsub('/', '_')}&tokenId=#{$ac_token_id}"
      puts ws_signed_url

      uri = URI(ws_signed_url)
      response = Net::HTTP.get(uri)

      unless response.empty?
        puts 'Downloading cache...'

        signed = JSON.parse(response)
        ENV['AC_CACHE_GET_URL'] = signed['getUrl']
        puts ENV['AC_CACHE_GET_URL']

        if get_env_variable('AC_CACHE_PROVIDER').eql?('FILESYSTEM')
          run_command_with_log("curl -X GET --fail -o #{cache_file} '#{ENV['AC_CACHE_GET_URL']}'")
        else
          run_command_with_log("curl -X GET -H \"Content-Type: application/zip\" --fail -o #{cache_file} $AC_CACHE_GET_URL")
        end
        run_command_with_log("mv #{cache_file} #{$output_path}/")
      end
    end
  end
end

## Get necessary Parameters
scheme = get_env_variable('AC_SCHEME') || abort_with0('AC_SCHEME env variable must be set when build started')
params = {}
params[:xcodeproj] = xcode_project_file
params[:scheme] = scheme

## Begin search, cache, read Permissions
begin
  xcode_permissions = read_permissions_from_info_plist(params)
  permission_result = "permission_result_#{$git_branch}.txt"
  write_values_to_file(xcode_permissions, $output_path, permission_result)
  cache_push_and_pull_file()

  cached_permission_result = read_file_content("#{$output_path}/permission_result_#{$ac_referance_branch}.txt")
  previous_permission_result = read_file_content("#{$output_path}/permission_result_#{$git_branch}.txt")
  compare_files(cached_permission_result, previous_permission_result)

  exit 0
rescue StandardError => e
  puts "Your project is not compatible. Project is not updated. \nError: #{e} "
  exit 1
end